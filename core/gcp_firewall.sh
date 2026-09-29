#!/usr/bin/env bash
# =============================================================================
# core/gcp_firewall.sh — GCP / UFW / iptables Firewall Sync
#
# Called by manager/menu.sh after a port change to re-sync firewall rules.
# Reads ports from config/config.json (with .env fallback for menu.sh compat).
# Auto-detects: GCP metadata → UFW → iptables fallback.
# Compatible: Any Ubuntu/Debian host.
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/vpn_step2.log"
log()  { echo "[FIREWALL] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
warn() { echo "[FIREWALL][WARN] $*" | tee -a "$LOG_FILE"; }

# ── Load ports from config.json or .env fallback ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="$(dirname "$SCRIPT_DIR")/config/config.json"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"

if [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
    ADMIN_PORT=$(jq -r '.admin.port     // 2053'  "$CONFIG_JSON")
    SS_PORT=$(   jq -r '.shadowsocks.port // 25762' "$CONFIG_JSON")
    REALITY_PORT=$(jq -r '.vless_reality.port // 443' "$CONFIG_JSON")
    GCP_PROJECT=$(jq -r '.gcp.project // empty'   "$CONFIG_JSON")
    GCP_RULE=$(  jq -r '.firewall.gcp_rule_name // "allow-vpn-traffic"' "$CONFIG_JSON")
elif [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    ADMIN_PORT="${ADMIN_PORT:-2053}"
    SS_PORT="${SS_PORT:-25762}"
    REALITY_PORT="${REALITY_PORT:-443}"
    GCP_PROJECT="${GCP_PROJECT:-}"
    GCP_RULE="allow-vpn-traffic"
else
    ADMIN_PORT=2053
    SS_PORT=25762
    REALITY_PORT=443
    GCP_PROJECT=""
    GCP_RULE="allow-vpn-traffic"
fi

# Allow caller overrides via environment variables
ADMIN_PORT="${ADMIN_PORT_OVERRIDE:-$ADMIN_PORT}"
SS_PORT="${SS_PORT_OVERRIDE:-$SS_PORT}"

# ── Detect environment ─────────────────────────────────────────────────────────
is_gcp() {
    curl -sf -H "Metadata-Flavor: Google" \
        http://metadata.google.internal/computeMetadata/v1/ \
        --max-time 2 > /dev/null 2>&1
}

is_gcloud_authed() {
    command -v gcloud &>/dev/null && \
    gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q '@'
}

# ── UFW rules ──────────────────────────────────────────────────────────────────
apply_ufw_rules() {
    log "Applying UFW firewall rules..."
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw -qq
    fi
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp               comment "SSH"
    ufw allow "$REALITY_PORT/tcp"  comment "VLESS-Reality"
    ufw allow "$ADMIN_PORT/tcp"    comment "3X-UI Admin Panel"
    ufw allow "$SS_PORT/tcp"       comment "Shadowsocks TCP"
    ufw allow "$SS_PORT/udp"       comment "Shadowsocks UDP"
    ufw --force enable
    log "UFW rules applied. Status:"
    ufw status verbose | tee -a "$LOG_FILE"
}

# ── GCP firewall rules ─────────────────────────────────────────────────────────
apply_gcp_rules() {
    [[ -z "$GCP_PROJECT" ]] && GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
    local RULES="tcp:22,tcp:${REALITY_PORT},tcp:${ADMIN_PORT},tcp:${SS_PORT},udp:${SS_PORT}"

    if gcloud compute firewall-rules describe "$GCP_RULE" \
            --project="$GCP_PROJECT" &>/dev/null 2>&1; then
        log "Updating GCP firewall rule: $GCP_RULE"
        gcloud compute firewall-rules update "$GCP_RULE" \
            --project="$GCP_PROJECT" --rules="$RULES" --quiet
    else
        log "Creating GCP firewall rule: $GCP_RULE"
        gcloud compute firewall-rules create "$GCP_RULE" \
            --project="$GCP_PROJECT" --allow="$RULES" \
            --target-tags="vpn-node" \
            --description="VPN: SS + VLESS-Reality + Admin Panel" --quiet
    fi
    log "GCP firewall synced. Rules: $RULES"
}

# ── iptables fallback ──────────────────────────────────────────────────────────
apply_iptables_rules() {
    log "Applying iptables rules..."
    iptables -I INPUT -p tcp --dport 22             -j ACCEPT
    iptables -I INPUT -p tcp --dport "$REALITY_PORT" -j ACCEPT
    iptables -I INPUT -p tcp --dport "$ADMIN_PORT"  -j ACCEPT
    iptables -I INPUT -p tcp --dport "$SS_PORT"     -j ACCEPT
    iptables -I INPUT -p udp --dport "$SS_PORT"     -j ACCEPT

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
        iptables-save > /etc/iptables.rules    2>/dev/null || true
    fi
    log "iptables rules applied."
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    log "Firewall sync start. Reality=$REALITY_PORT Admin=$ADMIN_PORT SS=$SS_PORT"

    if is_gcp && is_gcloud_authed; then
        apply_gcp_rules
        # Also apply UFW locally for defense-in-depth
        apply_ufw_rules
    elif command -v ufw &>/dev/null || apt-get install -y ufw -qq 2>/dev/null; then
        apply_ufw_rules
    else
        apply_iptables_rules
    fi

    log "Firewall sync complete."
}

main "$@"
