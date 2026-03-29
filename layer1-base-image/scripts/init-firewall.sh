#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# init-firewall.sh
#
# Best-effort container egress firewall (until Apex proxy is available).
# Allows outbound traffic only to approved endpoints:
#   - AWS Bedrock + STS (us-east-1)
#   - S3 policy bucket
#   - GitHub (for git operations)
#   - npm registry
#   - VS Code marketplace
#
# NOTE: This is defense-in-depth only. A developer with Docker Desktop
# access can bypass container-level iptables from the host. Apex will
# be the real enforcement point when available.
# =============================================================================

log() { echo "[FIREWALL $(date -u +%H:%M:%SZ)] $*"; }

# ── Step 1: Preserve Docker internal DNS before flushing ─────────────────────
DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

# ── Step 2: Flush all existing rules ─────────────────────────────────────────
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# ── Step 3: Restore Docker DNS ───────────────────────────────────────────────
if [ -n "$DOCKER_DNS_RULES" ]; then
    log "Restoring Docker internal DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT    2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat 2>/dev/null || true
fi

# ── Step 4: Always-allow rules (DNS, SSH, loopback) ──────────────────────────
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ── Step 5: Build allowed-domains ipset ──────────────────────────────────────
ipset create allowed-domains hash:net 2>/dev/null || true

# AWS IP ranges for Bedrock, STS, S3 in us-east-1
log "Fetching AWS IP ranges..."
aws_ranges=$(curl -sf --connect-timeout 10 https://ip-ranges.amazonaws.com/ip-ranges.json || echo "")
if [ -n "$aws_ranges" ] && echo "$aws_ranges" | jq -e '.prefixes' >/dev/null 2>&1; then
    while read -r cidr; do
        [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || continue
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$aws_ranges" | jq -r '
        .prefixes[] |
        select(
            (.service == "BEDROCK" or .service == "BEDROCK_RUNTIME" or
             .service == "STS" or .service == "S3") and
            .region == "us-east-1"
        ) | .ip_prefix')
    log "AWS IP ranges added"
else
    log "WARN: Could not fetch AWS IP ranges"
fi

# GitHub IP ranges (for git operations)
log "Fetching GitHub IP ranges..."
gh_ranges=$(curl -sf --connect-timeout 10 https://api.github.com/meta || echo "")
if [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web' >/dev/null 2>&1; then
    while read -r cidr; do
        [[ "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || continue
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' 2>/dev/null || echo "")
    log "GitHub IP ranges added"
fi

# Resolve individual approved domains
for domain in \
    "registry.npmjs.org" \
    "sts.us-east-1.amazonaws.com" \
    "bedrock.us-east-1.amazonaws.com" \
    "bedrock-runtime.us-east-1.amazonaws.com" \
    "s3.us-east-1.amazonaws.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com"; do
    ips=$(dig +noall +answer A "$domain" 2>/dev/null | awk '$4=="A"{print $5}' || echo "")
    if [ -z "$ips" ]; then
        log "WARN: Could not resolve ${domain}, skipping"
        continue
    fi
    while read -r ip; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<< "$ips"
    log "Resolved and added: ${domain}"
done

# Allow host network (Docker bridge)
HOST_IP=$(ip route | awk '/default/{print $3}' || echo "")
if [ -n "$HOST_IP" ]; then
    HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
    iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
    iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
    log "Host network allowed: ${HOST_NETWORK}"
fi

# ── Step 6: Set default DROP and allow only approved destinations ─────────────
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

log "Firewall configured — egress restricted to approved endpoints"

# ── Step 7: Verify ────────────────────────────────────────────────────────────
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    log "WARN: Firewall verification — example.com reachable (unexpected)"
else
    log "OK: Firewall verification — example.com blocked as expected"
fi
