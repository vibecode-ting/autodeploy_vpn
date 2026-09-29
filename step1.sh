#!/usr/bin/env bash
# =============================================================================
# step1.sh — Prerequisites & Authentication Setup
#
# PURPOSE: Install ALL tools, CLIs, Python packages, and set up auth
#          before running step2.sh on a fresh/empty Linux VPS.
#
# WHAT IT INSTALLS:
#   System: curl, wget, git, unzip, jq, sqlite3, ufw, qrencode, whiptail
#   Python: python3, pip, bcrypt, cryptography, openpyxl, qrcode
#   CLIs:   GitHub CLI (gh), Google Cloud CLI (gcloud)
#   Auth:   Optional interactive login for gh and gcloud
#
# USAGE:
#   sudo bash step1.sh                  # Full setup with auth prompts
#   sudo bash step1.sh --no-gcloud      # Skip gcloud install
#   sudo bash step1.sh --no-gh          # Skip GitHub CLI install
#   sudo bash step1.sh --no-auth        # Install only, skip auth login
#   sudo bash step1.sh --unattended     # No prompts, no auth (CI mode)
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/var/log/vpn_step1.log"
STEP1_STATUS_FILE="/var/log/vpn_step1_status.json"

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"; }
ok()      { echo -e "  ${GREEN}✔${NC} $*" | tee -a "$LOG_FILE"; }
skip()    { echo -e "  ${YELLOW}⊘${NC} $* (skipped)" | tee -a "$LOG_FILE"; }

# ── Flags ──────────────────────────────────────────────────────────────────────
INSTALL_GCLOUD=true
INSTALL_GH=true
DO_AUTH=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-gcloud)   INSTALL_GCLOUD=false ;;
        --no-gh)       INSTALL_GH=false ;;
        --no-auth)     DO_AUTH=false ;;
        --unattended)  DO_AUTH=false ;;
    esac
    shift
done

# ── Pre-flight ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash step1.sh"
mkdir -p /var/log
touch "$LOG_FILE"

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      VPN NODE — STEP 1: PREREQUISITES & AUTH SETUP          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

source /etc/os-release 2>/dev/null || true
log "Step 1 started. OS: ${PRETTY_NAME:-unknown}. Log: $LOG_FILE"

# ── 1. System Update ───────────────────────────────────────────────────────────
section "1. System Update"
apt-get update -qq 2>&1 | tail -3 | tee -a "$LOG_FILE"
apt-get upgrade -y -qq 2>&1 | tail -3 | tee -a "$LOG_FILE"
ok "System updated"

# ── 2. Core System Packages ────────────────────────────────────────────────────
section "2. Core System Packages"

PACKAGES=(
    # Essentials
    curl wget git unzip zip
    # Network tools
    net-tools iproute2 iputils-ping dnsutils
    # VPN tools
    ufw qrencode sqlite3 whiptail
    # Build tools (needed for pip packages with C extensions)
    build-essential libssl-dev libffi-dev
    # Python
    python3 python3-pip python3-venv python3-dev
    # Utilities
    jq htop screen tmux nano vim
    # Security & apt transport
    ca-certificates gnupg lsb-release apt-transport-https
    # Firewall persistence
    iptables-persistent netfilter-persistent
)

log "Installing ${#PACKAGES[@]} packages..."
apt-get install -y -qq "${PACKAGES[@]}" 2>&1 | tail -5 | tee -a "$LOG_FILE"
ok "All system packages installed"

for tool in curl wget git python3 pip3 sqlite3 ufw jq; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool: $(command -v $tool)"
    else
        warn "$tool: NOT FOUND after install attempt"
    fi
done

# ── 3. Python Packages ─────────────────────────────────────────────────────────
section "3. Python Packages"

PIP_PACKAGES=(
    bcrypt           # Admin password hashing for 3X-UI
    cryptography     # x25519 key generation for VLESS-Reality
    openpyxl         # Excel read/write for prepare/
    qrcode           # Terminal QR code generation
)

PIP_OPTS=""
python3 -c "import sys; v=sys.version_info; exit(0 if v.major>3 or (v.major==3 and v.minor>=11) else 1)" 2>/dev/null && \
    PIP_OPTS="--break-system-packages"

log "Installing Python packages: ${PIP_PACKAGES[*]}"
for pkg in "${PIP_PACKAGES[@]}"; do
    if pip3 install --quiet $PIP_OPTS "$pkg" 2>/dev/null; then
        ok "Python: $pkg installed"
    else
        warn "Python: $pkg install failed (will retry at runtime)"
    fi
done

# ── 4. GitHub CLI (gh) ─────────────────────────────────────────────────────────
section "4. GitHub CLI (gh)"

if [[ "$INSTALL_GH" == "false" ]]; then
    skip "GitHub CLI (--no-gh)"
elif command -v gh &>/dev/null; then
    ok "gh already installed: $(gh --version | head -1)"
else
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y -qq gh 2>&1 | tail -2 | tee -a "$LOG_FILE"

    if command -v gh &>/dev/null; then
        ok "GitHub CLI installed: $(gh --version | head -1)"
    else
        warn "GitHub CLI install failed. Manual install: https://cli.github.com"
    fi
fi

# ── 5. Google Cloud CLI (gcloud) ───────────────────────────────────────────────
section "5. Google Cloud CLI (gcloud)"

if [[ "$INSTALL_GCLOUD" == "false" ]]; then
    skip "Google Cloud CLI (--no-gcloud)"
elif command -v gcloud &>/dev/null; then
    ok "gcloud already installed: $(gcloud --version | head -1)"
else
    log "Installing Google Cloud CLI..."
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
        https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list
    apt-get update -qq
    apt-get install -y -qq google-cloud-cli 2>&1 | tail -3 | tee -a "$LOG_FILE"

    if command -v gcloud &>/dev/null; then
        ok "gcloud installed: $(gcloud --version | head -1)"
    else
        warn "gcloud install failed. Manual: https://cloud.google.com/sdk/docs/install"
    fi
fi

# ── 6. UFW Firewall — Initial Rules ───────────────────────────────────────────
section "6. UFW Firewall — Initial Rules"

ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow 22/tcp comment "SSH - always keep open" > /dev/null
ufw --force enable > /dev/null
ok "UFW enabled with SSH open. Additional ports configured by step2.sh"
ufw status | tee -a "$LOG_FILE"

# ── 7. Authentication Setup ────────────────────────────────────────────────────
section "7. Authentication Setup"

if [[ "$DO_AUTH" == "false" ]]; then
    skip "Auth setup (--no-auth or --unattended)"
else
    echo ""
    echo -e "${CYAN}  Authentication is optional but required for:${NC}"
    echo -e "  • GitHub CLI (gh)   → clone private repos, push configs"
    echo -e "  • Google Cloud CLI  → create VMs, manage firewall, rotate IPs"
    echo ""

    # GitHub auth
    if command -v gh &>/dev/null; then
        if gh auth status &>/dev/null 2>&1; then
            ok "GitHub: already authenticated as $(gh api user -q .login 2>/dev/null || echo 'unknown')"
        else
            echo -ne "${YELLOW}  → Authenticate with GitHub? [y/N]: ${NC}"
            read -r GH_CONFIRM
            if [[ "${GH_CONFIRM,,}" == "y" ]]; then
                echo -e "${CYAN}  Running: gh auth login${NC}"
                echo -e "${YELLOW}  Select: GitHub.com → SSH → Authenticate Git → Login with browser${NC}"
                gh auth login || warn "GitHub auth failed or cancelled."
            else
                skip "GitHub auth"
            fi
        fi
    fi

    # Google Cloud auth
    if command -v gcloud &>/dev/null; then
        ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
        if [[ -n "$ACTIVE_ACCOUNT" ]]; then
            ok "gcloud: already authenticated as $ACTIVE_ACCOUNT"
        else
            echo -ne "${YELLOW}  → Authenticate with Google Cloud? [y/N]: ${NC}"
            read -r GCP_CONFIRM
            if [[ "${GCP_CONFIRM,,}" == "y" ]]; then
                echo -e "${CYAN}  Running: gcloud auth login${NC}"
                echo -e "${YELLOW}  A browser URL will be shown — open it to authenticate${NC}"
                gcloud auth login --no-launch-browser 2>/dev/null || \
                gcloud auth login 2>/dev/null || \
                warn "gcloud auth failed. Run manually: gcloud auth login"

                echo -ne "${YELLOW}  → Set up Application Default Credentials? [y/N]: ${NC}"
                read -r ADC_CONFIRM
                [[ "${ADC_CONFIRM,,}" == "y" ]] && \
                    gcloud auth application-default login --no-launch-browser 2>/dev/null || true

                echo -ne "${YELLOW}  → Enter GCP Project ID (or Enter to skip): ${NC}"
                read -r GCP_PROJECT_ID
                if [[ -n "$GCP_PROJECT_ID" ]]; then
                    gcloud config set project "$GCP_PROJECT_ID"
                    ok "gcloud: default project set to $GCP_PROJECT_ID"
                fi
            else
                skip "Google Cloud auth"
            fi
        fi
    fi
fi

# ── 8. Environment Verification ────────────────────────────────────────────────
section "8. Environment Verification"

check_tool() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
        ok "$name: $(command -v $cmd)"
    else
        warn "$name: NOT FOUND"
    fi
}

check_tool "Python3"  "python3"
check_tool "pip3"     "pip3"
check_tool "git"      "git"
check_tool "curl"     "curl"
check_tool "jq"       "jq"
check_tool "sqlite3"  "sqlite3"
check_tool "ufw"      "ufw"
check_tool "whiptail" "whiptail"
check_tool "qrencode" "qrencode"
[[ "$INSTALL_GH" == "true" ]]     && check_tool "gh"     "gh"
[[ "$INSTALL_GCLOUD" == "true" ]] && check_tool "gcloud" "gcloud"

for pkg in bcrypt cryptography openpyxl; do
    if python3 -c "import ${pkg//-/_}" 2>/dev/null; then
        ok "Python: $pkg available"
    else
        warn "Python: $pkg NOT importable"
    fi
done

# ── 9. Write Status File ───────────────────────────────────────────────────────
section "9. Writing Status File"

GH_AUTH_STATUS=$(gh auth status 2>/dev/null && echo "authenticated" || echo "unauthenticated")
GCLOUD_AUTH_STATUS=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || echo "unauthenticated")

cat > "$STEP1_STATUS_FILE" << EOF
{
  "step1_completed": true,
  "timestamp": "$(date -Iseconds)",
  "os": "${PRETTY_NAME:-unknown}",
  "tools": {
    "python3":  "$(command -v python3  2>/dev/null || echo '')",
    "git":      "$(command -v git      2>/dev/null || echo '')",
    "gcloud":   "$(command -v gcloud   2>/dev/null || echo '')",
    "gh":       "$(command -v gh       2>/dev/null || echo '')",
    "sqlite3":  "$(command -v sqlite3  2>/dev/null || echo '')",
    "ufw":      "$(command -v ufw      2>/dev/null || echo '')",
    "jq":       "$(command -v jq       2>/dev/null || echo '')"
  },
  "auth": {
    "github": "$GH_AUTH_STATUS",
    "gcloud": "$GCLOUD_AUTH_STATUS"
  },
  "python_packages": {
    "bcrypt":       $(python3 -c "import bcrypt;       print('true')" 2>/dev/null || echo "false"),
    "cryptography": $(python3 -c "import cryptography; print('true')" 2>/dev/null || echo "false"),
    "openpyxl":     $(python3 -c "import openpyxl;     print('true')" 2>/dev/null || echo "false")
  }
}
EOF
ok "Status written to $STEP1_STATUS_FILE"

# ── Final Summary ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ✅  STEP 1 COMPLETE — READY FOR STEP 2              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Log file   : ${CYAN}$LOG_FILE${GREEN}                    ║${NC}"
echo -e "${GREEN}║  Status     : ${CYAN}$STEP1_STATUS_FILE${GREEN}  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  NEXT STEPS:                                                 ║${NC}"
echo -e "${GREEN}║  1. Fill in config: ${CYAN}prepare/requirements.xlsx${GREEN}              ║${NC}"
echo -e "${GREEN}║  2. Generate JSON:  ${CYAN}python3 prepare/excel_to_json.py${GREEN}       ║${NC}"
echo -e "${GREEN}║  3. Run installer:  ${CYAN}sudo bash step2.sh${GREEN}                     ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
