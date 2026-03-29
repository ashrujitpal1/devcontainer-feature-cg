# Claude Code Dev Container Architecture — Capital Group

## Document Purpose

This document describes the architecture for rolling out Claude Code via Dev Containers
at Capital Group. It covers the 3-layer design, security control enforcement, dual-delivery
policy mechanism, multi-language support, and the developer experience.

**Implementation Status:** Phase 1 complete and validated.
**Registry:** `ghcr.io/ashrujitpal1/devcontainer-feature-cg`
**S3 Policy Bucket:** `capital-group-claude-policies`

---

## Phase 1: Architecture Overview

### Design Principles

1. Security policy is delivered by design, not by developer cooperation
2. Developer workflow (Rebuild and Reopen in Container) is never disrupted
3. Security controls are maintained in TWO places simultaneously — image baseline AND S3 delta
4. S3 holds DELTA only — new controls added since last image build (not a full copy)
5. Image holds the FULL baseline — always the policy floor, works even when S3 is unreachable
6. Security controls update without forcing image rebuilds on developers
7. Container ready time stays under 1 minute
8. Developers choose their languages freely within approved boundaries
9. Two enforcement surfaces that Capital Group owns: Claude Managed Settings + Bedrock IAM

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
(updated baseline)  (delta only — new controls
                     since last image build)

Baked into the      Fetched at every
next image build    container start
Acts as the         Acts as the
policy FLOOR        policy DELTA SOURCE
```

**Critical distinction:**
- S3 does NOT hold a full copy of all settings — it holds only the DELTA (new controls)
- At runtime: `merged result = COPY 1 (image baseline) + COPY 2 (S3 delta)`
- At v1.0.0 initial release: S3 delta is empty (`deltaFiles: []`) — image baseline is the full policy

Why both?

- S3 alone: if S3 is unreachable, developer gets NO policy
- Image alone: developer must rebuild to get new controls — violates "upon launching" requirement
- Both together: S3 delivers freshness (delta), image delivers resilience (full baseline)

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
│    ├── manifest.json      (version metadata)                        │
│    ├── settings.json      (base policy — all developers)            │
│    ├── settings-java.json (Java overlay)                            │
│    ├── settings-python.json (Python overlay)                        │
│    ├── settings-node.json (Node overlay)                            │
│    └── settings-go.json   (Go overlay)                              │
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
│  1. Detect installed language runtimes (java, python, node, go)     │
│  2. Fetch S3 delta manifest — check deltaFiles count                │
│     - deltaFiles = 0 → use image baseline only (COPY 1)            │
│     - deltaFiles > 0 → merge delta on top of baseline              │
│  3. Merge COPY 1 + COPY 2 delta + language-specific overlays       │
│  4. Write to ~/.claude/settings.json (Claude managed path)          │
│     → Highest priority — cannot be overridden by developer          │
│  5. Emit audit event (policy version, source, languages detected)   │
│                                                                     │
│  Key implementation note: log() writes to STDERR only to prevent   │
│  log lines from polluting JSON captured by $() substitution         │
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
            L1["Layer 1: Base Image\nghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:latest\nContains: COPY 1 full baseline policy"]
            L2["Layer 2: Features\nJava / Python / Node / Go\nghcr.io/ashrujitpal1/devcontainer-feature-cg/<feature>:1"]
            L3["Layer 3: apply-security-policy.sh\npostStartCommand — runs every start\nMerges COPY1 + COPY2 delta"]
            CC["Claude Code CLI"]
            MS["~/.claude/settings.json\nManaged Policy — highest priority\nWritten fresh at every start"]
        end
    end

    subgraph POLICY_SOURCES["Policy Sources — Dual Delivery"]
        S3["S3 Bucket\ncapital-group-claude-policies/latest/\nCOPY 2 — Delta only\nNew controls since last image build"]
        IMG_POL["Image Baseline /etc/cg-managed-settings/\nCOPY 1 — Full policy floor\nAlways present, works offline"]
    end

    subgraph AWS["AWS (Account: 696072349808)"]
        BEDROCK["AWS Bedrock\nClaude Sonnet 4\nus.anthropic.claude-sonnet-4-6"]
        IAM["IAM Policy\nPer-developer role\nbedrock:InvokeModel only"]
        CT["CloudTrail\nAudit log of all Bedrock calls"]
        CW["CloudWatch\nUsage metrics + alerts"]
    end

    subgraph CICD["CI/CD Pipeline (GitHub Actions)\nghcr.io/ashrujitpal1/devcontainer-feature-cg"]
        SEC_COMMIT["Security Team Commits\nNew Control"]
        IMG_BUILD["Base Image Build\nUpdates COPY 1 in image\n+ language overlays"]
        S3_PUBLISH["Policy Publish\nUpdates COPY 2 delta in S3\nmanifest.json + delta files only"]
        REG["Container Registry\nghcr.io/ashrujitpal1"]
    end

    subgraph APEX["Apex Gateway (Future)"]
        GW["MCP Gateway\nOutbound Proxy\nPrivate Model Routes"]
    end

    VS --> DD --> DC
    SEC_COMMIT -->|"triggers"| IMG_BUILD
    SEC_COMMIT -->|"triggers"| S3_PUBLISH
    IMG_BUILD -->|"push image with new baseline"| REG
    S3_PUBLISH -->|"aws s3 sync delta only"| S3
    REG -->|"docker pull"| L1
    L3 -->|"1. fetch S3 delta manifest"| S3
    L3 -->|"2. always start from"| IMG_POL
    L3 -->|"3. write merged result"| MS
    MS -->|"enforces controls"| CC
    CC -->|"bedrock:InvokeModel\nvia IAM role"| BEDROCK
    BEDROCK --> IAM
    BEDROCK --> CT
    BEDROCK --> CW
    CC -.->|"future routing"| GW
    GW -.->|"future"| BEDROCK
```

---

## Phase 3: Dual-Delivery Policy Mechanism (Core Design)

```mermaid
flowchart TD
    SEC["Security Team\nCommits new control to policy repo"]
    SEC --> CICD["CI/CD Pipeline triggers"]

    CICD --> COPY1["Update COPY 1\nAdd new control to managed-settings/settings.json\nRebuild base image\nPush to GHCR"]

    CICD --> COPY2["Update COPY 2\nAdd delta file to layer3-policy/\nUpdate manifest.json deltaFiles list\nSync to S3"]

    COPY1 --> IMG_NOTE["Image is the FLOOR\nFull baseline always present\nWorks even when S3 is down\nUpdated monthly"]

    COPY2 --> S3_NOTE["S3 is the DELTA SOURCE\nOnly new controls since last image build\nDeveloper gets on next container START\nNo rebuild needed"]

    IMG_NOTE --> RUNTIME["Container Start\napply-security-policy.sh"]
    S3_NOTE --> RUNTIME

    RUNTIME --> STEP1["Step 1: Load COPY 1\nimage baseline as starting point"]
    STEP1 --> STEP2["Step 2: Fetch S3 manifest\nCheck deltaFiles count"]
    STEP2 --> DECISION{deltaFiles > 0?}

    DECISION -->|"Yes"| MERGE_DELTA["Merge COPY 2 delta\non top of baseline"]
    DECISION -->|"No / S3 unreachable"| BASELINE_ONLY["Use image baseline only\nAudit: source=no-delta or S3-fail"]

    MERGE_DELTA --> LANG["Merge language overlays\n(java/python/node/go detected)"]
    BASELINE_ONLY --> LANG

    LANG --> WRITE["Write ~/.claude/settings.json\nManaged path — highest priority\nDeveloper cannot override"]
    WRITE --> AUDIT["Emit audit event\nbaselineVersion + deltaVersion\ndetectedLanguages + source"]
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
        D1["COPY 1\nImage baseline\n/etc/cg-managed-settings/\nFull policy floor"]
        D2["COPY 2\nS3 delta\ns3://capital-group-claude-policies/latest/\nNew controls only"]
    end

    subgraph ENFORCEMENT["Enforcement Surface"]
        MS["Claude Managed Settings\n~/.claude/settings.json\nHighest priority in Claude hierarchy\nCannot be overridden by developer"]
        IAM["Bedrock IAM Policy\nServer-side\nDeveloper cannot change\nAccount: 696072349808"]
        FW["Container iptables\nBest-effort until Apex\ninit-firewall.sh"]
        APEX["Apex Gateway\nFuture enforcement"]
    end

    C1 --> D1 & D2 -->|"mcpServers.httpWhitelist"| MS
    C2 --> D1 & D2 -->|"permissions.deny"| MS
    C3 --> D1 & D2 -->|"fileSystemIsolation"| MS
    C4 --> D1 & D2 -->|"permissions.allow — Phase 2"| MS
    C5 -->|"best-effort today"| FW
    C5 -.->|"enforced when ready"| APEX
    C6 -->|"model ARN restriction"| IAM
    C6 --> D1 & D2 -->|"model config"| MS
```

---

## Phase 5: Claude Settings Hierarchy

```mermaid
graph TB
    subgraph HIERARCHY["Claude Code Settings Hierarchy — Highest to Lowest Priority"]
        M["1. Managed Settings\n~/.claude/settings.json\nWritten by apply-security-policy.sh at every start\nSource: COPY1 merged with COPY2 delta\nCannot be overridden by anything below"]
        L["2. Local User Settings\n~/.claude/settings.local.json\nDeveloper personal preferences"]
        P["3. Project Settings\n.claude/settings.json in repo\nProject-specific permissions"]
        PL["4. Project Local Settings\n.claude/settings.local.json in repo\nLowest priority"]
    end

    M -->|"overrides"| L
    L -->|"overrides"| P
    P -->|"overrides"| PL

    subgraph DELIVERY["How Managed Settings Are Built"]
        C1["COPY 1: /etc/cg-managed-settings/settings.json\nFull baseline — always the starting point"]
        C2["COPY 2: S3 delta settings.json\nNew controls only — merged on top"]
        LANG["Language overlays\nsettings-java/python/node/go.json\nAuto-detected at runtime"]
        SCRIPT["apply-security-policy.sh\nRuns at every container start\nlog() → stderr only (critical)"]
    end

    C1 -->|"base"| SCRIPT
    C2 -->|"delta merged on top"| SCRIPT
    LANG -->|"language-aware merge"| SCRIPT
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
    participant CT as CloudTrail

    Dev->>VS: Rebuild and Reopen in Container
    VS->>DD: docker pull claude-base:latest
    DD->>REG: Pull base image (cached if unchanged)
    Note over DD,REG: Image contains COPY 1 full baseline in /etc/cg-managed-settings/
    REG-->>DD: Image layers (incremental pull)
    DD->>DC: Apply Layer 2 features (java/python/node — cached after first build)
    DC->>DC: Container starts
    DC->>DC: postStartCommand → apply-security-policy.sh
    DC->>DC: detect_languages() → java, python, node detected
    DC->>S3: Fetch manifest.json (check deltaFiles count)
    alt deltaFiles = 0 (initial release / no new controls)
        S3-->>DC: manifest.json — deltaFiles empty
        DC->>DC: Use COPY 1 image baseline only
    else deltaFiles > 0 (new controls released)
        S3-->>DC: manifest.json + delta settings files
        DC->>DC: Merge COPY 1 + COPY 2 delta
    else S3 unreachable
        DC->>DC: Use COPY 1 image baseline only
        DC->>DC: Log WARN: S3 unreachable
    end
    DC->>DC: Merge language overlays (java/python/node)
    DC->>DC: Write ~/.claude/settings.json (managed path)
    DC->>CT: Emit audit event (baselineVersion, deltaVersion, languages)
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
        CICD->>IMG: Push claude-base:latest with new baseline
        Note over CICD,IMG: New image is the updated floor
    and COPY 2 — Update S3 delta
        CICD->>CICD: Add delta file to layer3-policy/
        CICD->>CICD: Update manifest.json deltaFiles list
        CICD->>S3: aws s3 sync layer3-policy/ → latest/
        Note over CICD,S3: Immediately available — no developer action needed
    end

    DC->>DC: Developer does Reopen in Container
    DC->>S3: Fetch manifest — deltaFiles > 0
    S3-->>DC: Delta settings file with new control
    DC->>DC: Merge COPY1 + delta → write managed settings
```

---

## Phase 8: Multi-Language Architecture

```mermaid
graph TB
    subgraph BASE["Layer 1: One Base Image — Full Baseline Policy (COPY 1)"]
        BI["ghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:latest\nnode:20 base + Claude CLI + awscli + policy scripts\n/etc/cg-managed-settings/ — full baseline baked in"]
    end

    subgraph FEATURES["Layer 2: Developer Picks Capital Group Approved Features"]
        F1["java:1 v1.0.1\nEclipse Temurin JDK 21/17/11\nMaven + optional Gradle"]
        F2["python:1 v1.0.1\nPython 3.12/3.11/3.10\ndeadsnakes PPA on Debian Bookworm"]
        F3["node:1 v1.0.0\nNode.js 22/20/18\nNodeSource repo"]
        F4["go:1 v1.0.0\nGo 1.22/1.21\ngo.dev direct download"]
        F5["approved-ide-tools-vscode:1 v1.0.0\ngitleaks + eslint + prettier\nblack + pylint (language-aware)"]
    end

    subgraph POLICY["Layer 3: Language-Aware Policy Merge at Runtime"]
        BASE_S["settings.json\nBase deny list, MCP whitelist\nFile isolation, model config"]
        JAVA_S["settings-java.json\n+ mvn, gradle, javac\n+ /usr/lib/jvm, ~/.m2"]
        PY_S["settings-python.json\n+ python3, pip, pytest\n+ /usr/lib/python3*, ~/.cache/pip"]
        NODE_S["settings-node.json\n+ npm, npx, yarn\n+ /usr/local/lib/node_modules"]
        GO_S["settings-go.json\n+ go, gofmt\n+ /usr/local/go, ~/go"]
        MERGE["~/.claude/settings.json\nFinal merged result\nWritten at every container start"]
    end

    BI --> F1 & F2 & F3 & F4 & F5
    F1 & F2 & F3 & F4 & F5 --> BASE_S
    BASE_S --> MERGE
    JAVA_S -->|"if java detected"| MERGE
    PY_S -->|"if python3 detected"| MERGE
    NODE_S -->|"if node detected"| MERGE
    GO_S -->|"if go detected"| MERGE
```

---

## Phase 9: Bedrock IAM Enforcement

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

## Phase 10: Developer Experience

```mermaid
graph LR
    subgraph BEFORE["Before"]
        B1["devcontainer.json\npoints to local Dockerfile"]
        B2["Builds everything locally\n5-10 minutes"]
        B3["No security policy"]
        B4["No automatic updates"]
    end

    subgraph AFTER["After"]
        A1["devcontainer.json\npoints to pre-built image\n+ CG approved features"]
        A2["Image pulled from GHCR\n~50 seconds"]
        A3["Managed settings enforced\nat every container start"]
        A4["Policy updates automatic\nno developer action needed"]
    end

    subgraph UNCHANGED["Developer Workflow — UNCHANGED"]
        U["VS Code\nDev Containers extension\nRebuild and Reopen in Container\nSame command, same experience"]
    end

    B1 -.->|"migrates to"| A1
    B2 -.->|"improves to"| A2
    B3 -.->|"replaced by"| A3
    B4 -.->|"replaced by"| A4
```

---

## Phase 11: Rollout Gantt

```mermaid
gantt
    title Capital Group Claude Code Rollout
    dateFormat  YYYY-MM-DD

    section Phase 1 Foundation (COMPLETE)
    Base image + COPY 1 baseline           :done, p1a, 2025-02-01, 2w
    S3 bucket + COPY 2 delta setup         :done, p1b, 2025-02-01, 1w
    apply-security-policy.sh               :done, p1c, after p1b, 1w
    CG Features published to GHCR          :done, p1d, after p1a, 1w
    Java + Python validated                :done, p1e, after p1d, 1w

    section Phase 2 Security Controls
    MCP HTTP Whitelist active              :done, p2a, after p1e, 1w
    Deny List v1 active                    :done, p2b, after p2a, 1w
    File System Isolation active           :done, p2c, after p2b, 1w
    Tool Extension Allowlist               :p2d, after p2c, 1w
    Bedrock IAM per-developer roles        :p2e, after p1e, 2w

    section Phase 3 Broad Rollout
    Node + Go templates validated          :p3a, after p2d, 1w
    Full developer rollout                 :p3b, after p3a, 2w
    CloudTrail SIEM integration            :p3c, after p3b, 1w

    section Phase 4 Apex Integration
    Apex gateway deployment                :p4a, after p3c, 4w
    Outbound proxy enforcement             :p4b, after p4a, 2w
    Private model routes via Apex          :p4c, after p4b, 1w
    MCP gateway via Apex                   :p4d, after p4c, 1w
```

---

## Summary Tables

### Published Assets (Current State)

| Asset | Registry / Location | Version | Status |
|---|---|---|---|
| Base Image | `ghcr.io/ashrujitpal1/devcontainer-feature-cg/claude-base:latest` | latest | ✅ Live |
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
| New controls released | COPY 1 + COPY 2 delta | Latest policy | `deltaSource=s3` |
| S3 unreachable | COPY 1 image baseline | Floor policy | `deltaSource=no-delta, WARN` |

### Layer Rebuild Trigger

| Layer | Trigger | Who | Developer Impact |
|---|---|---|---|
| Layer 1 Base Image | Claude CLI bump, OS patch, new tool | Platform team CI/CD | docker pull on next Rebuild |
| Layer 2 Features | Developer adds/removes language | Developer | One-time install, cached after |
| Layer 3 Security Policy | Biweekly/monthly control change | Security team CI/CD | Zero rebuild — applied at start |

---

## Key Implementation Notes (Lessons Learned)

1. **log() must write to stderr** — `log()` redirects to `>&2` so log lines never pollute stdout captured by `$()` command substitution in `merge_settings()` and `fetch_delta_policy()`

2. **Directory permissions** — `/etc/cg-managed-settings/` must be `755` (traversable), files `444` (read-only). `chmod -R 444` incorrectly makes the directory untraversable.

3. **Java on Debian Bookworm** — `openjdk-21-jdk` is not in default Bookworm apt repo. Use Eclipse Temurin via Adoptium API instead.

4. **Python on Debian Bookworm** — `python3.12` requires deadsnakes PPA. Default Bookworm ships Python 3.11.

5. **S3 holds delta only** — S3 is NOT a full copy of the image settings. It holds only new controls added since the last image build. The merge is always `COPY1 + COPY2 delta`.

6. **GHCR namespace** — Features publish to `ghcr.io/<github-username>/<repo-name>/<feature-id>`, not `ghcr.io/<org>/features/<feature-id>`.
