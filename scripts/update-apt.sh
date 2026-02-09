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

TAG_NAME=$(jq -r '.tag_name' "$WORKDIR/release.json")
VERSION="${TAG_NAME#v}"

DEB_URL=$(jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' "$WORKDIR/release.json" | head -n 1)

DEB_PATH=""
if [[ -n "$DEB_URL" && "$DEB_URL" != "null" ]]; then
  DEB_NAME=$(basename "$DEB_URL")
  DEB_PATH="$WORKDIR/$DEB_NAME"
  curl -fsSL -L "$DEB_URL" -o "$DEB_PATH"
else
  TAR_URL=$(jq -r '.assets[] | select(.name | contains("unknown-linux-gnu") and endswith(".tar.gz")) | .browser_download_url' "$WORKDIR/release.json" | head -n 1)
  if [[ -z "$TAR_URL" || "$TAR_URL" == "null" ]]; then
    echo "No Linux tarball found in release assets" >&2
    exit 1
  fi
  TAR_NAME=$(basename "$TAR_URL")
  TAR_PATH="$WORKDIR/$TAR_NAME"
  curl -fsSL -L "$TAR_URL" -o "$TAR_PATH"

  EXTRACT_DIR="$WORKDIR/extract"
  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$TAR_PATH" -C "$EXTRACT_DIR"
  ROOT_DIR=$(find "$EXTRACT_DIR" -maxdepth 1 -type d -name "run-*" | head -n 1)
  if [[ -z "$ROOT_DIR" ]]; then
    ROOT_DIR="$EXTRACT_DIR"
  fi

  PKG_DIR="$WORKDIR/pkg"
  mkdir -p "$PKG_DIR/DEBIAN" "$PKG_DIR/usr/bin" "$PKG_DIR/usr/share/doc/run"

  install -m 0755 "$ROOT_DIR/run" "$PKG_DIR/usr/bin/run"
  if [[ -f "$ROOT_DIR/README.md" ]]; then
    install -m 0644 "$ROOT_DIR/README.md" "$PKG_DIR/usr/share/doc/run/README.md"
  fi
  if [[ -f "$ROOT_DIR/LICENSE" ]]; then
    install -m 0644 "$ROOT_DIR/LICENSE" "$PKG_DIR/usr/share/doc/run/LICENSE"
  fi

  cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: run
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Esubalew Chekol <esubalewchekol6@gmail.com>
Depends: libc6 (>= 2.31)
Description: Universal multi-language runner and smart REPL
EOF

  DEB_PATH="$WORKDIR/run_${VERSION}_amd64.deb"
  dpkg-deb --build "$PKG_DIR" "$DEB_PATH" > /dev/null
fi

VERSION=$(dpkg-deb -f "$DEB_PATH" Version)
ARCH=$(dpkg-deb -f "$DEB_PATH" Architecture)

POOL_DIR="$DOCS_DIR/pool/main/r/run"
DIST_DIR="$DOCS_DIR/dists/$DIST/main/binary-$ARCH"

mkdir -p "$POOL_DIR" "$DIST_DIR"
cp "$DEB_PATH" "$POOL_DIR/"

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
