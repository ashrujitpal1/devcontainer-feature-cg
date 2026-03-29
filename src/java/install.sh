#!/bin/sh
set -eu

VERSION="${VERSION:-21}"
INSTALL_MAVEN="${INSTALLMAVEN:-true}"
INSTALL_GRADLE="${INSTALLGRADLE:-false}"
GRADLE_VERSION="8.7"
MAVEN_VERSION="3.9.6"

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)  TEMURIN_ARCH="x64" ;;
    arm64)  TEMURIN_ARCH="aarch64" ;;
    *)      echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Installing Eclipse Temurin JDK ${VERSION} (${TEMURIN_ARCH})..."

# Install dependencies
apt-get update
apt-get install -y --no-install-recommends wget ca-certificates unzip
apt-get clean && rm -rf /var/lib/apt/lists/*

# Download and install Temurin JDK from Adoptium
TEMURIN_URL="https://api.adoptium.net/v3/binary/latest/${VERSION}/ga/linux/${TEMURIN_ARCH}/jdk/hotspot/normal/eclipse"

wget -q --show-progress -O /tmp/jdk.tar.gz "${TEMURIN_URL}"
mkdir -p /usr/lib/jvm
tar -xzf /tmp/jdk.tar.gz -C /usr/lib/jvm
rm /tmp/jdk.tar.gz

# Find the extracted directory and set JAVA_HOME
JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "jdk-${VERSION}*" | head -1)
if [ -z "$JAVA_HOME" ]; then
    JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d | grep -v "^/usr/lib/jvm$" | head -1)
fi

echo "JAVA_HOME=${JAVA_HOME}"

# Set up symlinks and environment
ln -sf "${JAVA_HOME}/bin/java"  /usr/local/bin/java
ln -sf "${JAVA_HOME}/bin/javac" /usr/local/bin/javac
ln -sf "${JAVA_HOME}/bin/jar"   /usr/local/bin/jar

# Persist JAVA_HOME for all shells
echo "export JAVA_HOME=${JAVA_HOME}" >> /etc/profile.d/java.sh
echo "export PATH=\$JAVA_HOME/bin:\$PATH" >> /etc/profile.d/java.sh
chmod +x /etc/profile.d/java.sh

# Verify
java -version
javac -version
echo "Java ${VERSION} installed successfully"

# Maven — download binary directly (avoids apt version mismatch)
if [ "$INSTALL_MAVEN" = "true" ]; then
    echo "Installing Maven ${MAVEN_VERSION}..."
    wget -q -O /tmp/maven.tar.gz \
        "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
    tar -xzf /tmp/maven.tar.gz -C /opt
    ln -sf "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn
    rm /tmp/maven.tar.gz
    echo "export M2_HOME=/opt/apache-maven-${MAVEN_VERSION}" >> /etc/profile.d/java.sh
    echo "export PATH=\$M2_HOME/bin:\$PATH" >> /etc/profile.d/java.sh
    mvn --version
    echo "Maven ${MAVEN_VERSION} installed successfully"
fi

# Gradle
if [ "$INSTALL_GRADLE" = "true" ]; then
    echo "Installing Gradle ${GRADLE_VERSION}..."
    wget -q -O /tmp/gradle.zip \
        "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
    unzip -q /tmp/gradle.zip -d /opt
    ln -sf "/opt/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
    rm /tmp/gradle.zip
    gradle --version
    echo "Gradle ${GRADLE_VERSION} installed successfully"
fi
