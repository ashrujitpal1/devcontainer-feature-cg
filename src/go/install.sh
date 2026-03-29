#!/bin/sh
set -eu

VERSION="${VERSION:-1.22}"
ARCH=$(dpkg --print-architecture)

case "$ARCH" in
    amd64) GO_ARCH="amd64" ;;
    arm64) GO_ARCH="arm64" ;;
    *)     echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Installing Go ${VERSION} (${GO_ARCH})..."

curl -fsSL "https://go.dev/dl/go${VERSION}.linux-${GO_ARCH}.tar.gz" \
    -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

ln -sf /usr/local/go/bin/go   /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

go version
echo "Go ${VERSION} installed successfully"
