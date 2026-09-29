#!/usr/bin/env bash
# =============================================================================
# deploy_gcp.sh — Mode A: Google Cloud Infrastructure Orchestrator
#
# USAGE (from Google Cloud Shell or local machine with gcloud):
#   bash deploy_gcp.sh [--project PROJECT_ID] [--region REGION]
#
# What it does:
#   1. Reserves a Standard Tier regional static IP
#   2. Creates VPC firewall rules (SS + Reality 443 + Admin Panel)
#   3. Deploys e2-small VM with startup script that auto-installs VPN
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Arg Parsing ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --region)  GCP_REGION="$2"; shift 2 ;;
        --zone)    GCP_ZONE="$2"; shift 2 ;;
        --env)     ENV_FILE="$2"; shift 2 ;;
        *) warn "Unknown arg: $1"; shift ;;
    esac
done

# ── Load config ───────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
GCP_REGION="${GCP_REGION:-asia-southeast1}"
GCP_ZONE="${GCP_ZONE:-asia-southeast1-b}"
GCP_TIER="${GCP_TIER:-STANDARD}"
GCP_VM_NAME="${GCP_VM_NAME:-vpn-node-01}"
GCP_MACHINE_TYPE="${GCP_MACHINE_TYPE:-e2-small}"
ADMIN_PORT="${ADMIN_PORT:-2053}"
SS_PORT="${SS_PORT:-25762}"
REALITY_PORT="${REALITY_PORT:-443}"

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v gcloud &>/dev/null || error "gcloud CLI not found. Install Google Cloud SDK."
[[ -z "$GCP_PROJECT" ]] && error "GCP_PROJECT not set. Pass --project or configure gcloud."

gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | \
    grep -q '@' || error "Not authenticated. Run: gcloud auth login"

echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}        GCP VPN NODE DEPLOYMENT PLAN${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  Project   : ${CYAN}$GCP_PROJECT${NC}"
echo -e "  Region    : ${CYAN}$GCP_REGION${NC} (Network Tier: $GCP_TIER)"
echo -e "  Zone      : ${CYAN}$GCP_ZONE${NC}"
echo -e "  VM Name   : ${CYAN}$GCP_VM_NAME${NC} ($GCP_MACHINE_TYPE)"
echo -e "  Firewall  : Ports ${CYAN}22, $REALITY_PORT, $ADMIN_PORT, $SS_PORT/tcp+udp${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
read -rp "Proceed with deployment? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { echo "Aborted."; exit 0; }

gcloud config set project "$GCP_PROJECT" --quiet

# ── Step 1: Reserve Static IP ─────────────────────────────────────────────────
IP_NAME="vpn-static-ip-$(date +%s)"
log "Reserving $GCP_TIER tier static IP in $GCP_REGION..."
gcloud compute addresses create "$IP_NAME" \
    --project="$GCP_PROJECT" \
    --region="$GCP_REGION" \
    --network-tier="$GCP_TIER" \
    --quiet

STATIC_IP=$(gcloud compute addresses describe "$IP_NAME" \
    --region="$GCP_REGION" --project="$GCP_PROJECT" \
    --format="value(address)")
log "Static IP reserved: $STATIC_IP"

# ── Step 2: Create Firewall Rules ─────────────────────────────────────────────
RULE_NAME="allow-vpn-traffic"
log "Setting up VPC firewall rules..."

if gcloud compute firewall-rules describe "$RULE_NAME" \
        --project="$GCP_PROJECT" &>/dev/null 2>&1; then
    log "Updating existing firewall rule..."
    gcloud compute firewall-rules update "$RULE_NAME" \
        --project="$GCP_PROJECT" \
        --rules="tcp:22,tcp:${REALITY_PORT},tcp:${ADMIN_PORT},tcp:${SS_PORT},udp:${SS_PORT}" \
        --quiet
else
    log "Creating firewall rule: $RULE_NAME"
    gcloud compute firewall-rules create "$RULE_NAME" \
        --project="$GCP_PROJECT" \
        --allow="tcp:22,tcp:${REALITY_PORT},tcp:${ADMIN_PORT},tcp:${SS_PORT},udp:${SS_PORT}" \
        --target-tags="vpn-node" \
        --description="VPN: VLESS-Reality:${REALITY_PORT} SS:${SS_PORT} Admin:${ADMIN_PORT}" \
        --source-ranges="0.0.0.0/0" \
        --quiet
fi
log "Firewall rules set."

# ── Step 3: Build Startup Script ──────────────────────────────────────────────
REPO_URL="https://github.com/YOUR_USERNAME/automation_build_vpn_on_current_host"

# Embed .env content into startup script for full automation
ENV_CONTENT=$(cat "$ENV_FILE" 2>/dev/null || cat "$SCRIPT_DIR/.env.example")

STARTUP_SCRIPT=$(cat << STARTUP_EOF
#!/bin/bash
set -e
exec > /var/log/vpn_startup.log 2>&1
echo "=== VPN Auto-Setup Started at \$(date) ==="

# Install git if missing
apt-get update -qq && apt-get install -y -qq git curl

# Clone automation repo
cd /root
git clone "$REPO_URL" automation_build_vpn_on_current_host || {
    echo "Git clone failed. Downloading as zip..."
    # Fallback: download and extract
    curl -sL "${REPO_URL}/archive/refs/heads/main.zip" -o repo.zip
    unzip -q repo.zip && mv automation_build_vpn_on_current_host-main automation_build_vpn_on_current_host
}

cd automation_build_vpn_on_current_host

# Write .env from deployment config
cat > .env << 'ENVEOF'
$ENV_CONTENT
ENVEOF

chmod +x setup_host.sh core/*.sh manager/*.sh 2>/dev/null || true
bash setup_host.sh >> /var/log/vpn_startup.log 2>&1
echo "=== Setup Complete at \$(date) ==="
STARTUP_EOF
)

# ── Step 4: Create VM Instance ────────────────────────────────────────────────
log "Creating VM instance: $GCP_VM_NAME in $GCP_ZONE..."

# Check if VM already exists
if gcloud compute instances describe "$GCP_VM_NAME" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" &>/dev/null 2>&1; then
    warn "VM $GCP_VM_NAME already exists. Skipping creation."
else
    gcloud compute instances create "$GCP_VM_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE" \
        --machine-type="$GCP_MACHINE_TYPE" \
        --network-tier="$GCP_TIER" \
        --image-family="ubuntu-2204-lts" \
        --image-project="ubuntu-os-cloud" \
        --boot-disk-size="20GB" \
        --boot-disk-type="pd-standard" \
        --address="$STATIC_IP" \
        --tags="vpn-node" \
        --metadata="startup-script=$STARTUP_SCRIPT" \
        --quiet

    log "VM created: $GCP_VM_NAME"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║       ✅  GCP DEPLOYMENT INITIATED SUCCESSFULLY              ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  VM Name     : ${CYAN}$GCP_VM_NAME${GREEN}                               ║${NC}"
echo -e "${GREEN}║  Static IP   : ${CYAN}$STATIC_IP${GREEN}                              ║${NC}"
echo -e "${GREEN}║  Region      : ${CYAN}$GCP_REGION${GREEN}                       ║${NC}"
echo -e "${GREEN}║  Admin Panel : ${CYAN}http://$STATIC_IP:$ADMIN_PORT${GREEN}              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Setup runs automatically via startup script (~2-3 min)      ║${NC}"
echo -e "${GREEN}║  Monitor: ${CYAN}gcloud compute ssh $GCP_VM_NAME --zone $GCP_ZONE${GREEN}  ║${NC}"
echo -e "${GREEN}║  Logs:    ${CYAN}cat /var/log/vpn_startup.log${GREEN}                    ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Deployment complete. VM will be ready in ~3 minutes."
