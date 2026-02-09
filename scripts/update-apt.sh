#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-Esubaalew}"
REPO_NAME="${REPO_NAME:-run}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
DOCS_DIR="${DOCS_DIR:-docs}"
DIST="${DIST:-stable}"
COMPONENT="${COMPONENT:-main}"

if [[ -z "${APT_GPG_PRIVATE_KEY:-}" ]]; then
  echo "APT_GPG_PRIVATE_KEY is required to sign the repository" >&2
  exit 1
fi
if [[ -z "${APT_GPG_PASSPHRASE:-}" ]]; then
  echo "APT_GPG_PASSPHRASE is required to sign the repository" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ "$RELEASE_TAG" == "latest" ]]; then
  API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
else
  API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${RELEASE_TAG}"
fi

curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "$API_URL" > "$WORKDIR/release.json"

ASSET_URL=$(jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' "$WORKDIR/release.json" | head -n 1)
if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
  echo "No .deb asset found in ${REPO_OWNER}/${REPO_NAME} ${RELEASE_TAG}" >&2
  exit 1
fi

DEB_NAME=$(basename "$ASSET_URL")

curl -fsSL -L "$ASSET_URL" -o "$WORKDIR/$DEB_NAME"

VERSION=$(dpkg-deb -f "$WORKDIR/$DEB_NAME" Version)
ARCH=$(dpkg-deb -f "$WORKDIR/$DEB_NAME" Architecture)

POOL_DIR="$DOCS_DIR/pool/main/r/run"
DIST_DIR="$DOCS_DIR/dists/$DIST/main/binary-$ARCH"

mkdir -p "$POOL_DIR" "$DIST_DIR"
cp "$WORKDIR/$DEB_NAME" "$POOL_DIR/"

dpkg-scanpackages --arch "$ARCH" "$DOCS_DIR/pool" > "$DIST_DIR/Packages"
gzip -9c "$DIST_DIR/Packages" > "$DIST_DIR/Packages.gz"

RELEASE_FILE="$DOCS_DIR/dists/$DIST/Release"
{
  echo "Origin: Run"
  echo "Label: Run"
  echo "Suite: $DIST"
  echo "Codename: $DIST"
  echo "Date: $(date -R)"
  echo "Architectures: $ARCH"
  echo "Components: $COMPONENT"
  echo "Description: Run apt repository"
} > "$RELEASE_FILE"
apt-ftparchive release "$DOCS_DIR/dists/$DIST" >> "$RELEASE_FILE"

# Import and use the signing key
printf '%s' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import

KEY_ID="${APT_GPG_KEY_ID:-}"
if [[ -z "$KEY_ID" ]]; then
  KEY_ID=$(gpg --list-keys --with-colons | awk -F: '$1=="pub"{print $5; exit}')
fi
if [[ -z "$KEY_ID" ]]; then
  echo "Unable to determine GPG key id for signing" >&2
  exit 1
fi

GPG_COMMON=(--batch --yes --pinentry-mode loopback --passphrase "$APT_GPG_PASSPHRASE" -u "$KEY_ID")

gpg "${GPG_COMMON[@]}" -abs -o "$RELEASE_FILE.gpg" "$RELEASE_FILE"
gpg "${GPG_COMMON[@]}" --clearsign -o "$DOCS_DIR/dists/$DIST/InRelease" "$RELEASE_FILE"

gpg --batch --export --armor "$KEY_ID" > "$DOCS_DIR/run-archive-keyring.gpg"

echo "Updated apt repo for run ${VERSION} ($ARCH)"
