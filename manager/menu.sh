#!/usr/bin/env bash
# =============================================================================
# manager/menu.sh — Non-Technical Interactive TUI
#
# 8-option management console for the VPN node.
# Reads config from config/config.json (with .env fallback).
# Usage: sudo bash manager/menu.sh
# =============================================================================
set -euo pipefail

# ── Dependency check ───────────────────────────────────────────────────────────
if ! command -v whiptail &>/dev/null; then
    apt-get install -y whiptail -qq 2>/dev/null || \
    { echo "ERROR: whiptail not found and cannot be installed."; exit 1; }
fi

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_JSON="$ROOT_DIR/config/config.json"
ENV_FILE="$ROOT_DIR/.env"
DB_PATH="/etc/x-ui/x-ui.db"
KEY_GEN="$SCRIPT_DIR/key_generator.py"
FIREWALL="$ROOT_DIR/core/gcp_firewall.sh"

# ── Load config ────────────────────────────────────────────────────────────────
load_config() {
    if [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
        ADMIN_PORT=$(jq -r '.admin.port         // 2053'  "$CONFIG_JSON")
        ADMIN_USER=$(jq -r '.admin.username     // "admin"' "$CONFIG_JSON")
        SS_PORT=$(   jq -r '.shadowsocks.port   // 25762' "$CONFIG_JSON")
        REALITY_PORT=$(jq -r '.vless_reality.port // 443' "$CONFIG_JSON")
        NODE_NAME=$(jq -r '.node.name           // "VPN Node"' "$CONFIG_JSON")
    elif [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        ADMIN_PORT="${ADMIN_PORT:-2053}"
        ADMIN_USER="${ADMIN_USER:-admin}"
        SS_PORT="${SS_PORT:-25762}"
        REALITY_PORT="${REALITY_PORT:-443}"
        NODE_NAME="${NODE_NAME:-VPN Node}"
    else
        ADMIN_PORT=2053; ADMIN_USER=admin; SS_PORT=25762
        REALITY_PORT=443; NODE_NAME="VPN Node"
    fi
}

get_ip() {
    SERVER_IP=$(curl -sf --max-time 3 https://api.ipify.org 2>/dev/null || \
                curl -sf --max-time 3 https://icanhazip.com 2>/dev/null || \
                hostname -I 2>/dev/null | awk '{print $1}' || \
                echo "Unknown")
}

load_config
get_ip

# ── UI helper ──────────────────────────────────────────────────────────────────
msg() { whiptail --title "3X-UI Manager" --msgbox "$1" 20 70; }

# ── Option 1: View Outline Keys ────────────────────────────────────────────────
view_outline_keys() {
    local OUTPUT
    OUTPUT=$(python3 "$KEY_GEN" --db "$DB_PATH" 2>/dev/null | \
             grep -A 10 "Shadowsocks" || echo "No Shadowsocks inbound found.")
    whiptail --title "Outline / Shadowsocks Keys" --scrolltext --msgbox "$OUTPUT" 30 80
}

# ── Option 2: View VLESS-Reality Keys ─────────────────────────────────────────
view_reality_keys() {
    local OUTPUT
    OUTPUT=$(python3 "$KEY_GEN" --db "$DB_PATH" 2>/dev/null | \
             grep -A 10 "VLESS" || echo "No VLESS-Reality inbound found.")
    whiptail --title "VLESS-Reality Keys" --scrolltext --msgbox "$OUTPUT" 30 80
}

# ── Option 3: Change Shadowsocks Port ─────────────────────────────────────────
change_ss_port() {
    local NEW_PORT
    NEW_PORT=$(whiptail --title "Change SS Port" \
               --inputbox "Current port: $SS_PORT\nEnter new Shadowsocks port (1024-65535):" \
               10 60 "$SS_PORT" 3>&1 1>&2 2>&3) || return

    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ $NEW_PORT -lt 1024 || $NEW_PORT -gt 65535 ]]; then
        msg "Invalid port. Must be 1024-65535."
        return
    fi

    # Update DB
    python3 - << PYEOF
import sqlite3, json
db = sqlite3.connect("$DB_PATH")
for row_id, _ in db.execute("SELECT id, settings FROM inbounds WHERE protocol='shadowsocks'").fetchall():
    db.execute("UPDATE inbounds SET port=? WHERE id=?", ($NEW_PORT, row_id))
db.commit()
db.close()
print("DB updated.")
PYEOF

    # Update config.json if present
    if [[ -f "$CONFIG_JSON" ]] && command -v jq &>/dev/null; then
        tmp=$(mktemp)
        jq ".shadowsocks.port = $NEW_PORT" "$CONFIG_JSON" > "$tmp" && mv "$tmp" "$CONFIG_JSON"
    fi

    SS_PORT=$NEW_PORT
    bash "$FIREWALL"
    systemctl restart x-ui
    load_config
    msg "Shadowsocks port changed to $NEW_PORT.\nFirewall updated. 3X-UI restarted."
}

# ── Option 4: Add New User ─────────────────────────────────────────────────────
add_new_user() {
    local EMAIL QUOTA_GB
    EMAIL=$(whiptail --title "Add New User" \
            --inputbox "Enter email/label (e.g., user1@corp):" \
            10 60 "" 3>&1 1>&2 2>&3) || return
    QUOTA_GB=$(whiptail --title "Data Quota" \
               --inputbox "Data quota in GB (0 = unlimited):" \
               10 60 "0" 3>&1 1>&2 2>&3) || return

    python3 - << PYEOF
import sqlite3, json, uuid, secrets
db = sqlite3.connect("$DB_PATH")
cursor = db.cursor()

new_uuid  = str(uuid.uuid4())
new_pass  = secrets.token_urlsafe(20)
total_bytes = int("$QUOTA_GB") * 1024**3

# Add to VLESS inbound
for row_id, settings_raw in cursor.execute(
    "SELECT id, settings FROM inbounds WHERE protocol='vless'"
).fetchall():
    s = json.loads(settings_raw)
    s["clients"].append({
        "id": new_uuid, "flow": "xtls-rprx-vision",
        "email": "$EMAIL", "limitIp": 0,
        "totalGB": total_bytes, "expiryTime": 0,
        "enable": True, "tgId": "", "subId": ""
    })
    cursor.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(s), row_id))

# Add to SS inbound
for row_id, settings_raw in cursor.execute(
    "SELECT id, settings FROM inbounds WHERE protocol='shadowsocks'"
).fetchall():
    s = json.loads(settings_raw)
    if "clients" in s:
        s["clients"].append({
            "method": s.get("method", "chacha20-ietf-poly1305"),
            "password": new_pass, "email": "$EMAIL"
        })
        cursor.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(s), row_id))

db.commit()
db.close()
print(f"User: $EMAIL | VLESS UUID: {new_uuid} | SS Pass: {new_pass}")
PYEOF

    systemctl restart x-ui
    msg "User '$EMAIL' added with ${QUOTA_GB}GB quota.\n3X-UI restarted."
}

# ── Option 5: Bandwidth Usage ──────────────────────────────────────────────────
check_bandwidth() {
    local OUTPUT
    OUTPUT=$(python3 - << 'PYEOF'
import sqlite3
db = sqlite3.connect("/etc/x-ui/x-ui.db")
rows = db.execute("SELECT remark, up, down FROM inbounds ORDER BY id").fetchall()
db.close()

def fmt(b):
    if b > 1024**3: return f"{b/1024**3:.2f} GB"
    if b > 1024**2: return f"{b/1024**2:.2f} MB"
    return f"{b/1024:.2f} KB"

print(f"{'Inbound':<20} {'Upload':>12} {'Download':>12} {'Total':>12}")
print("-" * 60)
for remark, up, down in rows:
    print(f"{remark:<20} {fmt(up):>12} {fmt(down):>12} {fmt(up+down):>12}")
PYEOF
    )
    whiptail --title "Bandwidth Usage" --scrolltext --msgbox "$OUTPUT" 20 70
}

# ── Option 6: Rotate Static IP (GCP only) ─────────────────────────────────────
rotate_ip() {
    if ! command -v gcloud &>/dev/null; then
        msg "gcloud CLI not available.\nRotating IP requires gcloud installed and authenticated."
        return
    fi

    if whiptail --title "Rotate External IP" --yesno \
        "This assigns a NEW static IP to this VM.\nThe old IP will be RELEASED.\n\nCurrent IP: $SERVER_IP\n\nProceed?" 12 60; then

        local GCP_REGION
        GCP_REGION=$(jq -r '.gcp.region // "asia-southeast1"' "$CONFIG_JSON" 2>/dev/null || echo "asia-southeast1")
        local GCP_TIER
        GCP_TIER=$(jq -r '.gcp.network_tier // "STANDARD"' "$CONFIG_JSON" 2>/dev/null || echo "STANDARD")

        gcloud compute addresses create "vpn-ip-$(date +%s)" \
            --region="$GCP_REGION" \
            --network-tier="$GCP_TIER" --quiet 2>&1

        get_ip
        msg "New IP reserved.\nRun the menu again to see the updated IP.\nUpdate client configs with: $SERVER_IP"
    fi
}

# ── Option 7: Open Web Dashboard ──────────────────────────────────────────────
open_dashboard() {
    msg "3X-UI Web Dashboard\n\nURL: http://$SERVER_IP:$ADMIN_PORT\nUser: $ADMIN_USER\n\nOpen this URL in your browser."
}

# ── Main Menu ──────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        local CHOICE
        CHOICE=$(whiptail --title "3X-UI Dynamic Management Console" \
            --menu "Node IP: $SERVER_IP  |  $NODE_NAME" 22 78 8 \
            "1" "View & Export Outline Keys (ss://)" \
            "2" "View & Export VLESS-Reality Keys (vless://)" \
            "3" "Change Shadowsocks Port (auto-updates firewall)" \
            "4" "Add New User with Data Quota" \
            "5" "Check Bandwidth Usage" \
            "6" "Rotate External Static IP (GCP only)" \
            "7" "Open 3X-UI Web Dashboard Link" \
            "8" "Exit" \
            3>&1 1>&2 2>&3) || break

        case "$CHOICE" in
            1) view_outline_keys ;;
            2) view_reality_keys ;;
            3) change_ss_port ;;
            4) add_new_user ;;
            5) check_bandwidth ;;
            6) rotate_ip ;;
            7) open_dashboard ;;
            8) break ;;
        esac
    done
}

main_menu
