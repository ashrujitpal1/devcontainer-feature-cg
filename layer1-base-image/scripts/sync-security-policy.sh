#!/bin/bash
set -euo pipefail

# =============================================================================
# sync-security-policy.sh
#
# Layer 3 — runs at EVERY container start via postStartCommand.
#
# Single-policy model (no language-specific overlays):
#   COPY 1 (image baseline) : /etc/cg-managed-settings/settings.json
#                             Single unified policy — the floor.
#
#   COPY 2 (S3 deltas)      : s3://capital-group-claude-policies/latest/
#                             Each release is a separate versioned file.
#                             Only deltas with version > image baseline
#                             version are fetched and merged.
#
# Runtime result = COPY 1 + applicable S3 deltas (version > baseline)
# Written to ~/.claude/settings.json (highest priority, immutable).
# =============================================================================

POLICY_SOURCE="${SECURITY_POLICY_SOURCE:-s3}"
POLICY_S3_BUCKET="${SECURITY_POLICY_S3_BUCKET:-capital-group-claude-policies}"
POLICY_S3_PREFIX="${SECURITY_POLICY_S3_PREFIX:-latest}"
POLICY_BASELINE_DIR="/etc/cg-managed-settings"
POLICY_DELTA_DIR="/tmp/cg-policy-delta"

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_MANAGED_DIR="$CLAUDE_CONFIG_DIR"
else
    CLAUDE_MANAGED_DIR="${HOME:-/root}/.claude"
fi

LOG_FILE="/tmp/cg-policy-sync.log"
rm -f "$LOG_FILE" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cg-policy-sync-$$.log"

log()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE" >&2; }
warn() { log "WARN: $*"; }

# ── Version comparison (semver: major.minor.patch) ───────────────────────────
# Returns 0 if $1 > $2, 1 otherwise
version_gt() {
    local IFS=.
    local i a=($1) b=($2)
    for ((i=0; i<3; i++)); do
        local va=${a[i]:-0} vb=${b[i]:-0}
        if ((va > vb)); then return 0; fi
        if ((va < vb)); then return 1; fi
    done
    return 1
}

# ── Get image baseline version ───────────────────────────────────────────────
get_baseline_version() {
    if [ -f "${POLICY_BASELINE_DIR}/manifest.json" ]; then
        jq -r '.version // "0.0.0"' "${POLICY_BASELINE_DIR}/manifest.json" 2>/dev/null || echo "0.0.0"
    else
        echo "0.0.0"
    fi
}

# ── Fetch S3 delta manifest and download applicable deltas ───────────────────
# Prints "s3" or "no-delta" to stdout; all logging to stderr
fetch_delta_policy() {
    local baseline_version="$1"

    if [ "$POLICY_SOURCE" = "local" ]; then
        log "SECURITY_POLICY_SOURCE=local — skipping S3 delta fetch"
        echo "no-delta"
        return 0
    fi

    mkdir -p "$POLICY_DELTA_DIR"
    log "Fetching delta manifest from s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/manifest.json"

    if ! aws s3 cp \
        "s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/manifest.json" \
        "${POLICY_DELTA_DIR}/manifest.json" \
        --quiet --no-progress 2>>"$LOG_FILE"; then
        warn "S3 fetch failed — will use image baseline only (COPY 1)"
        echo "no-delta"
        return 0
    fi

    local release_count
    release_count=$(jq -r '.deltaReleases | length' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "0")

    if [ "$release_count" = "0" ] || [ "$release_count" = "null" ]; then
        log "S3 manifest has no delta releases — image baseline is current"
        echo "no-delta"
        return 0
    fi

    # Find deltas with version > baseline and download them
    local applicable_files
    applicable_files=$(jq -r --arg bv "$baseline_version" '
        .deltaReleases[]
        | select(
            (.version | split(".") | map(tonumber)) as $v |
            ($bv     | split(".") | map(tonumber)) as $b |
            ($v[0] > $b[0]) or
            ($v[0] == $b[0] and $v[1] > $b[1]) or
            ($v[0] == $b[0] and $v[1] == $b[1] and $v[2] > $b[2])
        )
        | .file
    ' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "")

    if [ -z "$applicable_files" ]; then
        log "No delta releases newer than image baseline v${baseline_version}"
        echo "no-delta"
        return 0
    fi

    local count=0
    while IFS= read -r delta_file; do
        [ -z "$delta_file" ] && continue
        log "Downloading delta: ${delta_file}"
        if aws s3 cp \
            "s3://${POLICY_S3_BUCKET}/${POLICY_S3_PREFIX}/${delta_file}" \
            "${POLICY_DELTA_DIR}/${delta_file}" \
            --quiet --no-progress 2>>"$LOG_FILE"; then
            count=$((count + 1))
        else
            warn "Failed to download delta: ${delta_file}"
        fi
    done <<< "$applicable_files"

    if [ "$count" -gt 0 ]; then
        log "Downloaded ${count} delta file(s) newer than baseline v${baseline_version}"
        echo "s3"
    else
        echo "no-delta"
    fi
}

# ── Merge baseline + applicable deltas ───────────────────────────────────────
# Prints final JSON to stdout
merge_settings() {
    local delta_source="$1"
    local baseline_version="$2"

    local base_file="${POLICY_BASELINE_DIR}/settings.json"
    if [ ! -f "$base_file" ]; then
        warn "COPY 1 baseline settings.json missing from image"
        return 1
    fi

    local merged
    merged=$(cat "$base_file")
    log "Starting from COPY 1 image baseline v${baseline_version}"

    if [ "$delta_source" != "s3" ]; then
        echo "$merged"
        return 0
    fi

    # Apply each applicable delta in version order
    local ordered_files
    ordered_files=$(jq -r --arg bv "$baseline_version" '
        .deltaReleases
        | map(select(
            (.version | split(".") | map(tonumber)) as $v |
            ($bv     | split(".") | map(tonumber)) as $b |
            ($v[0] > $b[0]) or
            ($v[0] == $b[0] and $v[1] > $b[1]) or
            ($v[0] == $b[0] and $v[1] == $b[1] and $v[2] > $b[2])
        ))
        | sort_by(.version | split(".") | map(tonumber))
        | .[].file
    ' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "")

    while IFS= read -r delta_file; do
        [ -z "$delta_file" ] && continue
        local delta_path="${POLICY_DELTA_DIR}/${delta_file}"
        [ ! -f "$delta_path" ] && continue

        log "Merging delta: ${delta_file}"
        merged=$(printf '%s' "$merged" | jq -s '
            .[0] as $base | .[1] as $delta |
            $base * $delta |
            .permissions.allow = (($base.permissions.allow // []) + ($delta.permissions.allow // []) | unique) |
            .permissions.deny  = (($base.permissions.deny  // []) + ($delta.permissions.deny  // []) | unique) |
            .fileSystemIsolation.allowedPaths = (($base.fileSystemIsolation.allowedPaths // []) + ($delta.fileSystemIsolation.allowedPaths // []) | unique) |
            .fileSystemIsolation.deniedPaths  = (($base.fileSystemIsolation.deniedPaths  // []) + ($delta.fileSystemIsolation.deniedPaths  // []) | unique)
        ' - "$delta_path")
    done <<< "$ordered_files"

    echo "$merged"
}

# ── Write to Claude managed settings ─────────────────────────────────────────
write_managed_settings() {
    local merged_json="$1"
    mkdir -p "$CLAUDE_MANAGED_DIR"
    printf '%s' "$merged_json" | jq '.' > "${CLAUDE_MANAGED_DIR}/settings.json"
    log "Managed settings written to ${CLAUDE_MANAGED_DIR}/settings.json"
}

# ── Emit audit event ─────────────────────────────────────────────────────────
emit_audit() {
    local delta_source="$1"
    local baseline_version="$2"

    local delta_version="none"
    if [ "$delta_source" = "s3" ] && [ -f "${POLICY_DELTA_DIR}/manifest.json" ]; then
        delta_version=$(jq -r '
            .deltaReleases | map(.version) | sort_by(split(".") | map(tonumber)) | last // "none"
        ' "${POLICY_DELTA_DIR}/manifest.json" 2>/dev/null || echo "none")
    fi

    local payload
    payload=$(jq -n \
        --arg event            "cg-policy-applied" \
        --arg baseline_version "$baseline_version" \
        --arg delta_version    "$delta_version" \
        --arg delta_source     "$delta_source" \
        --arg host             "$(hostname)" \
        --arg user             "$(whoami)" \
        --arg ts               "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, baselineVersion:$baseline_version, deltaVersion:$delta_version,
          deltaSource:$delta_source, host:$host, user:$user, timestamp:$ts}' 2>/dev/null \
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

    local baseline_version
    baseline_version=$(get_baseline_version)
    log "Image baseline version: v${baseline_version}"

    local delta_source
    delta_source=$(fetch_delta_policy "$baseline_version")

    local merged_json
    merged_json=$(merge_settings "$delta_source" "$baseline_version")

    write_managed_settings "$merged_json"
    emit_audit "$delta_source" "$baseline_version"

    log "================================================"
    log "Policy applied — baseline: v${baseline_version}, delta source: ${delta_source}"
    log "================================================"
}

main "$@"
