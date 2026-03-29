# Workspace Understanding — devcontainer-feature-cg

## What This Repository Is

This repository implements the Capital Group Claude Code Dev Container platform.
It provides a secure, enterprise-grade way for developers to run Claude Code
inside Dev Containers with centrally managed security controls.

**GitHub:** https://github.com/ashrujitpal1/devcontainer-feature-cg
**GHCR Namespace:** `ghcr.io/ashrujitpal1/devcontainer-feature-cg`
**S3 Policy Bucket:** `s3://capital-group-claude-policies`
**AWS Account:** `696072349808`

---

## Repository Structure

```
devcontainer-feature-cg/
│
├── layer1-base-image/          ← Layer 1: Pre-built base image (CI/CD built)
│   ├── Dockerfile              ← Builds the base image
│   ├── managed-settings/       ← COPY 1: Policy floor baked into image
│   │   ├── manifest.json       ← Baseline version metadata
│   │   ├── settings.json       ← Base policy (all developers)
│   │   ├── settings-java.json  ← Java language overlay
│   │   ├── settings-python.json← Python language overlay
│   │   ├── settings-node.json  ← Node language overlay
│   │   └── settings-go.json    ← Go language overlay
│   └── scripts/
│       ├── apply-security-policy.sh  ← Runs at every container start
│       └── init-firewall.sh          ← Best-effort egress firewall
│
├── src/                        ← Layer 2: Dev Container Features source
│   ├── java/
│   │   ├── devcontainer-feature.json  ← Feature metadata (v1.0.1)
│   │   └── install.sh                 ← Eclipse Temurin JDK installer
│   ├── python/
│   │   ├── devcontainer-feature.json  ← Feature metadata (v1.0.1)
│   │   └── install.sh                 ← deadsnakes PPA Python installer
│   ├── node/
│   │   ├── devcontainer-feature.json  ← Feature metadata (v1.0.0)
│   │   └── install.sh                 ← NodeSource Node.js installer
│   ├── go/
│   │   ├── devcontainer-feature.json  ← Feature metadata (v1.0.0)
│   │   └── install.sh                 ← go.dev direct download installer
│   └── approved-ide-tools/
│       └── vscode/
│           ├── devcontainer-feature.json  ← Feature metadata (v1.0.0)
│           └── install.sh                 ← gitleaks, eslint, prettier, black
│
├── layer3-policy/              ← Layer 3: S3 delta policy (COPY 2)
│   └── manifest.json           ← Delta manifest (deltaFiles: [] at v1.0.0)
│
├── developer-templates/        ← What developers copy into their projects
│   ├── java/
│   │   └── .devcontainer/
│   │       └── devcontainer.json  ← Java project template
│   ├── python/
│   │   └── .devcontainer/
│   │       └── devcontainer.json  ← Python project template
│   ├── node/
│   │   └── .devcontainer/
│   │       └── devcontainer.json  ← Node project template
│   ├── fullstack/
│   │   └── .devcontainer/
│   │       └── devcontainer.json  ← Java + Python + Node template
│   └── java-local-test/
│       └── .devcontainer/
│           └── devcontainer.json  ← Local test template (SECURITY_POLICY_SOURCE=local)
│
├── test/                       ← Feature test suites
│   ├── java/
│   │   ├── scenarios.json      ← Test scenarios (java21, java17-gradle)
│   │   └── test.sh             ← Verifies java, javac, mvn installed
│   ├── python/
│   │   ├── scenarios.json
│   │   └── test.sh
│   ├── node/
│   │   ├── scenarios.json
│   │   └── test.sh
│   ├── go/
│   │   ├── scenarios.json
│   │   └── test.sh
│   └── approved-ide-tools/
│       └── vscode/
│           ├── scenarios.json
│           └── test.sh
│
└── .github/
    └── workflows/
        ├── release.yaml    ← Publishes features + base image + S3 policy
        ├── test.yaml       ← Tests all features on push/PR
        └── validate.yaml   ← Validates devcontainer-feature.json files
```

---

## File-by-File Explanation

### layer1-base-image/Dockerfile

The base image Dockerfile. Built from `node:20` (Debian Bookworm).

Key decisions:
- Uses `node:20` as base because Claude Code CLI requires Node.js
- Installs core tools as root, then switches to `node` user for Claude CLI install
- Switches back to root to copy security assets
- `managed-settings/` copied to `/etc/cg-managed-settings/` with `chmod 755` (dir) and `chmod 444` (files)
- Ends with `USER node` — container runs as non-root by default

What it does NOT include:
- Java, Python, Go, Rust — these come from Layer 2 features
- Any project-specific tooling

### layer1-base-image/managed-settings/settings.json

The COPY 1 baseline policy. This is the full security policy floor baked into the image.

Current Phase 1 controls:
- `permissions.deny` — blocks curl, wget, nc, ncat, ssh, scp, rsync
- `mcpServers.httpWhitelist` — only `https://mcp-gateway.internal.capitalgroup.com/*`
- `fileSystemIsolation.allowedPaths` — `/workspace`, `/tmp` only
- `fileSystemIsolation.deniedPaths` — `/root/.aws`, `/etc/shadow`, `/etc/passwd`, `/etc/sudoers`
- `model.allowedModels` — only `us.anthropic.claude-sonnet-4-6` and `us.anthropic.claude-haiku-3-5`

### layer1-base-image/scripts/apply-security-policy.sh

The most critical script in the entire system. Runs at every container start via `postStartCommand`.

Flow:
1. `detect_languages()` — checks for `java`, `python3`, `node`, `go` binaries
2. `fetch_delta_policy()` — fetches S3 manifest, checks `deltaFiles` count
3. `merge_settings()` — starts from COPY 1, merges COPY 2 delta if present, then language overlays
4. `write_managed_settings()` — writes to `~/.claude/settings.json`
5. `emit_audit()` — logs audit event with versions and detected languages

**Critical implementation note:** `log()` writes to `stderr` (`>&2`) only. This prevents log lines from being captured by `$()` command substitution when `merge_settings()` and `fetch_delta_policy()` are called.

Environment variables it reads:
- `SECURITY_POLICY_SOURCE` — `s3` (default) or `local` (skip S3, use image only)
- `SECURITY_POLICY_S3_BUCKET` — S3 bucket name
- `SECURITY_POLICY_S3_PREFIX` — S3 prefix (default: `latest`)
- `CLAUDE_CONFIG_DIR` — where to write `settings.json`
- `CG_AUDIT_ENDPOINT` — optional HTTP endpoint for audit events

### layer1-base-image/scripts/init-firewall.sh

Best-effort container egress firewall using iptables. Allows outbound traffic only to:
- AWS Bedrock, STS, S3 endpoints (us-east-1)
- GitHub (for git operations)
- npm registry
- VS Code marketplace

**Important:** This is defense-in-depth only. A developer with Docker Desktop access can bypass container-level iptables from the host. Apex will be the real enforcement when available.

### src/<feature>/devcontainer-feature.json

Standard Dev Container Feature metadata. Key fields:
- `id` — feature identifier (used in GHCR path)
- `version` — semantic version (bump to trigger new publish)
- `options` — configurable parameters (version, installMaven, etc.)
- `customizations.vscode.extensions` — VS Code extensions auto-installed with this feature
- `installsAfter` — ordering hint for feature installation

### src/java/install.sh

Installs Eclipse Temurin JDK via Adoptium API. Uses direct download instead of apt because `openjdk-21-jdk` is not in Debian Bookworm's default apt repository.

Also installs Maven via Apache archive direct download (not apt) for version consistency.

### src/python/install.sh

Installs Python via deadsnakes PPA. Uses `add-apt-repository ppa:deadsnakes/ppa` because `python3.12` is not in Debian Bookworm's default apt repository.

### layer3-policy/manifest.json

The S3 delta manifest. At v1.0.0 initial release, `deltaFiles` is empty — the image baseline is the full policy.

When security team adds new controls:
1. Add delta settings file (e.g., `settings-delta-v1.1.json`)
2. Add filename to `deltaFiles` array
3. Bump `version`
4. CI/CD syncs to S3

### developer-templates/<stack>/.devcontainer/devcontainer.json

What developers copy into their project repos. Contains:
- `image` — points to `ghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:latest`
- `features` — Capital Group approved features for the language stack
- `postStartCommand` — `/usr/local/bin/apply-security-policy.sh`
- `containerEnv` — Bedrock config, S3 bucket reference
- `mounts` — `~/.aws` (read-only), `~/.gitconfig` (read-only), named volumes for history and Claude config

### .github/workflows/release.yaml

Triggered on push to `main`. Three parallel jobs:
1. `publish-features` — publishes all `src/` features to GHCR via `devcontainers/action`
2. `publish-base-image` — builds and pushes `layer1-base-image/` to GHCR
3. `publish-policy-s3` — syncs `layer3-policy/` to S3 (runs after base image build)

---

## Published Assets on GHCR

| Feature | GHCR Path | Version | What it installs |
|---|---|---|---|
| Base Image | `.../claude-base:latest` | latest | node:20 + Claude CLI + security scripts |
| Java | `.../java:1` | 1.0.1 | Eclipse Temurin JDK + Maven/Gradle |
| Python | `.../python:1` | 1.0.1 | Python 3.12 via deadsnakes PPA |
| Node | `.../node:1` | 1.0.0 | Node.js via NodeSource |
| Go | `.../go:1` | 1.0.0 | Go via go.dev |
| IDE Tools | `.../approved-ide-tools-vscode:1` | 1.0.0 | gitleaks, eslint, prettier, black |

---

## Environment Variables Reference

| Variable | Default | Where Set | Purpose |
|---|---|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | `1` | devcontainer.json | Route Claude via AWS Bedrock |
| `AWS_REGION` | `us-east-1` | devcontainer.json | Bedrock region |
| `AWS_PROFILE` | `default` | devcontainer.json | AWS credentials profile |
| `CLAUDE_CONFIG_DIR` | `/root/.claude` | devcontainer.json | Claude settings directory |
| `SECURITY_POLICY_SOURCE` | `s3` | devcontainer.json | `s3` or `local` |
| `SECURITY_POLICY_S3_BUCKET` | `capital-group-claude-policies` | devcontainer.json | S3 bucket for delta policy |
| `SECURITY_POLICY_S3_PREFIX` | `latest` | devcontainer.json | S3 prefix |
| `CG_AUDIT_ENDPOINT` | (unset) | optional | HTTP endpoint for audit events |
| `NODE_OPTIONS` | `--max-old-space-size=4096` | devcontainer.json | Node.js heap for Claude CLI |
| `POWERLEVEL9K_DISABLE_GITSTATUS` | `true` | devcontainer.json | Prevents slow zsh prompt in large repos |

---

## Security Controls Active at v1.0.0

All delivered via COPY 1 (image baseline):

| Control | Implementation | Status |
|---|---|---|
| MCP HTTP Whitelist | `mcpServers.httpWhitelist` in settings.json | ✅ Active |
| Deny List | `permissions.deny` — blocks curl, wget, nc, ssh, scp, rsync | ✅ Active |
| File System Isolation | `fileSystemIsolation.allowedPaths/deniedPaths` | ✅ Active |
| Private Model Routes | `model.allowedModels` + Bedrock IAM | ✅ Active |
| Tool Extension Allowlist | `permissions.allow` per language | ✅ Active |
| Outbound Traffic Proxy | iptables (best-effort) | ⚠️ Best-effort |
| Apex Controls | Not yet | ⏳ Phase 4 |
