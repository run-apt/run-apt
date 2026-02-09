# Run APT Repository

This repository hosts the signed APT repository for `run`.

## Install

```bash
sudo install -d /usr/share/keyrings
curl -fsSL https://run-apt.github.io/run-apt/run-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/run-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/run-archive-keyring.gpg] https://run-apt.github.io/run-apt stable main" \
  | sudo tee /etc/apt/sources.list.d/run.list

sudo apt update
sudo apt install run
```

## Notes

- Only `amd64` is currently published.
- The repository is updated from the latest `run` release.
