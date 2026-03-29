#!/bin/sh
set -eu

VERSION="${VERSION:-20}"
INSTALL_YARN="${INSTALLYARN:-false}"
INSTALL_PNPM="${INSTALLPNPM:-false}"

echo "Installing Node.js ${VERSION}..."

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${VERSION}.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y nodejs
apt-get clean && rm -rf /var/lib/apt/lists/*

node --version
npm --version
echo "Node.js ${VERSION} installed successfully"

if [ "$INSTALL_YARN" = "true" ]; then
    echo "Installing Yarn..."
    npm install -g yarn
    yarn --version
fi

if [ "$INSTALL_PNPM" = "true" ]; then
    echo "Installing pnpm..."
    npm install -g pnpm
    pnpm --version
fi
