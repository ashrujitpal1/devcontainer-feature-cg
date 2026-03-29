#!/bin/bash
set -e
source dev-container-features-test-lib

check "go installed"    command -v go
check "gofmt installed" command -v gofmt
check "go version"      go version

reportResults
