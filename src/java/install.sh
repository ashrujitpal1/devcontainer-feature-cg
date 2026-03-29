#!/bin/sh
set -eu

VERSION="${VERSION:-21}"
INSTALL_MAVEN="${INSTALLMAVEN:-true}"
INSTALL_GRADLE="${INSTALLGRADLE:-false}"
GRADLE_VERSION="8.7"

echo "Installing Java JDK ${VERSION}..."

apt-get update
apt-get install -y --no-install-recommends \
    "openjdk-${VERSION}-jdk" \
    "openjdk-${VERSION}-source"
apt-get clean
rm -rf /var/lib/apt/lists/*

# Verify
java -version
javac -version
echo "Java ${VERSION} installed successfully"

# Maven
if [ "$INSTALL_MAVEN" = "true" ]; then
    echo "Installing Maven..."
    apt-get update
    apt-get install -y --no-install-recommends maven
    apt-get clean && rm -rf /var/lib/apt/lists/*
    mvn --version
    echo "Maven installed successfully"
fi

# Gradle
if [ "$INSTALL_GRADLE" = "true" ]; then
    echo "Installing Gradle ${GRADLE_VERSION}..."
    curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
        -o /tmp/gradle.zip
    unzip -q /tmp/gradle.zip -d /opt
    ln -s "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
    rm /tmp/gradle.zip
    gradle --version
    echo "Gradle ${GRADLE_VERSION} installed successfully"
fi
