# Claude Code Dev Container Architecture — Capital Group

## Document Purpose

This document describes the architecture for rolling out Claude Code via Dev Containers
at Capital Group. It covers the 3-layer design, security control enforcement, dual-delivery
policy mechanism, and the developer experience.

**Implementation Status:** Phase 1 complete and validated.
**Registry:** `ghcr.io/ashrujitpal1/devcontainer-feature-cg`
**S3 Policy Bucket:** `capital-group-claude-policies`

---

## Phase 1: Architecture Overview

### Design Principles

1. Security policy is delivered by design, not by developer cooperation
2. Developer workflow (Rebuild and Reopen in Container) is never disrupted
3. Security controls are maintained in TWO places simultaneously — image baseline AND S3 versioned deltas
4. S3 holds VERSIONED DELTAS only — each release is a separate file, never overwritten
5. Image holds the FULL baseline — always the policy floor, works even when S3 is unreachable
6. Version matching ensures only deltas newer than the image baseline are applied
7. Container ready time stays under 1 minute
8. Developers choose their languages freely within approved boundaries
9. Single unified policy — no language-specific settings files
10. Two enforcement surfaces that Capital Group owns: Claude Managed Settings + Bedrock IAM

---

### The Dual-Delivery Policy Principle

Every security control change is published to TWO places at the same time:

```
Security Team commits new control
              │
              ▼
        CI/CD Pipeline
         /           \
        /             \
       ▼               ▼
Layer 1 Image       S3 Bucket
managed-settings/   layer3-policy/
settings.json       delta-X.Y.Z.json (versioned, never overwritten)
(updated baseline)

Baked into the      Fetched at every
next image build    container start
Acts as the         Acts as the
policy FLOOR        policy DELTA SOURCE
```

**Critical distinctions:**
- S3 does NOT hold a full copy — it holds only VERSIONED DELTAS (one file per release)
- Each delta file is named `delta-X.Y.Z.json` and is never overwritten
- At runtime: `merged result = COPY 1 (image baseline) + applicable S3 deltas (version > baseline)`
- Version matching: script reads image baseline version from manifest.json, fetches only deltas with higher version
- At v1.0.0 initial release: S3 deltaReleases is empty — image baseline is the full policy
- Single unified policy — all language permissions are in one `settings.json`

Why both?

- S3 alone: if S3 is unreachable, developer gets NO policy
- Image alone: developer must rebuild to get new controls — violates "upon launching" requirement
- Both together: S3 delivers freshness (versioned deltas), image delivers resilience (full baseline)

---

### The 3-Layer Model

```
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 1: Base Platform Image                                        │
│ Owner: Platform Team | Built by: CI/CD | Changes: Monthly          │
│ Registry: ghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base │
│                                                                     │
│  - node:20 base (Debian Bookworm)                                   │
│  - Core utils: git, zsh, curl, jq, awscli, iptables, fzf           │
│  - Claude Code CLI (latest)                                         │
│  - git-delta, zsh-in-docker (Powerlevel10k)                        │
│  - COPY 1: /etc/cg-managed-settings/ (policy floor, chmod 755/444) │
│    ├── manifest.json      (version metadata — used for matching)    │
│    └── settings.json      (single unified policy — all languages)   │
│  - apply-security-policy.sh (baked in, runs at every start)        │
│  - init-firewall.sh (best-effort egress control until Apex)        │
│  - NO language runtimes                                             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 2: Language and Tooling (Dev Container Features)              │
│ Owner: Developer | Changes: When project needs change               │
│ Registry: ghcr.io/ashrujitpal1/devcontainer-feature-cg/<feature>   │
│                                                                     │
│  Developer picks from APPROVED Capital Group features:              │
│  - .../java:1        Java 21/17/11 via Eclipse Temurin + Maven      │
│  - .../python:1      Python 3.12/3.11/3.10 via deadsnakes PPA      │
│  - .../node:1        Node.js 22/20/18 via NodeSource                │
│  - .../go:1          Go 1.22/1.21 via go.dev                       │
│  - .../approved-ide-tools-vscode:1  Linters, formatters, gitleaks  │
│                                                                     │
│  Cached in Docker layer after first build — no rebuild cost         │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 3: Security Policy (postStartCommand)                         │
│ Owner: Security Team | Changes: Biweekly/Monthly | Rebuild: NEVER  │
│ Source: s3://capital-group-claude-policies/latest/                  │
│                                                                     │
│  Runs at EVERY container start via apply-security-policy.sh:        │
│  1. Read image baseline version from manifest.json                  │
│  2. Fetch S3 delta manifest — check deltaReleases                   │
│  3. Version match: download only deltas with version > baseline     │
│  4. Merge COPY 1 + applicable deltas (in version order)             │
│  5. Write to ~/.claude/settings.json (Claude managed path)          │
│     → Highest priority — cannot be overridden by developer          │
│  6. Emit audit event (baseline version, delta versions applied)     │
│                                                                     │
│  Key: each delta is a separate file (delta-X.Y.Z.json), never      │
│  overwritten. If developer hasn't rebuilt, ALL missed deltas are    │
│  applied in order.                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Phase 2: System Context Diagram

```mermaid
graph TB
    subgraph DEV["Developer Workstation (Local)"]
        VS["VS Code\n'Rebuild and Reopen in Container'"]
        DD["Docker Desktop"]
        subgraph DC["Dev Container"]
            L1["Layer 1: Base Image\nghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:1.0.0\nContains: COPY 1 full baseline policy (single unified settings.json)"]
            L2["Layer 2: Features\nJava / Python / Node / Go\nghcr.io/ashrujitpal1/devcontainer-feature-cg/<feature>:1"]
            L3["Layer 3: apply-security-policy.sh\npostStartCommand — runs every start\nVersion-matches and merges COPY1 + applicable S3 deltas"]
            CC["Claude Code CLI"]
            MS["~/.claude/settings.json\nManaged Policy — highest priority\nWritten fresh at every start"]
        end
    end

    subgraph POLICY_SOURCES["Policy Sources — Dual Delivery"]
        S3["S3 Bucket\ncapital-group-claude-policies/latest/\nVersioned deltas — one file per release\nOnly deltas > image version applied"]
        IMG_POL["Image Baseline /etc/cg-managed-settings/\nCOPY 1 — Single unified policy\nAlways present, works offline"]
    end

    subgraph AWS["AWS (Account: 696072349808)"]
        BEDROCK["AWS Bedrock\nClaude Sonnet 4\nus.anthropic.claude-sonnet-4-6"]
        IAM["IAM Policy\nPer-developer role\nbedrock:InvokeModel only"]
        CT["CloudTrail\nAudit log of all Bedrock calls"]
        CW["CloudWatch\nUsage metrics + alerts"]
    end

    subgraph CICD["CI/CD Pipeline (GitHub Actions)\nghcr.io/ashrujitpal1/devcontainer-feature-cg"]
        SEC_COMMIT["Security Team Commits\nNew Control"]
        IMG_BUILD["Base Image Build\nUpdates settings.json in image\nBumps manifest version"]
        S3_PUBLISH["Policy Publish\nAdds new delta-X.Y.Z.json to S3\nUpdates manifest deltaReleases"]
        REG["Container Registry\nghcr.io/ashrujitpal1"]
    end

    VS --> DD --> DC
    SEC_COMMIT -->|"triggers"| IMG_BUILD
    SEC_COMMIT -->|"triggers"| S3_PUBLISH
    IMG_BUILD -->|"push image with new baseline"| REG
    S3_PUBLISH -->|"aws s3 cp delta file + manifest"| S3
    REG -->|"docker pull"| L1
    L3 -->|"1. fetch S3 manifest, version-match"| S3
    L3 -->|"2. always start from"| IMG_POL
    L3 -->|"3. write merged result"| MS
    MS -->|"enforces controls"| CC
    CC -->|"bedrock:InvokeModel\nvia IAM role"| BEDROCK
    BEDROCK --> IAM
    BEDROCK --> CT
    BEDROCK --> CW
```

---

## Phase 3: Versioned Delta Policy Mechanism (Core Design)

```mermaid
flowchart TD
    SEC["Security Team\nCommits new control to policy repo"]
    SEC --> CICD["CI/CD Pipeline triggers"]

    CICD --> COPY1["Update COPY 1\nAdd new control to settings.json\nBump manifest version to X.Y.Z\nRebuild base image\nPush to GHCR"]

    CICD --> COPY2["Update COPY 2\nCreate delta-X.Y.Z.json with new controls\nAdd entry to manifest.json deltaReleases\nSync to S3"]

    COPY1 --> IMG_NOTE["Image is the FLOOR\nSingle unified policy\nWorks even when S3 is down\nUpdated monthly"]

    COPY2 --> S3_NOTE["S3 is the DELTA SOURCE\nEach release = separate versioned file\nNever overwritten\nDeveloper gets on next container START"]

    IMG_NOTE --> RUNTIME["Container Start\napply-security-policy.sh"]
    S3_NOTE --> RUNTIME

    RUNTIME --> STEP1["Step 1: Read image baseline version\nfrom /etc/cg-managed-settings/manifest.json"]
    STEP1 --> STEP2["Step 2: Fetch S3 manifest\nCheck deltaReleases"]
    STEP2 --> DECISION{Any delta version > baseline?}

    DECISION -->|"Yes"| DOWNLOAD["Download only applicable deltas\n(version > baseline)"]
    DECISION -->|"No / S3 unreachable"| BASELINE_ONLY["Use image baseline only\nAudit: source=no-delta"]

    DOWNLOAD --> MERGE["Merge deltas in version order\non top of baseline"]
    MERGE --> WRITE["Write ~/.claude/settings.json\nManaged path — highest priority"]
    BASELINE_ONLY --> WRITE

    WRITE --> AUDIT["Emit audit event\nbaselineVersion + highest delta applied"]
```

### Example: Version Matching in Action

```
Image baseline version: 1.0.0

S3 manifest deltaReleases:
  - delta-1.1.0.json  (version: 1.1.0)  → 1.1.0 > 1.0.0 ✅ APPLY
  - delta-1.2.0.json  (version: 1.2.0)  → 1.2.0 > 1.0.0 ✅ APPLY
  - delta-1.3.0.json  (version: 1.3.0)  → 1.3.0 > 1.0.0 ✅ APPLY

Developer rebuilds image → new baseline version: 1.3.0

Next container start:
  - delta-1.1.0.json  (version: 1.1.0)  → 1.1.0 > 1.3.0 ❌ SKIP (already in baseline)
  - delta-1.2.0.json  (version: 1.2.0)  → 1.2.0 > 1.3.0 ❌ SKIP (already in baseline)
  - delta-1.3.0.json  (version: 1.3.0)  → 1.3.0 > 1.3.0 ❌ SKIP (already in baseline)

Security team releases 1.4.0:
  - delta-1.4.0.json  (version: 1.4.0)  → 1.4.0 > 1.3.0 ✅ APPLY
```

---

## Phase 4: Security Control Enforcement Map

```mermaid
graph LR
    subgraph CONTROLS["Security Controls"]
        C1["MCP HTTP Whitelist\nTenant: Claude Settings"]
        C2["Deny List\nDefault allow, grow deny list\nTenant: Claude Settings"]
        C3["File System Isolation\nTenant: Claude Settings"]
        C4["Tool Extension Allowlist\nTenant: Claude Settings\nPhase 2 — pending"]
        C5["Outbound Traffic Proxy\nTenant: Apex — FUTURE"]
        C6["Private Model Routes\nTenant: Apex + IAM"]
    end

    subgraph DELIVERY["Dual Delivery"]
        D1["COPY 1\nImage baseline\n/etc/cg-managed-settings/settings.json\nSingle unified policy"]
        D2["COPY 2\nS3 versioned deltas\ns3://capital-group-claude-policies/latest/\ndelta-X.Y.Z.json files"]
    end

    subgraph ENFORCEMENT["Enforcement Surface"]
        MS["Claude Managed Settings\n~/.claude/settings.json\nHighest priority in Claude hierarchy\nCannot be overridden by developer"]
        IAM["Bedrock IAM Policy\nServer-side\nDeveloper cannot change\nAccount: 696072349808"]
        FW["Container iptables\nBest-effort until Apex\ninit-firewall.sh"]
    end

    C1 --> D1 & D2 -->|"mcpServers.httpWhitelist"| MS
    C2 --> D1 & D2 -->|"permissions.deny"| MS
    C3 --> D1 & D2 -->|"fileSystemIsolation"| MS
    C4 --> D1 & D2 -->|"permissions.allow — Phase 2"| MS
    C5 -->|"best-effort today"| FW
    C6 -->|"model ARN restriction"| IAM
    C6 --> D1 & D2 -->|"model config"| MS
```

---

## Phase 5: Claude Settings Hierarchy

```mermaid
graph TB
    subgraph HIERARCHY["Claude Code Settings Hierarchy — Highest to Lowest Priority"]
        M["1. Managed Settings\n~/.claude/settings.json\nWritten by apply-security-policy.sh at every start\nSource: COPY1 merged with applicable S3 deltas\nCannot be overridden by anything below"]
        L["2. Local User Settings\n~/.claude/settings.local.json\nDeveloper personal preferences"]
        P["3. Project Settings\n.claude/settings.json in repo\nProject-specific permissions"]
        PL["4. Project Local Settings\n.claude/settings.local.json in repo\nLowest priority"]
    end

    M -->|"overrides"| L
    L -->|"overrides"| P
    P -->|"overrides"| PL

    subgraph DELIVERY["How Managed Settings Are Built"]
        C1["COPY 1: /etc/cg-managed-settings/settings.json\nSingle unified policy — always the starting point"]
        C2["COPY 2: S3 versioned deltas\ndelta-X.Y.Z.json files\nOnly versions > baseline applied"]
        SCRIPT["apply-security-policy.sh\nRuns at every container start\nVersion-matches and merges in order"]
    end

    C1 -->|"base"| SCRIPT
    C2 -->|"applicable deltas merged on top"| SCRIPT
    SCRIPT -->|"writes final result"| M
```

---

## Phase 6: Container Startup Sequence

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant VS as VS Code
    participant DD as Docker Desktop
    participant REG as GHCR Registry
    participant DC as Dev Container
    participant S3 as S3 Policy Bucket

    Dev->>VS: Rebuild and Reopen in Container
    VS->>DD: docker pull claude-base:1.0.0
    DD->>REG: Pull base image (cached if unchanged)
    Note over DD,REG: Image contains COPY 1 unified policy + manifest v1.0.0
    REG-->>DD: Image layers (incremental pull)
    DD->>DC: Apply Layer 2 features (java/python/node — cached after first build)
    DC->>DC: Container starts
    DC->>DC: postStartCommand → apply-security-policy.sh
    DC->>DC: Read baseline version from manifest.json (e.g. v1.0.0)
    DC->>S3: Fetch manifest.json (check deltaReleases)
    alt No deltas > baseline version
        S3-->>DC: manifest.json — no applicable deltas
        DC->>DC: Use COPY 1 image baseline only
    else Deltas found > baseline version
        S3-->>DC: manifest.json lists delta-1.1.0.json, delta-1.2.0.json
        DC->>S3: Download each applicable delta file
        DC->>DC: Merge COPY 1 + deltas in version order
    else S3 unreachable
        DC->>DC: Use COPY 1 image baseline only
        DC->>DC: Log WARN: S3 unreachable
    end
    DC->>DC: Write ~/.claude/settings.json (managed path)
    DC->>DC: Emit audit event (baselineVersion, highest delta applied)
    DC-->>VS: Container ready
    VS-->>Dev: Dev Container open (~50 seconds)
```

---

## Phase 7: Policy Update Flow (Biweekly/Monthly)

```mermaid
sequenceDiagram
    actor SEC as Security Team
    participant GIT as GitHub Repo
    participant CICD as GitHub Actions
    participant IMG as GHCR Registry
    participant S3 as S3 Policy Bucket
    participant DC as Dev Container

    SEC->>GIT: Commit new security control
    Note over SEC,GIT: e.g., add entry to deny list
    GIT->>CICD: Trigger release.yaml workflow

    par COPY 1 — Update image baseline
        CICD->>CICD: Update managed-settings/settings.json
        CICD->>CICD: Bump manifest.json version to 1.1.0
        CICD->>IMG: Push claude-base:1.1.0 with new baseline
    and COPY 2 — Add versioned delta to S3
        CICD->>CICD: Create delta-1.1.0.json with new controls only
        CICD->>CICD: Add entry to manifest.json deltaReleases
        CICD->>S3: Upload delta-1.1.0.json + updated manifest.json
        Note over CICD,S3: File is never overwritten — immutable release
    end

    DC->>DC: Developer does Reopen in Container (image still v1.0.0)
    DC->>S3: Fetch manifest — delta-1.1.0 version 1.1.0 > baseline 1.0.0
    S3-->>DC: delta-1.1.0.json downloaded
    DC->>DC: Merge baseline + delta → write managed settings
    Note over DC: Developer gets new control without rebuilding image
```

---

## Phase 8: Bedrock IAM Enforcement

```mermaid
graph LR
    subgraph DEV["Developer"]
        CLI["Claude Code CLI\nInside Dev Container"]
        CREDS["AWS Credentials\n~/.aws mounted read-only\nfrom host machine"]
    end

    subgraph IAM_LAYER["AWS IAM (Capital Group owns — immutable to developer)"]
        ROLE["Per-Developer IAM Role\nvia AWS SSO / Identity Center"]
        POLICY["IAM Policy\nbedrock:InvokeModel only\nSpecific model ARNs\nRegion: us-east-1"]
        BOUNDARY["Permission Boundary\nCannot escalate beyond\nbedrock:InvokeModel"]
    end

    subgraph BEDROCK_LAYER["AWS Bedrock (Account: 696072349808)"]
        MODEL["Allowed Model\nus.anthropic.claude-sonnet-4-6\nus.anthropic.claude-haiku-3-5"]
        BLOCKED["Blocked\nDirect Anthropic API\nUnauthorized model ARNs\nOther regions"]
        CT["CloudTrail\nEvery call logged\nIAM identity + timestamp"]
    end

    CLI -->|"assumes role"| ROLE
    CREDS --> CLI
    ROLE --> POLICY --> BOUNDARY
    BOUNDARY -->|"allows"| MODEL
    BOUNDARY -->|"denies"| BLOCKED
    MODEL --> CT
```

---

## Summary Tables

### Published Assets (Current State)

| Asset | Registry / Location | Version | Status |
|---|---|---|---|
| Base Image | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:1.0.0` | 1.0.0 | ✅ Live |
| Java Feature | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/java:1` | 1.0.1 | ✅ Live |
| Python Feature | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/python:1` | 1.0.1 | ✅ Live |
| Node Feature | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/node:1` | 1.0.0 | ✅ Live |
| Go Feature | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/go:1` | 1.0.0 | ✅ Live |
| Approved IDE Tools | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/approved-ide-tools-vscode:1` | 1.0.0 | ✅ Live |
| S3 Policy Bucket | `s3://capital-group-claude-policies/latest/` | v1.0.0 | ✅ Live |

### Enforcement Model

| Security Control | Enforcement Surface | Delivery | Status |
|---|---|---|---|
| MCP HTTP Whitelist | Claude Managed Settings | COPY 1 (image) | ✅ Active Phase 1 |
| Deny List | Claude Managed Settings | COPY 1 (image) | ✅ Active Phase 1 |
| File System Isolation | Claude Managed Settings | COPY 1 (image) | ✅ Active Phase 1 |
| Tool Extension Allowlist | Claude Managed Settings | COPY 1 + COPY 2 | ⏳ Phase 2 |
| Outbound Traffic Proxy | Apex Gateway | Apex | ⏳ Phase 4 |
| Private Model Routes | Bedrock IAM | IAM Policy | ✅ Active Phase 1 |

### Policy Source Behaviour

| Scenario | Source Used | Result | Audit Log |
|---|---|---|---|
| Normal, no new controls | COPY 1 image baseline | Floor policy | `deltaSource=no-delta` |
| New controls released, dev hasn't rebuilt | COPY 1 + all deltas > baseline | Latest policy | `deltaSource=s3` |
| Dev rebuilt image (latest baseline) | COPY 1 only (no applicable deltas) | Latest policy | `deltaSource=no-delta` |
| S3 unreachable | COPY 1 image baseline | Floor policy | `deltaSource=no-delta, WARN` |

### Layer Rebuild Trigger

| Layer | Trigger | Who | Developer Impact |
|---|---|---|---|
| Layer 1 Base Image | Claude CLI bump, OS patch, new tool | Platform team CI/CD | docker pull on next Rebuild |
| Layer 2 Features | Developer adds/removes language | Developer | One-time install, cached after |
| Layer 3 Security Policy | Biweekly/monthly control change | Security team CI/CD | Zero rebuild — applied at start |

---

## Key Implementation Notes

1. **log() must write to stderr** — `log()` redirects to `>&2` so log lines never pollute stdout captured by `$()` command substitution.

2. **Directory permissions** — `/etc/cg-managed-settings/` must be `755` (traversable), files `444` (read-only).

3. **Single unified policy** — All language permissions (java, python, node, go) are in one `settings.json`. Security team maintains one file only.

4. **Versioned deltas** — Each S3 delta is a separate file (`delta-X.Y.Z.json`), never overwritten. The manifest tracks all releases in `deltaReleases` array.

5. **Version matching** — Script reads baseline version from image manifest, compares against each delta's version using semver, and only applies deltas with version strictly greater than baseline.

6. **Missed updates are caught** — If a developer hasn't rebuilt their image for 3 releases (1.1.0, 1.2.0, 1.3.0), all three deltas are downloaded and merged in order on next container start.

7. **S3 holds delta only** — S3 is NOT a full copy of the image settings. It holds only new controls added since the last image build.
