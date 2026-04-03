# OTel Backends — Observability Stack

Independent Docker Compose stack that runs the telemetry backends.
The OTel Collector inside each Dev Container forwards signals here.

## Architecture

```
┌─────────────────────────────┐       ┌─────────────────────────────────┐
│ Dev Container (per VDI)     │       │ This stack (docker compose up)  │
│                             │       │                                 │
│  App → localhost:4317/4318  │       │  Jaeger    :4317  ← traces      │
│         ↓                   │       │  Prometheus:9090  ← metrics     │
│  OTel Collector (agent)  ───┼──────▶│  Loki      :3100  ← logs        │
│                             │       │  Grafana   :3000  ← dashboards  │
└─────────────────────────────┘       └─────────────────────────────────┘
```

## Quick Start

```sh
cd otel-backends
docker compose up -d
```

## UIs

| Service    | URL                      | Purpose              |
|------------|--------------------------|----------------------|
| Jaeger     | http://localhost:16686    | Trace search & view  |
| Prometheus | http://localhost:9090     | Metrics query        |
| Grafana    | http://localhost:3000     | Unified dashboards   |
| Loki       | http://localhost:3100     | Log push API         |

Grafana login: `admin` / `admin`

## Dev Container Feature Defaults

The `otel-collector` feature defaults match this stack:

| Signal  | Collector exporter endpoint                          | Backend        |
|---------|------------------------------------------------------|----------------|
| Traces  | `http://host.docker.internal:4317`                   | Jaeger OTLP    |
| Metrics | `http://host.docker.internal:9090/api/v1/write`      | Prometheus RW  |
| Logs    | Local file inside container (`/var/log/otelcol/app.log`) | File exporter |

> **Note:** `host.docker.internal` resolves from inside the Dev Container
> to the host machine where this compose stack is running.

## Stopping

```sh
docker compose down
```

To also remove stored data:

```sh
docker compose down -v
```
