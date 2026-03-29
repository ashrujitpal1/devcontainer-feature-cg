#!/bin/bash
set -euo pipefail

# =============================================================================
# apply-security-policy.sh
#
# Layer 3 — runs at EVERY container start via postStartCommand.
#
# Dual-delivery policy:
#   COPY 2 (primary)  : Fetch latest policy from S3 — always up to date
#   COPY 1 (fallback) : Image-bundled baseline at /etc/cg-managed-settings/
#
# Writes result to ~/.claude/settings.json (Claude managed settings path —
# highest priority in Claude's hierarchy, cannot be overridden by developer).
# =============================================================================

POLICY_S3_BUCKET="${SECURITY_POLICY_S3_BUCKET:-capital-group-claude-policies}"
POLICY_S3_PREFIX="${SECURITY_POLICY_S3_PREFIX:-latest}"
POLICY_LIVE_DIR="/tmp/cg-policy-live"
POLICY_BASELINE_DIR="/etc/cg-managed-settings"
CLAUDE_MANAGED_DIR="${CLAUDE_CONFIG_DIR:-/root/.claude}"
LOG_FILE="/tmp/cg-policy-apply.log"

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }
warn() { log "WARN: $*"; }

# ── Step 1: Detect installed language runtimes ────────────────────────────────
detect_languages() {
    local langs=()
    command -v java    &>/dev/null && langs+=("java")
    command -v python3 &>/dev/null && langs+=("python")
    command -v python  &>/dev/null && langs+=("python")
    command -v node    &>/dev/null && langs+=("node")
    command -v go      &>/dev/null && langs+=("go")
    # Deduplicate
    printf '%s\n' "${langs[@]}" | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ── Step 2: Fetch COPY 2 from S3 (primary source) ────────────────────────────
fetch_live_policy() {
    mkdir -p "$POLICY_LIVE_DIR"
    log "Fetching live policy from s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/"

    if aws s3 sync \
        "s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/" \
        "$POLICY_LIVE_DIR/" \
        --quiet --no-progress 2>>"$LOG_FILE"; then
        log "Live policy fetched successfully (COPY 2 — S3)"
        echo "s3"
        return 0
    else
        warn "S3 fetch failed — falling back to image baseline (COPY 1)"
        echo "image-fallback"
        return 1
    fi
}

# ── Step 3: Resolve which policy dir to use ──────────────────────────────────
resolve_policy_dir() {
    local source="$1"
    if [ "$source" = "s3" ] && [ -f "${POLICY_LIVE_DIR}/settings.json" ]; then
        echo "$POLICY_LIVE_DIR"
    else
        echo "$POLICY_BASELINE_DIR"
    fi
}

# ── Step 4: Merge base + language-specific overlays ──────────────────────────
merge_settings() {
    local policy_dir="$1"
    local detected_langs="$2"
    local base_file="${policy_dir}/settings.json"

    if [ ! -f "$base_file" ]; then
        warn "settings.json not found in ${policy_dir}"
        return 1
    fi

    local merged
    merged=$(cat "$base_file")

    IFS=',' read -ra LANG_ARRAY <<< "$detected_langs"
    for lang in "${LANG_ARRAY[@]}"; do
        [ -z "$lang" ] && continue
        local overlay="${policy_dir}/settings-${lang}.json"
        if [ -f "$overlay" ]; then
            log "Merging language overlay: ${lang}"
            merged=$(printf '%s' "$merged" | jq -s '
                .[0] as $base | .[1] as $overlay |
                $base * $overlay |
                .permissions.allow   = (($base.permissions.allow   // []) + ($overlay.permissions.allow   // []) | unique) |
                .permissions.deny    = (($base.permissions.deny    // []) + ($overlay.permissions.deny    // []) | unique) |
                .fileSystemIsolation.allowedPaths = (
                    ($base.fileSystemIsolation.allowedPaths // []) +
                    ($overlay.fileSystemIsolation.allowedPaths // []) | unique
                )
            ' - "$overlay")
        fi
    done

    echo "$merged"
}

# ── Step 5: Write to Claude managed settings path ────────────────────────────
write_managed_settings() {
    local merged_json="$1"
    mkdir -p "$CLAUDE_MANAGED_DIR"
    echo "$merged_json" | jq '.' > "${CLAUDE_MANAGED_DIR}/settings.json"
    log "Managed settings written to ${CLAUDE_MANAGED_DIR}/settings.json"
}

# ── Step 6: Emit audit event ─────────────────────────────────────────────────
emit_audit() {
    local source="$1"
    local detected_langs="$2"
    local policy_dir="$3"
    local version
    version=$(jq -r '.version // "unknown"' "${policy_dir}/manifest.json" 2>/dev/null || echo "unknown")

    local payload
    payload=$(jq -n \
        --arg event   "cg-policy-applied" \
        --arg version "$version" \
        --arg source  "$source" \
        --arg langs   "$detected_langs" \
        --arg host    "$(hostname)" \
        --arg user    "$(whoami)" \
        --arg ts      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, policyVersion:$version, source:$source,
          detectedLanguages:$langs, host:$host, user:$user, timestamp:$ts}')

    log "Audit: ${payload}"

    # Forward to audit endpoint if configured (CloudWatch / SIEM)
    if [ -n "${CG_AUDIT_ENDPOINT:-}" ]; then
        curl -fsSL -X POST "${CG_AUDIT_ENDPOINT}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null \
            || warn "Audit endpoint unreachable — event logged locally only"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    log "================================================"
    log "Capital Group — Security Policy Application"
    log "================================================"

    local detected_langs
    detected_langs=$(detect_languages)
    log "Detected languages: ${detected_langs:-none}"

    # Try COPY 2 (S3 live), fall back to COPY 1 (image baseline)
    local source
    source=$(fetch_live_policy || echo "image-fallback")

    local policy_dir
    policy_dir=$(resolve_policy_dir "$source")
    log "Using policy from: ${policy_dir} (source: ${source})"

    local merged_json
    merged_json=$(merge_settings "$policy_dir" "$detected_langs")

    write_managed_settings "$merged_json"
    emit_audit "$source" "$detected_langs" "$policy_dir"

    log "================================================"
    log "Security policy applied successfully"
    log "================================================"
}

main "$@"
