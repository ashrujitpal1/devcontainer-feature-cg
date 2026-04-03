#!/bin/bash
set -e
source dev-container-features-test-lib

check "otelcol installed"       command -v otelcol
check "otelcol version"         otelcol --version
check "config exists"           test -f /etc/otelcol/config.yaml
check "startup script exists"   test -x /usr/local/bin/start-otel-collector.sh
check "log dir exists"          test -d /var/log/otelcol
check "config has otlp receiver" grep -q "otlp:" /etc/otelcol/config.yaml
check "config has traces pipeline" grep -q "traces:" /etc/otelcol/config.yaml
check "config has metrics pipeline" grep -q "metrics:" /etc/otelcol/config.yaml
check "config has logs pipeline" grep -q "logs:" /etc/otelcol/config.yaml
check "config has loki exporter" grep -q "otlphttp/loki" /etc/otelcol/config.yaml

reportResults
