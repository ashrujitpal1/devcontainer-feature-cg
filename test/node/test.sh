#!/bin/bash
set -e
source dev-container-features-test-lib

check "node installed" command -v node
check "npm installed"  command -v npm
check "node version"   node --version
check "npm version"    npm --version

reportResults
