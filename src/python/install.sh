#!/bin/sh
set -eu

VERSION="${VERSION:-3.12}"
INSTALL_POETRY="${INSTALLPOETRY:-false}"
INSTALL_PIPENV="${INSTALLPIPENV:-false}"

echo "Installing Python ${VERSION}..."

apt-get update
apt-get install -y --no-install-recommends \
    "python${VERSION}" \
    "python${VERSION}-dev" \
    "python${VERSION}-venv" \
    python3-pip
apt-get clean
rm -rf /var/lib/apt/lists/*

# Make python3 point to the installed version
update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${VERSION}" 1
update-alternatives --install /usr/bin/python  python  "/usr/bin/python${VERSION}" 1

python3 --version
pip3 --version
echo "Python ${VERSION} installed successfully"

if [ "$INSTALL_POETRY" = "true" ]; then
    echo "Installing Poetry..."
    curl -sSL https://install.python-poetry.org | python3 -
    echo "Poetry installed successfully"
fi

if [ "$INSTALL_PIPENV" = "true" ]; then
    echo "Installing Pipenv..."
    pip3 install --no-cache-dir pipenv
    echo "Pipenv installed successfully"
fi
