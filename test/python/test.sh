#!/bin/bash
set -e
source dev-container-features-test-lib

check "python3 installed" command -v python3
check "pip3 installed"    command -v pip3
check "python version"    python3 --version

reportResults
