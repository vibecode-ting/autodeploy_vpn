#!/usr/bin/env bash
# =============================================================================
# setup_host.sh — Mode B: Single-Command In-Guest VPN Installer
#
# USAGE:
#   wget -qO setup_host.sh https://raw.githubusercontent.com/.../setup_host.sh
#   chmod +x setup_host.sh && sudo bash setup_host.sh
#
# Or with custom .env:
#   sudo bash setup_host.sh --env /path/to/.env
#
# Compatible: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
# Tested on: GCP e2-small, AWS t3.micro, Vultr, DigitalOcean
# Target completion: < 3 minutes on a fresh instance
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/vpn_setup.log"
START_TIME=$(date +%s)

# ── Arg Parsing ───────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_FILE="$2"; shift 2 ;;
        --skip-3xui) SKIP_3XUI=true; shift ;;
        --skip-bbr) SKIP_BBR=true; shift ;;
        *) echo "Unknown arg: $1"; shift ;;
    esac
done

SKIP_3XUI="${SKIP_3XUI:-false}"
SKIP_BBR="${SKIP_BBR:-false}"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p /var/log
touch "$LOG_FILE"
log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must run as root. Use: sudo bash setup_host.sh"

step "Pre-flight: Detecting OS"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-0}"
    log "Detected OS: $PRETTY_NAME"
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop) log "OS is supported." ;;
        *) warn "OS '$OS_ID' not tested. Proceeding anyway." ;;
    esac
else
    warn "Cannot detect OS. Proceeding anyway."
fi

# Check internet
log "Checking internet connectivity..."
if ! curl -sf --max-time 5 https://api.ipify.org > /dev/null; then
    error "No internet access. Check network settings."
fi
log "Internet: OK"

# ── Load config ───────────────────────────────────────────────────────────────
step "Loading Configuration"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
    log "Loaded config from $ENV_FILE"
else
    log "No .env file found. Using defaults."
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" 2>/dev/null || true
fi

# Set defaults
NODE_NAME="${NODE_NAME:-ting-vvip-server(SG)}"
ADMIN_PORT="${ADMIN_PORT:-2053}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-ChangeMe123!}"
SS_ENABLED="${SS_ENABLED:-true}"
SS_PORT="${SS_PORT:-25762}"
SS_CIPHER="${SS_CIPHER:-chacha20-ietf-poly1305}"
SS_PASSWORD="${SS_PASSWORD:-auto-generate}"
REALITY_ENABLED="${REALITY_ENABLED:-true}"
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_SNI="${REALITY_SNI:-gateway.icloud.com}"

log "Node: $NODE_NAME | Admin Port: $ADMIN_PORT | SS Port: $SS_PORT | Reality Port: $REALITY_PORT"

# ── Phase 1: System Updates & Dependencies ────────────────────────────────────
step "Phase 1: System Updates & Dependencies"
apt-get update -qq
apt-get install -y -qq \
    curl wget git python3 python3-pip python3-venv \
    whiptail sqlite3 ufw qrencode \
    net-tools iproute2 ca-certificates gnupg lsb-release \
    2>/dev/null
log "System packages installed."

# Python deps
pip3 install --quiet bcrypt cryptography 2>/dev/null || \
    pip3 install --quiet --break-system-packages bcrypt cryptography 2>/dev/null || \
    warn "pip3 install failed; db_seeder will self-install on run."

# ── Phase 2: Swap Allocation ──────────────────────────────────────────────────
step "Phase 2: Swap Allocation (4GB)"
SWAP_FILE="/swapfile"
if swapon --show | grep -q "$SWAP_FILE" 2>/dev/null; then
    log "Swap already active. Skipping."
else
    if [[ -f "$SWAP_FILE" ]]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f "$SWAP_FILE"
    fi
    log "Creating 4GB swapfile..."
    # Use fallocate if available, fallback to dd
    if command -v fallocate &>/dev/null; then
        fallocate -l 4G "$SWAP_FILE"
    else
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096 status=none
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null
    swapon "$SWAP_FILE"
    # Persist in fstab
    grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null || \
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    log "4GB swap created and enabled."
fi
free -h | grep -i swap | tee -a "$LOG_FILE"

# ── Phase 3: Kernel & BBR Tuning ─────────────────────────────────────────────
step "Phase 3: Kernel & Network Optimization (BBR)"
if [[ "$SKIP_BBR" != "true" ]]; then
    bash "$SCRIPT_DIR/core/bbr_tune.sh"
else
    log "BBR tuning skipped (--skip-bbr)."
fi

# ── Phase 4: 3X-UI Installation ──────────────────────────────────────────────
step "Phase 4: 3X-UI Installation (Xray-core)"
if [[ "$SKIP_3XUI" != "true" ]]; then
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        log "3X-UI already installed and running."
        # Stop before DB modifications
        log "Stopping x-ui service for database injection..."
        systemctl stop x-ui
    else
        log "Downloading and installing 3X-UI..."
        # Install script from official repo (unattended mode with 'y')
        bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "y" \
            2>&1 | tee -a "$LOG_FILE" || {
            # Fallback: try direct download
            warn "First install attempt failed. Retrying..."
            sleep 3
            bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< "y" \
                2>&1 | tee -a "$LOG_FILE"
        }
        # Stop service immediately after install for DB injection
        sleep 2
        systemctl stop x-ui 2>/dev/null || true
        log "3X-UI installed. Service stopped for DB seeding."
    fi
else
    log "3X-UI install skipped (--skip-3xui)."
fi

# ── Phase 5: Database Injection ───────────────────────────────────────────────
step "Phase 5: Database Injection (Admin + Inbounds)"
DB_PATH="/etc/x-ui/x-ui.db"
mkdir -p /etc/x-ui

log "Running database seeder..."
python3 "$SCRIPT_DIR/core/db_seeder.py" --env "$ENV_FILE" --db "$DB_PATH" \
    2>&1 | tee -a "$LOG_FILE"
log "Database seeded successfully."

# ── Phase 6: Firewall Configuration ──────────────────────────────────────────
step "Phase 6: Firewall Configuration"
bash "$SCRIPT_DIR/core/gcp_firewall.sh" 2>&1 | tee -a "$LOG_FILE"

# ── Phase 7: Start & Enable 3X-UI ────────────────────────────────────────────
step "Phase 7: Starting 3X-UI Service"
systemctl daemon-reload
systemctl enable x-ui --quiet 2>/dev/null || true
systemctl start x-ui

# Wait for service to come up
log "Waiting for x-ui to start..."
for i in {1..15}; do
    if systemctl is-active --quiet x-ui; then
        log "x-ui is running!"
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        warn "x-ui may not have started. Check: journalctl -u x-ui -n 50"
    fi
done

# Verify port binding
sleep 3
if ss -tulpn 2>/dev/null | grep -qE ":$ADMIN_PORT|:$REALITY_PORT|:$SS_PORT"; then
    log "Port binding verified."
else
    warn "Ports not yet showing in ss output. Service may need a moment."
fi

# ── Phase 8: Generate Connection Keys ────────────────────────────────────────
step "Phase 8: Generating Connection Keys"
SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -sf --max-time 5 https://icanhazip.com 2>/dev/null || \
            hostname -I | awk '{print $1}')

python3 "$SCRIPT_DIR/manager/key_generator.py" \
    --db "$DB_PATH" --qr 2>&1 | tee -a "$LOG_FILE"

# ── Final Summary ─────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ADMIN_PASS_DISPLAY=$(grep "^ADMIN_PASS=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "$ADMIN_PASS")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║          ✅  VPN NODE DEPLOYMENT COMPLETE                    ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Completed in: ${ELAPSED}s                                         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Server IP    : ${CYAN}$SERVER_IP${GREEN}                              ║${NC}"
echo -e "${GREEN}║  Admin URL    : ${CYAN}http://$SERVER_IP:$ADMIN_PORT${GREEN}             ║${NC}"
echo -e "${GREEN}║  Admin User   : ${CYAN}$ADMIN_USER${GREEN}                              ║${NC}"
echo -e "${GREEN}║  Admin Pass   : ${CYAN}$ADMIN_PASS_DISPLAY${GREEN}                   ║${NC}"
echo -e "${GREEN}║  SS Port      : ${CYAN}$SS_PORT${GREEN}                                  ║${NC}"
echo -e "${GREEN}║  Reality Port : ${CYAN}$REALITY_PORT${GREEN}                               ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Credentials  : ${CYAN}/root/.vpn_credentials${GREEN}                    ║${NC}"
echo -e "${GREEN}║  Setup Log    : ${CYAN}$LOG_FILE${GREEN}              ║${NC}"
echo -e "${GREEN}║  Manage TUI   : ${CYAN}sudo bash $SCRIPT_DIR/manager/menu.sh${GREEN} ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠  IMPORTANT: Change the admin password via the web panel!${NC}"
echo -e "${YELLOW}   URL: http://$SERVER_IP:$ADMIN_PORT${NC}"
echo ""
