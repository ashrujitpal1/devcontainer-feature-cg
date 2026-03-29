#!/bin/sh
set -eu

VERSION="${VERSION:-3.12}"
INSTALL_POETRY="${INSTALLPOETRY:-false}"
INSTALL_PIPENV="${INSTALLPIPENV:-false}"

echo "Installing Python ${VERSION}..."

apt-get update
apt-get install -y --no-install-recommends \
    software-properties-common \
    gnupg \
    ca-certificates \
    curl \
    wget
apt-get clean && rm -rf /var/lib/apt/lists/*

# Add deadsnakes PPA for newer Python versions on Debian/Ubuntu
# This provides Python 3.10, 3.11, 3.12, 3.13 on Debian Bookworm
apt-get update
apt-get install -y --no-install-recommends gpg-agent
add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || {
    # Fallback: add deadsnakes manually for Debian
    echo "deb https://ppa.launchpadcontent.net/deadsnakes/ppa/ubuntu jammy main" \
        > /etc/apt/sources.list.d/deadsnakes.list
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/deadsnakes.gpg
}

apt-get update
apt-get install -y --no-install-recommends \
    "python${VERSION}" \
    "python${VERSION}-dev" \
    "python${VERSION}-venv" \
    python3-pip
apt-get clean && rm -rf /var/lib/apt/lists/*

# Set as default python3
update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${VERSION}" 1
update-alternatives --install /usr/bin/python  python  "/usr/bin/python${VERSION}" 1

# Ensure pip is available for the installed version
"python${VERSION}" -m ensurepip --upgrade 2>/dev/null || true
"python${VERSION}" -m pip install --upgrade pip 2>/dev/null || true

python3 --version
pip3 --version || python3 -m pip --version
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
