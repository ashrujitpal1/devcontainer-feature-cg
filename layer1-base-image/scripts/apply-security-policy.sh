#!/bin/bash
set -euo pipefail

# =============================================================================
# apply-security-policy.sh
#
# Layer 3 — runs at EVERY container start via postStartCommand.
#
# Dual-delivery merge model:
#   COPY 1 (image baseline) : /etc/cg-managed-settings/
#                             Full policy floor — always the starting point.
#                             Updated monthly when image rebuilds.
#
#   COPY 2 (S3 delta)       : s3://capital-group-claude-policies/latest/
#                             Delta only — new controls added since last
#                             image build. Empty at initial release.
#                             Updated biweekly/monthly by security team.
#
# Runtime result = COPY 1 merged with COPY 2 delta + language overlays
# Written to ~/.claude/settings.json (Claude managed settings — highest
# priority in Claude's hierarchy, cannot be overridden by developer).
# =============================================================================

POLICY_SOURCE="${SECURITY_POLICY_SOURCE:-s3}"
POLICY_S3_BUCKET="${SECURITY_POLICY_S3_BUCKET:-capital-group-claude-policies}"
POLICY_S3_PREFIX="${SECURITY_POLICY_S3_PREFIX:-latest}"
POLICY_BASELINE_DIR="/etc/cg-managed-settings"
POLICY_DELTA_DIR="/tmp/cg-policy-delta"

# Resolve Claude config dir
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_MANAGED_DIR="$CLAUDE_CONFIG_DIR"
else
    CLAUDE_MANAGED_DIR="${HOME:-/root}/.claude"
fi

# Log file — always writable, remove stale root-owned file
LOG_FILE="/tmp/cg-policy-apply.log"
rm -f "$LOG_FILE" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cg-policy-apply-$$.log"

# CRITICAL: log() writes to STDERR only — never stdout
# This prevents log lines from being captured by $() command substitution
log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE" >&2; }
warn() { log "WARN: $*"; }

# ── Step 1: Detect installed language runtimes ────────────────────────────────
# Only prints language list to stdout — no log() calls inside
detect_languages() {
    local langs=()
    command -v java    &>/dev/null && langs+=("java")
    command -v python3 &>/dev/null && langs+=("python")
    command -v node    &>/dev/null && langs+=("node")
    command -v go      &>/dev/null && langs+=("go")
    printf '%s\n' "${langs[@]}" | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ── Step 2: Fetch COPY 2 delta from S3 ───────────────────────────────────────
# Only prints "s3" or "no-delta" to stdout — all log() calls go to stderr
fetch_delta_policy() {
    if [ "$POLICY_SOURCE" = "local" ]; then
        log "SECURITY_POLICY_SOURCE=local — skipping S3 delta fetch"
        echo "no-delta"
        return 0
    fi

    mkdir -p "$POLICY_DELTA_DIR"
    log "Fetching delta policy from s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/"

    if ! aws s3 sync \
        "s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/" \
        "$POLICY_DELTA_DIR/" \
        --quiet --no-progress 2>>"$LOG_FILE"; then
        warn "S3 fetch failed — will use image baseline only (COPY 1)"
        echo "no-delta"
        return 0
    fi

    local delta_files
    delta_files=$(jq -r '.deltaFiles | length' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "0")

    if [ "$delta_files" = "0" ] || [ "$delta_files" = "null" ]; then
        log "S3 manifest has no delta files — image baseline is current (COPY 1)"
        echo "no-delta"
    else
        log "S3 delta fetched — ${delta_files} new control file(s) to merge"
        echo "s3"
    fi
}

# ── Step 3: Build merged settings ────────────────────────────────────────────
# Only prints final JSON to stdout — all log() calls go to stderr
merge_settings() {
    local delta_source="$1"
    local detected_langs="$2"

    local base_file="${POLICY_BASELINE_DIR}/settings.json"
    if [ ! -f "$base_file" ]; then
        warn "COPY 1 baseline settings.json missing from image"
        return 1
    fi

    local merged
    merged=$(cat "$base_file")
    log "Starting from COPY 1 image baseline"

    # Merge COPY 2 delta on top if available
    if [ "$delta_source" = "s3" ] && [ -f "${POLICY_DELTA_DIR}/settings.json" ]; then
        log "Merging COPY 2 S3 delta settings on top of baseline"
        merged=$(printf '%s' "$merged" | jq -s '
            .[0] as $base | .[1] as $delta |
            $base * $delta |
            .permissions.allow = (($base.permissions.allow // []) + ($delta.permissions.allow // []) | unique) |
            .permissions.deny  = (($base.permissions.deny  // []) + ($delta.permissions.deny  // []) | unique) |
            .fileSystemIsolation.allowedPaths = (($base.fileSystemIsolation.allowedPaths // []) + ($delta.fileSystemIsolation.allowedPaths // []) | unique) |
            .fileSystemIsolation.deniedPaths  = (($base.fileSystemIsolation.deniedPaths  // []) + ($delta.fileSystemIsolation.deniedPaths  // []) | unique)
        ' - "${POLICY_DELTA_DIR}/settings.json")
    fi

    # Merge language-specific overlays
    IFS=',' read -ra LANG_ARRAY <<< "$detected_langs"
    for lang in "${LANG_ARRAY[@]}"; do
        [ -z "$lang" ] && continue

        local overlay=""
        if [ "$delta_source" = "s3" ] && [ -f "${POLICY_DELTA_DIR}/settings-${lang}.json" ]; then
            overlay="${POLICY_DELTA_DIR}/settings-${lang}.json"
            log "Merging language overlay (S3 delta): ${lang}"
        elif [ -f "${POLICY_BASELINE_DIR}/settings-${lang}.json" ]; then
            overlay="${POLICY_BASELINE_DIR}/settings-${lang}.json"
            log "Merging language overlay (image baseline): ${lang}"
        fi

        if [ -n "$overlay" ]; then
            merged=$(printf '%s' "$merged" | jq -s '
                .[0] as $base | .[1] as $overlay |
                $base * $overlay |
                .permissions.allow = (($base.permissions.allow // []) + ($overlay.permissions.allow // []) | unique) |
                .permissions.deny  = (($base.permissions.deny  // []) + ($overlay.permissions.deny  // []) | unique) |
                .fileSystemIsolation.allowedPaths = (($base.fileSystemIsolation.allowedPaths // []) + ($overlay.fileSystemIsolation.allowedPaths // []) | unique)
            ' - "$overlay")
        fi
    done

    # Only this echo goes to stdout — captured by $() in main
    echo "$merged"
}

# ── Step 4: Write to Claude managed settings path ────────────────────────────
write_managed_settings() {
    local merged_json="$1"
    mkdir -p "$CLAUDE_MANAGED_DIR"
    printf '%s' "$merged_json" | jq '.' > "${CLAUDE_MANAGED_DIR}/settings.json"
    log "Managed settings written to ${CLAUDE_MANAGED_DIR}/settings.json"
}

# ── Step 5: Emit audit event ─────────────────────────────────────────────────
emit_audit() {
    local delta_source="$1"
    local detected_langs="$2"

    local baseline_version="unknown"
    if [ -f "${POLICY_BASELINE_DIR}/manifest.json" ]; then
        baseline_version=$(jq -r '.version // "unknown"' "${POLICY_BASELINE_DIR}/manifest.json" 2>/dev/null || echo "unknown")
    fi

    local delta_version="none"
    if [ "$delta_source" = "s3" ] && [ -f "${POLICY_DELTA_DIR}/manifest.json" ]; then
        delta_version=$(jq -r '.version // "unknown"' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "unknown")
    fi

    local payload
    payload=$(jq -n \
        --arg event            "cg-policy-applied" \
        --arg baseline_version "$baseline_version" \
        --arg delta_version    "$delta_version" \
        --arg delta_source     "$delta_source" \
        --arg langs            "$detected_langs" \
        --arg host             "$(hostname)" \
        --arg user             "$(whoami)" \
        --arg ts               "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, baselineVersion:$baseline_version, deltaVersion:$delta_version,
          deltaSource:$delta_source, detectedLanguages:$langs,
          host:$host, user:$user, timestamp:$ts}' 2>/dev/null \
        || echo '{"event":"cg-policy-applied","error":"audit-payload-failed"}')

    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Audit: $payload" | tee -a "$LOG_FILE" >&2

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

    local delta_source
    delta_source=$(fetch_delta_policy)

    local merged_json
    merged_json=$(merge_settings "$delta_source" "$detected_langs")

    write_managed_settings "$merged_json"
    emit_audit "$delta_source" "$detected_langs"

    log "================================================"
    log "Security policy applied — baseline: COPY 1 + delta: ${delta_source}"
    log "================================================"
}

main "$@"
