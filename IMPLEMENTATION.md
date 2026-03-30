# Implementation Guide — Capital Group Claude Code Dev Container Platform

## Prerequisites

Before starting, ensure you have:

| Tool | Version | Purpose |
|---|---|---|
| Docker Desktop | 4.x+ | Container runtime |
| VS Code | Latest | IDE |
| Dev Containers extension | Latest | `ms-vscode-remote.remote-containers` |
| Node.js | 18+ | devcontainer CLI |
| AWS CLI | v2 | S3 and Bedrock access |
| GitHub account | — | GHCR registry access |
| AWS account | — | Bedrock + S3 |

---

## Part 1: One-Time Platform Setup

### Step 1: Clone the Repository

```bash
git clone https://github.com/ashrujitpal1/devcontainer-feature-cg.git
cd devcontainer-feature-cg
```

### Step 2: Install devcontainer CLI

```bash
npm install -g @devcontainers/cli
devcontainer --version
```

### Step 3: Configure AWS Credentials

Ensure AWS credentials are configured on your host machine:

```bash
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output (json)

# Verify
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "...",
    "Account": "696072349808",
    "Arn": "arn:aws:iam::696072349808:user/administrator"
}
```

### Step 4: Create the S3 Policy Bucket

```bash
# Create bucket
aws s3api create-bucket \
  --bucket capital-group-claude-policies \
  --region us-east-1

# Block public access
aws s3api put-public-access-block \
  --bucket capital-group-claude-policies \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket capital-group-claude-policies \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket capital-group-claude-policies \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

### Step 5: Push Initial Policy Manifest to S3

```bash
aws s3 sync ./layer3-policy/ \
  s3://capital-group-claude-policies/latest/ \
  --no-progress

# Verify
aws s3 ls s3://capital-group-claude-policies/latest/
aws s3 cp s3://capital-group-claude-policies/latest/manifest.json - | jq .
```

Expected: `manifest.json` with `"deltaReleases": []`

### Step 6: Login to GHCR

```bash
echo "<YOUR_GITHUB_PAT>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

PAT requires scopes: `repo`, `write:packages`, `workflow`

### Step 7: Build and Push the Base Image (Layer 1)

```bash
cd layer1-base-image

# Read version from manifest
VERSION=$(jq -r '.version' managed-settings/manifest.json)

docker build \
  -t ghcr.io/<your-github-username>/devcontainer-feature-cg/claude-base:${VERSION} \
  -t ghcr.io/<your-github-username>/devcontainer-feature-cg/claude-base:latest \
  .

docker push ghcr.io/<your-github-username>/devcontainer-feature-cg/claude-base:${VERSION}
docker push ghcr.io/<your-github-username>/devcontainer-feature-cg/claude-base:latest

cd ..
```

Build time: ~3-5 minutes (first time). Subsequent builds use cache.
The image is tagged with both the version from `manifest.json` (e.g., `1.0.0`) and `latest`.
Developer templates pin to the version tag; `latest` is kept for CI convenience.

Verify the image works:
```bash
docker run --rm --user root \
  -e CLAUDE_CONFIG_DIR=/root/.claude \
  -e SECURITY_POLICY_SOURCE=local \
  ghcr.io/<your-github-username>/devcontainer-feature-cg/claude-base:1.0.0 \
  /bin/bash -c "/usr/local/bin/apply-security-policy.sh && echo SUCCESS"
```

Expected: Script runs, prints log lines to stderr, exits 0.

### Step 8: Publish Layer 2 Features to GHCR

Publish each feature individually:

```bash
# Java
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/java

# Python
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/python

# Node
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/node

# Go
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/go

# Approved IDE Tools (VS Code)
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/approved-ide-tools/vscode
```

Each publish outputs the GHCR path and digest. Verify:
```bash
docker manifest inspect ghcr.io/<your-github-username>/devcontainer-feature-cg/java:1
```

### Step 9: Make GHCR Packages Public

By default GHCR packages are private. Make them public so developers can pull without authentication:

1. Go to `https://github.com/<your-username>?tab=packages`
2. For each package (`claude-base`, `java`, `python`, `node`, `go`, `approved-ide-tools-vscode`):
   - Click the package
   - Click **Package settings**
   - Scroll to **Danger Zone** → **Change visibility** → **Public**

---

## Part 2: Developer Onboarding

### Step 10: Developer Gets the Template

Developer picks the template matching their project stack:

```bash
# Clone the platform repo to get templates
git clone https://github.com/ashrujitpal1/devcontainer-feature-cg.git

# Copy the appropriate template into their project
# For Java:
cp -r devcontainer-feature-cg/developer-templates/java/.devcontainer /path/to/my-project/

# For Python:
cp -r devcontainer-feature-cg/developer-templates/python/.devcontainer /path/to/my-project/

# For Node:
cp -r devcontainer-feature-cg/developer-templates/node/.devcontainer /path/to/my-project/

# For Java + Python + Node:
cp -r devcontainer-feature-cg/developer-templates/fullstack/.devcontainer /path/to/my-project/
```

### Step 11: Update devcontainer.json with Correct Namespace

If you used a different GitHub username than `ashrujitpal1`, update the references:

```bash
cd /path/to/my-project/.devcontainer

# Replace namespace in devcontainer.json
sed -i 's|ashrujitpal1/devcontainer-feature-cg|<your-github-username>/devcontainer-feature-cg|g' devcontainer.json
```

### Step 12: Open Project in VS Code and Rebuild

```bash
cd /path/to/my-project
code .
```

In VS Code:
1. Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
2. Type: `Dev Containers: Rebuild Container`
3. Press Enter

VS Code will:
1. Pull `claude-base:1.0.0` from GHCR (~30s first time, instant if cached)
2. Install language features (~2-3 min first time, cached after)
3. Start container
4. Run `apply-security-policy.sh` (~5s)
5. Open workspace

Total: ~3-5 min first time, ~30-50s subsequent launches.

### Step 13: Verify Inside the Container

Open a terminal in VS Code (`` Ctrl+` ``):

```bash
# Verify Claude Code CLI
claude --version

# Verify language runtime (Java example)
java -version
mvn --version

# Verify managed settings were applied
cat /root/.claude/settings.json | jq '{deny_count: .permissions.deny|length}'

# Check policy apply log
cat /tmp/cg-policy-apply.log

# Verify AWS credentials work
aws sts get-caller-identity
```

---

## Part 3: Security Policy Updates (Biweekly/Monthly)

### Step 14: Adding a New Security Control

When the security team needs to add a new control:

**A. Update COPY 1 (image baseline):**

```bash
# Edit the single unified settings file
vim layer1-base-image/managed-settings/settings.json

# Example: add a new deny entry
# "Bash(telnet:*)" to permissions.deny array

# Bump the baseline manifest version
vim layer1-base-image/managed-settings/manifest.json
# Change "version": "1.0.0" to "version": "1.1.0"
```

**B. Update COPY 2 (S3 versioned delta):**

```bash
# Create a versioned delta file with ONLY the new control
cat > layer3-policy/delta-1.1.0.json << 'EOF'
{
  "permissions": {
    "deny": [
      "Bash(telnet:*)"
    ]
  }
}
EOF

# Add the new release entry to the S3 manifest
vim layer3-policy/manifest.json
# Add to deltaReleases array:
#   {"version": "1.1.0", "file": "delta-1.1.0.json", "releaseDate": "2025-02-01", "description": "Add telnet to deny list"}
```

**C. Rebuild base image and push:**

```bash
cd layer1-base-image
VERSION=$(jq -r '.version' managed-settings/manifest.json)
docker build \
  -t ghcr.io/<username>/devcontainer-feature-cg/claude-base:${VERSION} \
  -t ghcr.io/<username>/devcontainer-feature-cg/claude-base:latest \
  .
docker push ghcr.io/<username>/devcontainer-feature-cg/claude-base:${VERSION}
docker push ghcr.io/<username>/devcontainer-feature-cg/claude-base:latest
cd ..
```

**D. Update developer templates to reference the new version tag:**

Update the `image` field in all developer templates under `developer-templates/`:
```json
"image": "ghcr.io/<username>/devcontainer-feature-cg/claude-base:1.1.0"
```

**E. Upload delta to S3 (never delete old deltas):**

```bash
# Upload the new delta file and updated manifest
aws s3 cp ./layer3-policy/delta-1.1.0.json \
  s3://capital-group-claude-policies/latest/delta-1.1.0.json \
  --no-progress

aws s3 cp ./layer3-policy/manifest.json \
  s3://capital-group-claude-policies/latest/manifest.json \
  --no-progress

# Verify
aws s3 cp s3://capital-group-claude-policies/latest/manifest.json - | jq .
```

**F. Commit and push:**

```bash
git add -A
git commit -m "security: add telnet to deny list (v1.1.0)"
git push origin main
```

Developers get the new control on their **next container start** — no rebuild required.

---

## Part 4: Feature Updates

### Step 15: Updating a Feature Version

When a language feature needs updating (e.g., new Java version support):

```bash
# Edit the feature
vim src/java/install.sh
# or
vim src/java/devcontainer-feature.json

# Bump the version in devcontainer-feature.json
# "version": "1.0.1" → "version": "1.0.2"

# Republish
devcontainer features publish \
  --namespace <your-github-username>/devcontainer-feature-cg \
  --registry ghcr.io \
  ./src/java

# Commit
git add -A
git commit -m "feat: java feature v1.0.2 — add JDK 22 support"
git push origin main
```

Developers get the new feature version on their **next Rebuild**.

---

## Part 5: Troubleshooting

### Container fails to start — postStartCommand error

Check the policy apply log:
```bash
# In the container terminal
cat /tmp/cg-policy-apply.log
```

Common causes:
- `Permission denied` on `/etc/cg-managed-settings/` → directory needs `chmod 755`
- `parse error: Invalid numeric literal` → `log()` writing to stdout instead of stderr
- `S3 fetch failed` → AWS credentials not mounted or expired

### Feature install fails — package not found

Common causes:
- Java: `openjdk-21-jdk not found` → use Eclipse Temurin (already fixed in v1.0.1)
- Python: `python3.12 not found` → use deadsnakes PPA (already fixed in v1.0.1)
- Node: version not in NodeSource → check supported versions

### AWS credentials not working

```bash
# In container terminal
aws sts get-caller-identity

# If fails, check mount
ls -la /root/.aws/

# Check credentials file
cat /root/.aws/credentials
```

Ensure `~/.aws/credentials` exists on the host machine before rebuilding.

### Claude Code not connecting to Bedrock

```bash
# Verify environment variables
echo $CLAUDE_CODE_USE_BEDROCK   # should be 1
echo $AWS_REGION                # should be us-east-1
echo $AWS_PROFILE               # should be default

# Test Bedrock access directly
aws bedrock list-foundation-models --region us-east-1 | jq '.modelSummaries[0].modelId'
```

---

## Part 6: CI/CD Automation (GitHub Actions)

The repository includes three workflows that automate everything above:

### release.yaml — Triggered on push to main

Runs three jobs in parallel:
1. **publish-features** — publishes all `src/` features to GHCR
2. **publish-base-image** — builds and pushes base image to GHCR
3. **publish-policy-s3** — syncs `layer3-policy/` to S3 (after base image)

Required GitHub secrets:
- `AWS_POLICY_PUBLISH_ROLE_ARN` — IAM role ARN for S3 publish

### test.yaml — Triggered on push/PR

Tests all features against the base image using `devcontainer features test`.

### validate.yaml — Triggered on PR

Validates all `devcontainer-feature.json` files for schema compliance.

---

## Quick Reference

### Rebuild base image
```bash
cd layer1-base-image
VERSION=$(jq -r '.version' managed-settings/manifest.json)
docker build -t ghcr.io/<user>/devcontainer-feature-cg/claude-base:${VERSION} -t ghcr.io/<user>/devcontainer-feature-cg/claude-base:latest .
docker push ghcr.io/<user>/devcontainer-feature-cg/claude-base:${VERSION}
docker push ghcr.io/<user>/devcontainer-feature-cg/claude-base:latest
```

### Republish a feature
```bash
devcontainer features publish --namespace <user>/devcontainer-feature-cg --registry ghcr.io ./src/<feature>
```

### Upload new delta to S3
```bash
aws s3 cp ./layer3-policy/delta-X.Y.Z.json s3://capital-group-claude-policies/latest/delta-X.Y.Z.json
aws s3 cp ./layer3-policy/manifest.json s3://capital-group-claude-policies/latest/manifest.json
```

### Test policy script locally
```bash
docker run --rm --user root -e CLAUDE_CONFIG_DIR=/root/.claude -e SECURITY_POLICY_SOURCE=local ghcr.io/<user>/devcontainer-feature-cg/claude-base:1.0.0 /bin/bash -c "/usr/local/bin/apply-security-policy.sh && cat /root/.claude/settings.json | jq ."
```

### Check what's in S3
```bash
aws s3 ls s3://capital-group-claude-policies/latest/
aws s3 cp s3://capital-group-claude-policies/latest/manifest.json - | jq .
# Shows all versioned delta releases and their files
```
