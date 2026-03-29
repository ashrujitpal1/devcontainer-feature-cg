#!/bin/bash
set -e
source dev-container-features-test-lib

check "java installed"  command -v java
check "javac installed" command -v javac
check "java version"    java -version
check "mvn installed"   command -v mvn
check "mvn version"     mvn --version

reportResults
