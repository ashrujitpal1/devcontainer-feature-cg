#!/bin/bash
set -e
source dev-container-features-test-lib

check "gitleaks installed" command -v gitleaks
check "gitleaks version"   gitleaks version
check "eslint installed"   command -v eslint
check "prettier installed" command -v prettier

reportResults
