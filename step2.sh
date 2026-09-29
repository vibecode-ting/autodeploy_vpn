#!/usr/bin/env bash
# =============================================================================
# step2.sh — Main VPN Installer (reads 100% from config/config.json)
#
# USAGE:
#   sudo bash step2.sh                              # Uses config/config.json
#   sudo bash step2.sh --config /path/to/cfg.json  # Custom JSON path
#   sudo bash step2.sh --skip-3xui                 # Skip 3X-UI install
#   sudo bash step2.sh --no-swap                   # Skip swap allocation
#   sudo bash step2.sh --no-bbr                    # Skip kernel tuning
#   sudo bash step2.sh --no-firewall               # Skip firewall setup
#   sudo bash step2.sh --keys-only                 # Regenerate keys only
#   sudo bash step2.sh --dry-run                   # Preview config, no changes
#
# REQUIREMENTS: Run step1.sh first on a fresh VPS.
# Compatible:   Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/config/config.json"
LOG_FILE="/var/log/vpn_step2.log"
START_TIME=$(date +%s)

# ── Arg Parsing ────────────────────────────────────────────────────────────────
CONFIG_FILE="$DEFAULT_CONFIG"
SKIP_3XUI=false
SKIP_SWAP=false
SKIP_BBR=false
SKIP_FIREWALL=false
KEYS_ONLY=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)       CONFIG_FILE="$2"; shift 2 ;;
        --config=*)     CONFIG_FILE="${1#*=}"; shift ;;
        --skip-3xui)    SKIP_3XUI=true; shift ;;
        --no-swap)      SKIP_SWAP=true; shift ;;
        --no-bbr)       SKIP_BBR=true; shift ;;
        --no-firewall)  SKIP_FIREWALL=true; shift ;;
        --keys-only)    KEYS_ONLY=true; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        *)              shift ;;
    esac
done

# ── Logging ────────────────────────────────────────────────────────────────────
mkdir -p /var/log
touch "$LOG_FILE"
log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }
ok()      { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$LOG_FILE"; }
skip()    { echo -e "  ${YELLOW}⊘${NC} $*" | tee -a "$LOG_FILE"; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must run as root: sudo bash step2.sh"

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         VPN NODE — STEP 2: MAIN INSTALLER                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Config Loader ──────────────────────────────────────────────────────────────
section "Loading Configuration"

[[ ! -f "$CONFIG_FILE" ]] && error "Config not found: $CONFIG_FILE\nRun: python3 prepare/excel_to_json.py  OR  use default at config/config.json"
log "Config: $CONFIG_FILE"

# Read a single JSON value — uses jq if present, else Python fallback
jget() {
    local KEY="$1" DEFAULT="${2:-}"
    local VAL
    if command -v jq &>/dev/null; then
        VAL=$(jq -r "${KEY} // empty" "$CONFIG_FILE" 2>/dev/null)
    else
        VAL=$(python3 -c "
import json
with open('$CONFIG_FILE') as f: c = json.load(f)
keys = '${KEY}'.lstrip('.').split('.')
v = c
for k in keys:
    if isinstance(v, dict): v = v.get(k)
    else: v = None
    if v is None: break
print('' if v is None else str(v).lower() if isinstance(v, bool) else str(v))
" 2>/dev/null)
    fi
    echo "${VAL:-$DEFAULT}"
}

# Read a JSON array value — emits one item per line
jget_array() {
    local KEY="$1"
    if command -v jq &>/dev/null; then
        jq -r "${KEY}[]? // empty" "$CONFIG_FILE" 2>/dev/null
    else
        python3 -c "
import json
with open('$CONFIG_FILE') as f: c = json.load(f)
keys = '${KEY}'.lstrip('.').split('.')
v = c
for k in keys:
    if isinstance(v, dict): v = v.get(k)
    else: v = None
    if v is None: break
if isinstance(v, list):
    for i in v: print(i)
" 2>/dev/null
    fi
}

# ── Load config values ─────────────────────────────────────────────────────────
NODE_NAME=$(jget ".node.name"        "ting-vvip-server(SG)")
NODE_TZ=$(jget   ".node.timezone"    "Asia/Rangoon")

ADMIN_PORT=$(jget ".admin.port"      "2053")
ADMIN_USER=$(jget ".admin.username"  "admin")
ADMIN_PASS=$(jget ".admin.password"  "ChangeMe123!")

SS_ENABLED=$(jget     ".shadowsocks.enabled" "true")
SS_PORT=$(jget        ".shadowsocks.port"    "25762")
REALITY_ENABLED=$(jget ".vless_reality.enabled" "true")
REALITY_PORT=$(jget    ".vless_reality.port"    "443")

SWAP_SIZE=$(jget   ".system.swap_size_gb" "4")
ENABLE_BBR=$(jget  ".system.enable_bbr"   "true")
FD_LIMIT=$(jget    ".system.fd_limit"     "1000000")
SOCK_BUF_MB=$(jget ".system.socket_buffer_mb" "64")

INSTALL_3XUI=$(jget  ".install.install_3xui"   "true")
SKIP_IF_RUN=$(jget   ".install.skip_if_running" "false")
XRAY_VERSION=$(jget  ".install.3xui_version"   "latest")
SHOW_QR=$(jget       ".install.show_qr"        "true")

FIREWALL_BACKEND=$(jget ".firewall.backend"  "auto")
SSH_PORT=$(jget         ".firewall.ssh_port" "22")
GCP_RULE=$(jget         ".firewall.gcp_rule_name" "allow-vpn-traffic")

TG_TOKEN=$(jget        ".notifications.telegram_bot_token" "")
TG_CHAT=$(jget         ".notifications.telegram_chat_id"   "")
NOTIFY_STARTUP=$(jget  ".notifications.notify_on_startup"  "false")

log "Node: $NODE_NAME | Admin: $ADMIN_PORT | SS: $SS_PORT | Reality: $REALITY_PORT"
log "Swap: ${SWAP_SIZE}GB | BBR: $ENABLE_BBR | 3X-UI: $INSTALL_3XUI"

# ── Dry-run mode ───────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "\n${MAGENTA}━━━ DRY RUN: Config loaded. No changes made. ━━━${NC}"
    jq . "$CONFIG_FILE" 2>/dev/null || python3 -c "import json; print(json.dumps(json.load(open('$CONFIG_FILE')), indent=2))"
    exit 0
fi

# ── Keys-only mode ─────────────────────────────────────────────────────────────
if [[ "$KEYS_ONLY" == "true" ]]; then
    log "Keys-only mode: regenerating connection strings..."
    python3 "$SCRIPT_DIR/manager/key_generator.py" --db /etc/x-ui/x-ui.db --qr
    exit 0
fi

# ── 1. OS Detection & Essential Packages ──────────────────────────────────────
section "1. OS Detection & Essential Packages"
source /etc/os-release 2>/dev/null || true
log "OS: ${PRETTY_NAME:-unknown}"

if ! command -v jq &>/dev/null; then
    apt-get install -y -qq jq 2>/dev/null || true
fi
if ! python3 -c "import bcrypt" 2>/dev/null; then
    log "Installing Python packages..."
    PIP_OPTS=""
    python3 -c "import sys; v=sys.version_info; exit(0 if v.major>3 or (v.major==3 and v.minor>=11) else 1)" 2>/dev/null && \
        PIP_OPTS="--break-system-packages"
    pip3 install --quiet $PIP_OPTS bcrypt cryptography 2>/dev/null || true
fi
ok "Environment ready"

# ── 2. Timezone ────────────────────────────────────────────────────────────────
section "2. Timezone"
if timedatectl set-timezone "$NODE_TZ" 2>/dev/null; then
    ok "Timezone set to $NODE_TZ"
else
    warn "Could not set timezone: $NODE_TZ"
fi

# ── 3. Swap Allocation ─────────────────────────────────────────────────────────
section "3. Swap Allocation (${SWAP_SIZE}GB)"
if [[ "$SKIP_SWAP" == "true" ]]; then
    skip "Swap (--no-swap)"
else
    SWAP_FILE="/swapfile"
    if swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
        ok "Swap already active: $(free -h | grep Swap)"
    else
        [[ -f "$SWAP_FILE" ]] && { swapoff "$SWAP_FILE" 2>/dev/null || true; rm -f "$SWAP_FILE"; }
        log "Allocating ${SWAP_SIZE}GB swap..."
        if command -v fallocate &>/dev/null; then
            fallocate -l "${SWAP_SIZE}G" "$SWAP_FILE"
        else
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_SIZE * 1024)) status=none
        fi
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" > /dev/null
        swapon "$SWAP_FILE"
        grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || \
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        ok "Swap: $(free -h | grep Swap)"
    fi
fi

# ── 4. Kernel & BBR Tuning ─────────────────────────────────────────────────────
section "4. Kernel & Network Tuning (BBR)"
if [[ "$SKIP_BBR" == "true" ]]; then
    skip "BBR (--no-bbr)"
elif [[ "$ENABLE_BBR" == "false" ]]; then
    skip "BBR (disabled in config)"
else
    sed -i '/# VPN-Tuning/,/# End VPN-Tuning/d' /etc/sysctl.conf 2>/dev/null || true
    cat >> /etc/sysctl.conf << SYSCTL
# VPN-Tuning
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=$FD_LIMIT
net.core.rmem_max=$(( SOCK_BUF_MB * 1024 * 1024 ))
net.core.wmem_max=$(( SOCK_BUF_MB * 1024 * 1024 ))
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
# End VPN-Tuning
SYSCTL

    sed -i '/# VPN-limits/,/# End VPN-limits/d' /etc/security/limits.conf 2>/dev/null || true
    cat >> /etc/security/limits.conf << LIMITS
# VPN-limits
*    soft nofile $FD_LIMIT
*    hard nofile $FD_LIMIT
root soft nofile $FD_LIMIT
root hard nofile $FD_LIMIT
# End VPN-limits
LIMITS

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/vpn-limits.conf << SYSD
[Manager]
DefaultLimitNOFILE=$FD_LIMIT
DefaultLimitNPROC=65535
SYSD

    sysctl -p /etc/sysctl.conf 2>/dev/null | tail -5 | tee -a "$LOG_FILE" || true
    systemctl daemon-reload
    ACTUAL_BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    ok "BBR: $ACTUAL_BBR | FD limit: $FD_LIMIT"
fi

# ── 5. 3X-UI Installation ──────────────────────────────────────────────────────
section "5. 3X-UI Installation"
if [[ "$SKIP_3XUI" == "true" ]] || [[ "$INSTALL_3XUI" == "false" ]]; then
    skip "3X-UI install"
elif systemctl is-active --quiet x-ui 2>/dev/null && [[ "$SKIP_IF_RUN" == "true" ]]; then
    ok "3X-UI already running. Stopping for DB injection..."
    systemctl stop x-ui
else
    log "Downloading 3X-UI (version: $XRAY_VERSION)..."
    systemctl is-active --quiet x-ui 2>/dev/null && systemctl stop x-ui || true

    if [[ "$XRAY_VERSION" == "latest" || -z "$XRAY_VERSION" ]]; then
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "y" \
            2>&1 | tee -a "$LOG_FILE" || {
            sleep 5
            warn "First attempt failed. Retrying..."
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "y" \
                2>&1 | tee -a "$LOG_FILE"
        }
    else
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) "$XRAY_VERSION" <<< "y" \
            2>&1 | tee -a "$LOG_FILE"
    fi
    sleep 2
    systemctl stop x-ui 2>/dev/null || true
    ok "3X-UI installed. Service stopped for DB seeding."
fi

# ── 6. Database Injection ──────────────────────────────────────────────────────
section "6. Database Injection"
DB_PATH="/etc/x-ui/x-ui.db"
mkdir -p /etc/x-ui

log "Seeding database from config.json..."
python3 "$SCRIPT_DIR/core/db_seeder.py" \
    --config "$CONFIG_FILE" \
    --db "$DB_PATH" \
    2>&1 | tee -a "$LOG_FILE"
ok "Database seeded."

# ── 7. Firewall Configuration ──────────────────────────────────────────────────
section "7. Firewall Configuration"
if [[ "$SKIP_FIREWALL" == "true" ]]; then
    skip "Firewall (--no-firewall)"
else
    EXTRA_TCP=()
    while IFS= read -r port; do
        [[ -n "$port" ]] && EXTRA_TCP+=("$port")
    done < <(jget_array ".firewall.additional_tcp_ports")

    EXTRA_UDP=()
    while IFS= read -r port; do
        [[ -n "$port" ]] && EXTRA_UDP+=("$port")
    done < <(jget_array ".firewall.additional_udp_ports")

    apply_ufw() {
        log "Applying UFW rules..."
        ufw --force reset > /dev/null
        ufw default deny incoming > /dev/null
        ufw default allow outgoing > /dev/null
        ufw allow "$SSH_PORT/tcp" comment "SSH" > /dev/null
        [[ "$REALITY_ENABLED" == "true" ]] && ufw allow "$REALITY_PORT/tcp" comment "VLESS-Reality" > /dev/null
        ufw allow "$ADMIN_PORT/tcp" comment "3X-UI Panel" > /dev/null
        [[ "$SS_ENABLED" == "true" ]] && {
            ufw allow "$SS_PORT/tcp" comment "Shadowsocks" > /dev/null
            ufw allow "$SS_PORT/udp" comment "Shadowsocks" > /dev/null
        }
        for p in "${EXTRA_TCP[@]}"; do ufw allow "$p/tcp" comment "Custom" > /dev/null; done
        for p in "${EXTRA_UDP[@]}"; do ufw allow "$p/udp" comment "Custom" > /dev/null; done
        ufw --force enable > /dev/null
        ok "UFW rules applied:"
        ufw status numbered | tee -a "$LOG_FILE"
    }

    apply_gcp() {
        local PROJECT="$1"
        local RULES="tcp:$SSH_PORT,tcp:$REALITY_PORT,tcp:$ADMIN_PORT,tcp:$SS_PORT,udp:$SS_PORT"
        for p in "${EXTRA_TCP[@]}"; do RULES+=",tcp:$p"; done
        for p in "${EXTRA_UDP[@]}"; do RULES+=",udp:$p"; done

        if gcloud compute firewall-rules describe "$GCP_RULE" --project="$PROJECT" &>/dev/null 2>&1; then
            gcloud compute firewall-rules update "$GCP_RULE" --project="$PROJECT" \
                --rules="$RULES" --quiet
            ok "GCP firewall updated: $RULES"
        else
            gcloud compute firewall-rules create "$GCP_RULE" --project="$PROJECT" \
                --allow="$RULES" --target-tags="vpn-node" --source-ranges="0.0.0.0/0" --quiet
            ok "GCP firewall created: $RULES"
        fi
        apply_ufw
    }

    if [[ "$FIREWALL_BACKEND" == "gcp" ]] || \
       ([[ "$FIREWALL_BACKEND" == "auto" ]] && \
        curl -sf -H "Metadata-Flavor: Google" http://metadata.google.internal/ --max-time 2 &>/dev/null && \
        command -v gcloud &>/dev/null && \
        gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q '@'); then
        GCP_PROJECT=$(gcloud config get-value project 2>/dev/null || jget ".gcp.project" "")
        if [[ -n "$GCP_PROJECT" ]]; then
            apply_gcp "$GCP_PROJECT"
        else
            warn "GCP detected but no project configured. Falling back to UFW."
            apply_ufw
        fi
    else
        apply_ufw
    fi
fi

# ── 8. Start 3X-UI Service ─────────────────────────────────────────────────────
section "8. Starting 3X-UI Service"
systemctl daemon-reload
systemctl enable x-ui --quiet 2>/dev/null || true
systemctl start x-ui

log "Waiting for x-ui to start..."
for i in {1..20}; do
    if systemctl is-active --quiet x-ui; then
        ok "x-ui is running!"
        break
    fi
    sleep 2
    [[ $i -eq 20 ]] && warn "x-ui not responding. Check: journalctl -u x-ui -n 50"
done
sleep 3

# ── 9. Port Verification ───────────────────────────────────────────────────────
section "9. Port Verification"

check_port() {
    local PORT="$1" PROTO="${2:-tcp}" LABEL="$3"
    if ss -tulpn 2>/dev/null | grep -qE "${PROTO}.*:${PORT}[[:space:]]"; then
        ok "Port $PORT/$PROTO — $LABEL ✔"
    else
        warn "Port $PORT/$PROTO — $LABEL not yet listening (service may need a moment)"
    fi
}

check_port "$ADMIN_PORT"   "tcp" "3X-UI Admin Panel"
[[ "$REALITY_ENABLED" == "true" ]] && check_port "$REALITY_PORT" "tcp" "VLESS-Reality"
[[ "$SS_ENABLED" == "true" ]]      && check_port "$SS_PORT"      "tcp" "Shadowsocks"

# ── 10. Connection Keys ────────────────────────────────────────────────────────
section "10. Connection Keys"
SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -sf --max-time 5 https://icanhazip.com 2>/dev/null || \
            hostname -I | awk '{print $1}')

QR_ARG=""
[[ "$SHOW_QR" == "true" ]] && QR_ARG="--qr"

python3 "$SCRIPT_DIR/manager/key_generator.py" \
    --db "$DB_PATH" $QR_ARG \
    2>&1 | tee -a "$LOG_FILE"

# ── 11. Telegram Notification (Optional) ──────────────────────────────────────
if [[ "$NOTIFY_STARTUP" == "true" && -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
    section "11. Telegram Notification"
    MSG="✅ VPN Node Deployed!%0A🌐 IP: $SERVER_IP%0A🔐 Panel: http://$SERVER_IP:$ADMIN_PORT%0A👤 User: $ADMIN_USER"
    curl -sf "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}&text=${MSG}&parse_mode=HTML" > /dev/null 2>&1 && \
        ok "Telegram notification sent." || warn "Telegram notification failed."
fi

# ── Final Summary ──────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ✅  VPN NODE DEPLOYMENT COMPLETE                     ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Completed in:"      "${ELAPSED}s"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Server IP:"         "$SERVER_IP"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Admin URL:"         "http://$SERVER_IP:$ADMIN_PORT"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Admin User:"        "$ADMIN_USER"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Admin Pass:"        "$ADMIN_PASS"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Shadowsocks Port:"  "$SS_PORT"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "VLESS-Reality Port:" "$REALITY_PORT"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Credentials:" "/root/.vpn_credentials"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Setup Log:"   "/var/log/vpn_step2.log"
printf "${GREEN}║  %-30s ${CYAN}%-28s${GREEN}║${NC}\n" "Manage TUI:"  "sudo bash manager/menu.sh"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}  ⚠  SECURITY: Change the admin password immediately after first login!${NC}"
echo -e "${YELLOW}  🌐  Open: http://$SERVER_IP:$ADMIN_PORT${NC}"
echo ""
