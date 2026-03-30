#!/bin/sh
set -eu

INSTALL_LINTERS="${INSTALLLINTERS:-true}"
INSTALL_FORMATTERS="${INSTALLFORMATTERS:-true}"
INSTALL_SECRET_SCANNER="${INSTALLSECRETSCANNER:-true}"
GITLEAKS_VERSION="8.21.2"

echo "Activating feature 'approved-ide-tools-vscode'"

# ── Linters ───────────────────────────────────────────────────────────────────
if [ "$INSTALL_LINTERS" = "true" ]; then
    echo "Installing approved linters..."

    # JS/TS linter — only if npm is available
    if command -v npm >/dev/null 2>&1; then
        npm install -g eslint || echo "WARN: eslint install failed"
        echo "eslint installed"
    fi

    # Python linters — only if pip3 is available
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --no-cache-dir pylint flake8 mypy || echo "WARN: python linters install failed"
        echo "pylint, flake8, mypy installed"
    fi
fi

# ── Formatters ────────────────────────────────────────────────────────────────
if [ "$INSTALL_FORMATTERS" = "true" ]; then
    echo "Installing approved formatters..."

    if command -v npm >/dev/null 2>&1; then
        npm install -g prettier || echo "WARN: prettier install failed"
        echo "prettier installed"
    fi

    if command -v pip3 >/dev/null 2>&1; then
        pip3 install --no-cache-dir black isort || echo "WARN: python formatters install failed"
        echo "black, isort installed"
    fi
fi

# ── Secret Scanner (gitleaks) ─────────────────────────────────────────────────
if [ "$INSTALL_SECRET_SCANNER" = "true" ]; then
    echo "Installing gitleaks ${GITLEAKS_VERSION}..."

    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    case "$ARCH" in
        amd64) GL_ARCH="x64" ;;
        arm64) GL_ARCH="arm64" ;;
        *)     GL_ARCH="x64" ;;
    esac

    curl -fsSL \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
        -o /tmp/gitleaks.tar.gz \
    && tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks \
    && chmod +x /usr/local/bin/gitleaks \
    && rm /tmp/gitleaks.tar.gz \
    && gitleaks version \
    && echo "gitleaks installed" \
    || echo "WARN: gitleaks install failed"
fi

echo "approved-ide-tools-vscode installation complete"
