#!/bin/sh
set -eu

VERSION="${VERSION:-0.149.0}"
JAEGER_OTLP_ENDPOINT="${JAEGEROTLPENDPOINT:-http://host.docker.internal:4317}"
PROMETHEUS_RW_ENDPOINT="${PROMETHEUSREMOTEWRITEENDPOINT:-http://host.docker.internal:9090/api/v1/write}"
LOG_FILE_PATH="${LOGFILEPATH:-/var/log/otelcol/app.log}"
LOKI_ENDPOINT="${LOKIENDPOINT:-http://host.docker.internal:3100/otlp}"

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)  OTEL_ARCH="linux_amd64" ;;
    arm64)  OTEL_ARCH="linux_arm64" ;;
    *)      echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Installing OpenTelemetry Collector Contrib ${VERSION} (${OTEL_ARCH})..."

# Install dependencies
apt-get update
apt-get install -y --no-install-recommends wget ca-certificates
apt-get clean && rm -rf /var/lib/apt/lists/*

# Download collector-contrib binary (includes loki exporter)
DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VERSION}/otelcol-contrib_${VERSION}_${OTEL_ARCH}.tar.gz"
wget -q --show-progress -O /tmp/otelcol.tar.gz "${DOWNLOAD_URL}"
mkdir -p /usr/local/bin
tar -xzf /tmp/otelcol.tar.gz -C /usr/local/bin otelcol-contrib
chmod +x /usr/local/bin/otelcol-contrib
ln -sf /usr/local/bin/otelcol-contrib /usr/local/bin/otelcol
rm /tmp/otelcol.tar.gz

# Create config and log directories with open permissions
mkdir -p /etc/otelcol
mkdir -p "$(dirname "${LOG_FILE_PATH}")"
chmod 777 "$(dirname "${LOG_FILE_PATH}")"

# Write collector config
cat > /etc/otelcol/config.yaml <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

exporters:
  otlp/jaeger:
    endpoint: ${JAEGER_OTLP_ENDPOINT}
    tls:
      insecure: true

  prometheusremotewrite:
    endpoint: ${PROMETHEUS_RW_ENDPOINT}
    tls:
      insecure: true

  file:
    path: ${LOG_FILE_PATH}

  otlphttp/loki:
    endpoint: ${LOKI_ENDPOINT}

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlp/jaeger]
    metrics:
      receivers: [otlp]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      exporters: [file, otlphttp/loki]
EOF

# Create startup script that launches collector in background
cat > /usr/local/bin/start-otel-collector.sh <<'STARTUP'
#!/bin/sh
# Start OTel Collector in background if not already running
if ! pgrep -f otelcol-contrib > /dev/null 2>&1; then
    echo "Starting OpenTelemetry Collector..."
    nohup /usr/local/bin/otelcol-contrib --config /etc/otelcol/config.yaml \
        > /var/log/otelcol/collector.log 2>&1 &
    echo "OTel Collector started (PID: $!)"
fi
# Execute the original entrypoint/command if passed
exec "$@"
STARTUP
chmod +x /usr/local/bin/start-otel-collector.sh

# Verify installation
otelcol-contrib --version
echo "OpenTelemetry Collector Contrib ${VERSION} installed successfully"
echo "Config written to /etc/otelcol/config.yaml"
echo "Collector will start automatically via entrypoint"
