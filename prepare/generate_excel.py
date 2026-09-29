#!/usr/bin/env python3
"""
prepare/generate_excel.py — Generate the requirements.xlsx configuration spreadsheet.

Run this on any machine with openpyxl installed to create the Excel template.

Usage:
    python3 prepare/generate_excel.py
    python3 prepare/generate_excel.py --output /path/to/my_config.xlsx
"""

import argparse
from pathlib import Path

try:
    import openpyxl
    from openpyxl.styles import (
        PatternFill, Font, Alignment, Border, Side, GradientFill
    )
    from openpyxl.utils import get_column_letter
    from openpyxl.worksheet.datavalidation import DataValidation
    from openpyxl.comments import Comment
except ImportError:
    print("Installing openpyxl...")
    import subprocess, sys
    subprocess.run([sys.executable, "-m", "pip", "install", "openpyxl", "--quiet"], check=True)
    import openpyxl
    from openpyxl.styles import PatternFill, Font, Alignment, Border, Side
    from openpyxl.utils import get_column_letter
    from openpyxl.worksheet.datavalidation import DataValidation

# ── Style Constants ────────────────────────────────────────────────────────────
HEADER_FILL    = PatternFill("solid", fgColor="1F3864")   # Dark navy
SECTION_FILL   = PatternFill("solid", fgColor="2E75B6")   # Blue
SUBSECT_FILL   = PatternFill("solid", fgColor="D6E4F7")   # Light blue
REQUIRED_FILL  = PatternFill("solid", fgColor="FFF2CC")   # Light yellow
OPTIONAL_FILL  = PatternFill("solid", fgColor="F2F2F2")   # Light grey
WARNING_FILL   = PatternFill("solid", fgColor="FCE4D6")   # Light orange
SUCCESS_FILL   = PatternFill("solid", fgColor="E2EFDA")   # Light green

WHITE_BOLD   = Font(color="FFFFFF", bold=True, size=11)
NAVY_BOLD    = Font(color="1F3864", bold=True, size=10)
BLUE_BOLD    = Font(color="FFFFFF", bold=True, size=10)
BLACK_NORMAL = Font(color="000000", size=10)
RED_BOLD     = Font(color="C00000", bold=True, size=10)
GREY_ITALIC  = Font(color="595959", italic=True, size=9)

CENTER  = Alignment(horizontal="center", vertical="center", wrap_text=True)
LEFT    = Alignment(horizontal="left", vertical="center", wrap_text=True)
BORDER  = Border(
    left=Side(style="thin", color="BFBFBF"),
    right=Side(style="thin", color="BFBFBF"),
    top=Side(style="thin", color="BFBFBF"),
    bottom=Side(style="thin", color="BFBFBF"),
)

def style_cell(cell, fill=None, font=None, alignment=None, border=True):
    if fill:      cell.fill = fill
    if font:      cell.font = font
    if alignment: cell.alignment = alignment
    if border:    cell.border = BORDER

def section_header(ws, row, title, colspan=5, fill=SECTION_FILL):
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=colspan)
    cell = ws.cell(row=row, column=1, value=f"  {title}")
    style_cell(cell, fill=fill, font=BLUE_BOLD, alignment=LEFT)
    ws.row_dimensions[row].height = 22

def col_headers(ws, row, headers):
    fills = [HEADER_FILL] * len(headers)
    for col, (header, fill) in enumerate(zip(headers, fills), 1):
        cell = ws.cell(row=row, column=col, value=header)
        style_cell(cell, fill=HEADER_FILL, font=WHITE_BOLD, alignment=CENTER)

def data_row(ws, row, values, required=False, note=None):
    """Write a data row with styling. values = [Field, JSON Key, Default, Your Value, Description]"""
    fill = REQUIRED_FILL if required else OPTIONAL_FILL
    for col, val in enumerate(values, 1):
        cell = ws.cell(row=row, column=col, value=val)
        if col == 4:  # "Your Value" column — editable
            style_cell(cell, fill=PatternFill("solid", fgColor="FFFDE7"), font=BLACK_NORMAL, alignment=LEFT)
        elif col == 1:
            style_cell(cell, fill=fill, font=NAVY_BOLD, alignment=LEFT)
        elif col == 2:
            style_cell(cell, fill=fill, font=Font(color="1F3864", size=9, italic=True), alignment=LEFT)
        elif col == 3:
            style_cell(cell, fill=fill, font=GREY_ITALIC, alignment=LEFT)
        else:
            style_cell(cell, fill=fill, font=BLACK_NORMAL, alignment=LEFT)
    ws.row_dimensions[row].height = 20

def blank_row(ws, row):
    ws.row_dimensions[row].height = 6

# ── Sheet 1: Main Config ───────────────────────────────────────────────────────
def build_main_sheet(wb):
    ws = wb.active
    ws.title = "⚙ Config"
    ws.sheet_properties.tabColor = "1F3864"

    # Column widths
    ws.column_dimensions["A"].width = 28  # Field Name
    ws.column_dimensions["B"].width = 26  # JSON Key
    ws.column_dimensions["C"].width = 26  # Default Value
    ws.column_dimensions["D"].width = 30  # YOUR VALUE
    ws.column_dimensions["E"].width = 50  # Description

    # Freeze header rows
    ws.freeze_panes = "D4"

    # ── Title Banner ──────────────────────────────────────────────────────────
    ws.merge_cells("A1:E1")
    title_cell = ws.cell(row=1, column=1,
        value="🔐  VPN Node Configuration — Fill Column D, then run: python3 prepare/excel_to_json.py")
    style_cell(title_cell, fill=PatternFill("solid", fgColor="1F3864"),
               font=Font(color="FFFFFF", bold=True, size=13), alignment=CENTER)
    ws.row_dimensions[1].height = 32

    ws.merge_cells("A2:E2")
    sub_cell = ws.cell(row=2, column=1,
        value="⭐ = Required    📝 = Fill Your Value in Column D    Leave blank to use defaults")
    style_cell(sub_cell, fill=PatternFill("solid", fgColor="2E75B6"),
               font=Font(color="FFFFFF", size=10), alignment=CENTER)
    ws.row_dimensions[2].height = 20

    # ── Column Headers ────────────────────────────────────────────────────────
    col_headers(ws, 3, ["Field Name", "JSON Key Path", "Default Value", "⭐ YOUR VALUE", "Description & Notes"])
    ws.row_dimensions[3].height = 24

    r = 4

    # ═══ NODE SETTINGS ═══════════════════════════════════════════════════════
    section_header(ws, r, "📡  NODE SETTINGS"); r += 1
    data_row(ws, r, ["Node Name", "node.name", "ting-vvip-server(SG)", "",
        "Display name shown in Outline client and VPN manager"], required=True); r += 1
    data_row(ws, r, ["Timezone", "node.timezone", "Asia/Rangoon", "",
        "Server timezone. Options: Asia/Rangoon, Asia/Singapore, UTC, Asia/Bangkok"]); r += 1
    data_row(ws, r, ["Description", "node.description", "VPN Node", "",
        "Free-text description for your own reference"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ ADMIN PANEL ══════════════════════════════════════════════════════════
    section_header(ws, r, "🛡  ADMIN PANEL (3X-UI Web Dashboard)"); r += 1
    data_row(ws, r, ["Admin Port", "admin.port", "2053", "",
        "Web UI port. Accessible at http://<IP>:<PORT>. Default: 2053"], required=True); r += 1
    data_row(ws, r, ["Admin Username", "admin.username", "admin", "",
        "Login username for the 3X-UI dashboard"], required=True); r += 1
    data_row(ws, r, ["Admin Password", "admin.password", "ChangeMe123!", "",
        "⚠ MUST CHANGE! Use a strong password (min 12 chars, mixed case + numbers)"], required=True); r += 1
    data_row(ws, r, ["Web Path", "admin.web_path", "/", "",
        "URL path for the panel. e.g. /admin/ for security by obscurity"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ SHADOWSOCKS ══════════════════════════════════════════════════════════
    section_header(ws, r, "🌐  SHADOWSOCKS — Outline Client Compatible"); r += 1
    data_row(ws, r, ["Enable Shadowsocks", "shadowsocks.enabled", "true", "",
        "true / false. Provides Outline-compatible SS connection"], required=True); r += 1
    data_row(ws, r, ["SS Port", "shadowsocks.port", "25762", "",
        "Port for Shadowsocks. Avoid 80, 8080 (often blocked). Range: 1024-65535"], required=True); r += 1
    data_row(ws, r, ["SS Cipher", "shadowsocks.cipher", "chacha20-ietf-poly1305", "",
        "Encryption cipher. Options: chacha20-ietf-poly1305, aes-256-gcm, aes-128-gcm\n(chacha20 recommended for mobile)"], required=True); r += 1
    data_row(ws, r, ["SS Password", "shadowsocks.password", "auto-generate", "",
        "Leave blank or 'auto-generate' to create a secure random password automatically"]); r += 1
    data_row(ws, r, ["SS Network", "shadowsocks.network", "tcp,udp", "",
        "Transport: tcp,udp (recommended), tcp only, or udp only"]); r += 1
    data_row(ws, r, ["SS Remark", "shadowsocks.remark", "Outline-SS", "",
        "Label shown in 3X-UI dashboard for this inbound"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ VLESS REALITY ════════════════════════════════════════════════════════
    section_header(ws, r, "🔮  VLESS-REALITY — DPI Bypass for High-Censorship Networks"); r += 1
    data_row(ws, r, ["Enable VLESS-Reality", "vless_reality.enabled", "true", "",
        "true / false. Provides DPI-resistant tunnel disguised as HTTPS"], required=True); r += 1
    data_row(ws, r, ["Reality Port", "vless_reality.port", "443", "",
        "Must be 443 for best DPI evasion (looks like HTTPS traffic)"], required=True); r += 1
    data_row(ws, r, ["Server Name (SNI)", "vless_reality.sni", "gateway.icloud.com", "",
        "Destination to impersonate. Options: gateway.icloud.com, www.microsoft.com\nChoose a site reachable from your VPS"], required=True); r += 1
    data_row(ws, r, ["Destination", "vless_reality.dest", "gateway.icloud.com:443", "",
        "Must match SNI + :443. Usually same as sni above"]); r += 1
    data_row(ws, r, ["Server Names (list)", "vless_reality.server_names", '["gateway.icloud.com"]', "",
        "JSON array of SNI names. Leave blank to auto-populate from sni field"]); r += 1
    data_row(ws, r, ["Client Fingerprint", "vless_reality.fingerprint", "chrome", "",
        "TLS fingerprint to mimic. Options: chrome, firefox, safari, ios, edge, 360"]); r += 1
    data_row(ws, r, ["Flow Control", "vless_reality.flow", "xtls-rprx-vision", "",
        "xtls-rprx-vision (best), or leave blank. Required for full XTLS performance"]); r += 1
    data_row(ws, r, ["Private Key", "vless_reality.private_key", "auto-generate", "",
        "x25519 private key. Leave blank to auto-generate via xray or Python"]); r += 1
    data_row(ws, r, ["Public Key", "vless_reality.public_key", "auto-generate", "",
        "x25519 public key. Leave blank to auto-generate. Shared with clients"]); r += 1
    data_row(ws, r, ["Short ID", "vless_reality.short_id", "auto-generate", "",
        "8-byte hex short ID. Leave blank to auto-generate"]); r += 1
    data_row(ws, r, ["Remark", "vless_reality.remark", "VLESS-Reality", "",
        "Label in 3X-UI dashboard"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ SYSTEM TUNING ════════════════════════════════════════════════════════
    section_header(ws, r, "⚡  SYSTEM TUNING"); r += 1
    data_row(ws, r, ["Swap Size (GB)", "system.swap_size_gb", "4", "",
        "Swap file size in GB. Prevents crashes on small VMs (e2-small has 2GB RAM)"]); r += 1
    data_row(ws, r, ["Enable BBR", "system.enable_bbr", "true", "",
        "true / false. TCP BBR congestion control — significantly improves throughput on lossy links"]); r += 1
    data_row(ws, r, ["File Descriptor Limit", "system.fd_limit", "1000000", "",
        "Max open files/sockets. 1000000 handles many concurrent streams"]); r += 1
    data_row(ws, r, ["Socket Buffer (MB)", "system.socket_buffer_mb", "64", "",
        "TCP socket buffer size in MB. 64 is safe for most VPS"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ INSTALL OPTIONS ══════════════════════════════════════════════════════
    section_header(ws, r, "📦  INSTALL OPTIONS"); r += 1
    data_row(ws, r, ["Install 3X-UI", "install.install_3xui", "true", "",
        "true / false. Set false to skip 3X-UI install (if already installed)"]); r += 1
    data_row(ws, r, ["3X-UI Version", "install.3xui_version", "latest", "",
        "3X-UI version tag (e.g. v2.3.11) or 'latest'"]); r += 1
    data_row(ws, r, ["Show QR Codes", "install.show_qr", "true", "",
        "true / false. Print QR codes in terminal after install"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ FIREWALL ═════════════════════════════════════════════════════════════
    section_header(ws, r, "🔒  FIREWALL SETTINGS"); r += 1
    data_row(ws, r, ["Backend", "firewall.backend", "auto", "",
        "auto = detect GCP then UFW then iptables\nOptions: auto, gcp, ufw, iptables"]); r += 1
    data_row(ws, r, ["SSH Port", "firewall.ssh_port", "22", "",
        "SSH port to keep open. ALWAYS kept open to prevent lockout"], required=True); r += 1
    data_row(ws, r, ["Extra TCP Ports", "firewall.additional_tcp_ports", "[]", "",
        'JSON array of extra TCP ports to open. e.g. [8080, 9000]']); r += 1
    data_row(ws, r, ["Extra UDP Ports", "firewall.additional_udp_ports", "[]", "",
        'JSON array of extra UDP ports to open']); r += 1
    blank_row(ws, r); r += 1

    # ═══ GCP (OPTIONAL) ═══════════════════════════════════════════════════════
    section_header(ws, r, "☁  GOOGLE CLOUD PLATFORM (Optional — only if using deploy_gcp.sh)"); r += 1
    data_row(ws, r, ["Enable GCP Mode", "gcp.enabled", "false", "",
        "true = use gcloud for VM/firewall management. false = standalone VPS mode"]); r += 1
    data_row(ws, r, ["GCP Project ID", "gcp.project", "", "",
        "Your GCP project ID (e.g. my-project-123456). Required if enabled=true"]); r += 1
    data_row(ws, r, ["GCP Region", "gcp.region", "asia-southeast1", "",
        "Singapore region — best for Myanmar DPI bypass. Options: us-central1, asia-east1"]); r += 1
    data_row(ws, r, ["GCP Zone", "gcp.zone", "asia-southeast1-b", "",
        "Zone within region. Usually <region>-a, -b, or -c"]); r += 1
    data_row(ws, r, ["Network Tier", "gcp.network_tier", "STANDARD", "",
        "STANDARD ($0.085/GB egress) or PREMIUM ($0.12/GB). STANDARD recommended"]); r += 1
    data_row(ws, r, ["VM Name", "gcp.vm_name", "vpn-node-01", "",
        "Name of the GCP VM instance to create"]); r += 1
    data_row(ws, r, ["Machine Type", "gcp.machine_type", "e2-small", "",
        "VM size. e2-micro (free tier), e2-small (1 vCPU, 2GB RAM, recommended)"]); r += 1
    blank_row(ws, r); r += 1

    # ═══ NOTIFICATIONS (OPTIONAL) ═════════════════════════════════════════════
    section_header(ws, r, "📬  TELEGRAM NOTIFICATIONS (Optional)"); r += 1
    data_row(ws, r, ["Telegram Bot Token", "notifications.telegram_bot_token", "", "",
        "Get from @BotFather on Telegram. Leave blank to disable notifications"]); r += 1
    data_row(ws, r, ["Telegram Chat ID", "notifications.telegram_chat_id", "", "",
        "Your Telegram chat/group ID. Bot must be added to the chat"]); r += 1
    data_row(ws, r, ["Notify on Startup", "notifications.notify_on_startup", "false", "",
        "true / false. Send Telegram message after setup completes"]); r += 1

    # ── Legend row at bottom ─────────────────────────────────────────────────
    r += 2
    ws.merge_cells(f"A{r}:E{r}")
    legend = ws.cell(row=r, column=1,
        value="🟡 Yellow rows = Fill your value    ⭐ Required fields must be filled    📝 Leave blank = use default value")
    style_cell(legend, fill=PatternFill("solid", fgColor="FFF9C4"),
               font=Font(color="5D4037", size=10, italic=True), alignment=CENTER)
    ws.row_dimensions[r].height = 22

    return ws

# ── Sheet 2: Clients ───────────────────────────────────────────────────────────
def build_clients_sheet(wb):
    ws = wb.create_sheet("👥 Clients")
    ws.sheet_properties.tabColor = "2E75B6"

    col_widths = [20, 30, 18, 18, 18, 18, 12, 40]
    cols = ["A","B","C","D","E","F","G","H"]
    for c, w in zip(cols, col_widths):
        ws.column_dimensions[c].width = w

    # Title
    ws.merge_cells("A1:H1")
    t = ws.cell(row=1, column=1, value="👥  Client Users — Add one row per user/device")
    style_cell(t, fill=PatternFill("solid", fgColor="1F3864"),
               font=Font(color="FFFFFF", bold=True, size=13), alignment=CENTER)
    ws.row_dimensions[1].height = 30

    # Headers
    headers = ["Display Name", "Email (unique ID)", "Protocol",
               "Data Limit (GB)", "Expiry (days)", "IP Limit", "Enabled", "Notes"]
    for col, h in enumerate(headers, 1):
        cell = ws.cell(row=2, column=col, value=h)
        style_cell(cell, fill=HEADER_FILL, font=WHITE_BOLD, alignment=CENTER)
    ws.row_dimensions[2].height = 22
    ws.freeze_panes = "A3"

    # Default rows
    defaults = [
        ["Outline Default", "outline-client@vpn", "shadowsocks", 0, 0, 0, "true", "Default SS/Outline user"],
        ["Reality Default", "reality-client@vpn", "vless", 0, 0, 0, "true", "Default VLESS-Reality user"],
        ["", "", "shadowsocks", 0, 0, 0, "true", "Add more users here"],
        ["", "", "vless", 0, 0, 0, "true", "Add more users here"],
    ]
    for r, row in enumerate(defaults, 3):
        fill = SUCCESS_FILL if r <= 4 else OPTIONAL_FILL
        for c, val in enumerate(row, 1):
            cell = ws.cell(row=r, column=c, value=val)
            style_cell(cell, fill=fill, font=BLACK_NORMAL, alignment=LEFT)
        ws.row_dimensions[r].height = 20

    # Data validation for Protocol column
    dv = DataValidation(type="list", formula1='"shadowsocks,vless"', allow_blank=True)
    ws.add_data_validation(dv)
    dv.add(f"C3:C50")

    # Data validation for Enabled column
    dv2 = DataValidation(type="list", formula1='"true,false"', allow_blank=True)
    ws.add_data_validation(dv2)
    dv2.add(f"G3:G50")

    # Info row
    r_info = 8
    ws.merge_cells(f"A{r_info}:H{r_info}")
    info = ws.cell(row=r_info, column=1,
        value="💡 Protocol: 'shadowsocks' = Outline compatible | 'vless' = VLESS-Reality  |  Data Limit 0 = unlimited  |  Expiry 0 = never")
    style_cell(info, fill=PatternFill("solid", fgColor="E3F2FD"),
               font=Font(color="1565C0", size=10, italic=True), alignment=CENTER)

    return ws

# ── Sheet 3: How to Use ────────────────────────────────────────────────────────
def build_guide_sheet(wb):
    ws = wb.create_sheet("📖 How To Use")
    ws.sheet_properties.tabColor = "4CAF50"
    ws.column_dimensions["A"].width = 5
    ws.column_dimensions["B"].width = 80

    steps = [
        ("TITLE", "📖  Quick Start Guide — 3 Steps to Launch Your VPN Node"),
        ("BLANK", ""),
        ("STEP", "STEP 1 — Install Prerequisites (Run on your VPS)"),
        ("CODE", "sudo bash step1.sh"),
        ("NOTE", "This installs: Python, git, gcloud CLI, GitHub CLI, UFW, qrencode, bcrypt, and sets up auth."),
        ("BLANK", ""),
        ("STEP", "STEP 2 — Configure (Fill this Excel file)"),
        ("CODE", "Fill in Column D on the '⚙ Config' sheet with your values"),
        ("CODE", "Add users in the '👥 Clients' sheet"),
        ("CODE", "python3 prepare/excel_to_json.py   ← converts your Excel → config/config.json"),
        ("NOTE", "The JSON file will be saved to config/config.json automatically."),
        ("BLANK", ""),
        ("STEP", "STEP 3 — Deploy VPN (Run on your VPS)"),
        ("CODE", "sudo bash step2.sh"),
        ("CODE", "sudo bash step2.sh --config /path/to/config.json   ← custom JSON path"),
        ("NOTE", "Completes in < 3 minutes. Admin panel URL is printed at the end."),
        ("BLANK", ""),
        ("SECTION", "📁  File Reference"),
        ("INFO", "step1.sh            → Prerequisites installer (run first)"),
        ("INFO", "step2.sh            → Main VPN installer (reads from config.json)"),
        ("INFO", "config/config.json  → Master config file (generated from this Excel)"),
        ("INFO", "manager/menu.sh     → Interactive TUI management console"),
        ("INFO", "manager/key_generator.py → Export connection keys + QR codes"),
        ("INFO", "/root/.vpn_credentials  → Generated admin + VPN credentials (root only)"),
        ("INFO", "/var/log/vpn_step2.log  → Full installation log"),
        ("BLANK", ""),
        ("SECTION", "🔌  Default Ports"),
        ("INFO", "22    TCP  → SSH (always kept open)"),
        ("INFO", "443   TCP  → VLESS-Reality (DPI bypass)"),
        ("INFO", "2053  TCP  → 3X-UI Admin Dashboard"),
        ("INFO", "25762 TCP+UDP → Shadowsocks / Outline Client"),
        ("BLANK", ""),
        ("SECTION", "🔐  Security Checklist"),
        ("WARN", "⚠  Change the admin password IMMEDIATELY after first login!"),
        ("WARN", "⚠  /root/.vpn_credentials is chmod 600 — never share it"),
        ("WARN", "⚠  Do not expose port 2053 publicly without HTTPS or IP whitelist"),
        ("INFO", "✅ Admin password is bcrypt-hashed before storing in SQLite"),
        ("INFO", "✅ Shadowsocks password is 24-char cryptographically random"),
        ("INFO", "✅ VLESS-Reality keys are x25519 (auto-generated per deployment)"),
        ("BLANK", ""),
        ("SECTION", "📱  Client Apps"),
        ("INFO", "Outline (Android/iOS/Windows): getoutline.org — paste ss:// URL"),
        ("INFO", "v2rayNG (Android): github.com/2dust/v2rayNG — paste vless:// URL"),
        ("INFO", "Sing-box (iOS/Android): install from App Store — scan QR code"),
        ("INFO", "Nekoray (Windows/Linux): scan vless:// QR or import URL"),
    ]

    r = 1
    for kind, text in steps:
        if kind == "BLANK":
            ws.row_dimensions[r].height = 8
            r += 1
            continue

        ws.merge_cells(f"A{r}:B{r}")
        cell = ws.cell(row=r, column=1, value=text)

        if kind == "TITLE":
            style_cell(cell, fill=PatternFill("solid", fgColor="1F3864"),
                       font=Font(color="FFFFFF", bold=True, size=14), alignment=LEFT)
            ws.row_dimensions[r].height = 32
        elif kind == "STEP":
            style_cell(cell, fill=PatternFill("solid", fgColor="2E75B6"),
                       font=Font(color="FFFFFF", bold=True, size=11), alignment=LEFT)
            ws.row_dimensions[r].height = 24
        elif kind == "CODE":
            style_cell(cell, fill=PatternFill("solid", fgColor="263238"),
                       font=Font(color="80CBC4", size=10, name="Courier New"), alignment=LEFT)
            ws.row_dimensions[r].height = 22
        elif kind == "NOTE":
            style_cell(cell, fill=PatternFill("solid", fgColor="E8F5E9"),
                       font=Font(color="1B5E20", size=10, italic=True), alignment=LEFT)
            ws.row_dimensions[r].height = 20
        elif kind == "SECTION":
            style_cell(cell, fill=PatternFill("solid", fgColor="37474F"),
                       font=Font(color="FFFFFF", bold=True, size=10), alignment=LEFT)
            ws.row_dimensions[r].height = 22
        elif kind == "INFO":
            style_cell(cell, fill=OPTIONAL_FILL,
                       font=Font(color="212121", size=10, name="Courier New"), alignment=LEFT)
            ws.row_dimensions[r].height = 20
        elif kind == "WARN":
            style_cell(cell, fill=WARNING_FILL,
                       font=Font(color="BF360C", bold=True, size=10), alignment=LEFT)
            ws.row_dimensions[r].height = 22

        r += 1

    return ws

# ── Sheet 4: Cipher Reference ──────────────────────────────────────────────────
def build_cipher_sheet(wb):
    ws = wb.create_sheet("🔑 Cipher Reference")
    ws.sheet_properties.tabColor = "9C27B0"
    ws.column_dimensions["A"].width = 32
    ws.column_dimensions["B"].width = 15
    ws.column_dimensions["C"].width = 15
    ws.column_dimensions["D"].width = 50

    ws.merge_cells("A1:D1")
    t = ws.cell(row=1, column=1, value="🔑  Shadowsocks Cipher Reference")
    style_cell(t, fill=PatternFill("solid", fgColor="4A148C"),
               font=Font(color="FFFFFF", bold=True, size=13), alignment=CENTER)
    ws.row_dimensions[1].height = 28

    headers = ["Cipher Name", "Security", "Speed", "Notes"]
    for c, h in enumerate(headers, 1):
        cell = ws.cell(row=2, column=c, value=h)
        style_cell(cell, fill=HEADER_FILL, font=WHITE_BOLD, alignment=CENTER)
    ws.row_dimensions[2].height = 22

    ciphers = [
        ("chacha20-ietf-poly1305", "⭐ Excellent", "⭐ Fast", "✅ RECOMMENDED — Best for mobile, hardware-optimized on ARM"),
        ("aes-256-gcm", "⭐ Excellent", "Fast (AES-NI)", "Good for desktops/servers with AES hardware acceleration"),
        ("aes-128-gcm", "Excellent", "Fastest (AES-NI)", "Slightly lower security margin than 256, faster on AES-NI hardware"),
        ("aes-256-cfb", "Good", "Moderate", "Older cipher, lacks AEAD — not recommended for new deployments"),
        ("aes-128-cfb", "Good", "Moderate", "Legacy — avoid on new deployments"),
        ("rc4-md5", "❌ Broken", "Fast", "DO NOT USE — cryptographically broken"),
    ]
    fills = [SUCCESS_FILL, SUCCESS_FILL, OPTIONAL_FILL, OPTIONAL_FILL, WARNING_FILL, WARNING_FILL]
    for r, (cipher, sec, spd, note) in enumerate(ciphers, 3):
        for c, val in enumerate([cipher, sec, spd, note], 1):
            cell = ws.cell(row=r, column=c, value=val)
            style_cell(cell, fill=fills[r-3], font=BLACK_NORMAL, alignment=LEFT)
        ws.row_dimensions[r].height = 22

    # SNI Reference
    ws.merge_cells("A11:D11")
    t2 = ws.cell(row=11, column=1, value="🌐  VLESS-Reality SNI Options")
    style_cell(t2, fill=PatternFill("solid", fgColor="4A148C"),
               font=Font(color="FFFFFF", bold=True, size=13), alignment=CENTER)
    ws.row_dimensions[11].height = 28

    sni_headers = ["SNI / Destination", "Organization", "Reliability", "Notes"]
    for c, h in enumerate(sni_headers, 1):
        cell = ws.cell(row=12, column=c, value=h)
        style_cell(cell, fill=HEADER_FILL, font=WHITE_BOLD, alignment=CENTER)

    sni_data = [
        ("gateway.icloud.com", "Apple", "⭐ Excellent", "✅ DEFAULT — Very reliable, high traffic volume disguise"),
        ("itunes.apple.com", "Apple", "⭐ Excellent", "Good backup to iCloud gateway"),
        ("www.microsoft.com", "Microsoft", "Excellent", "Large CDN, good fallback"),
        ("www.apple.com", "Apple", "Excellent", "Alternative Apple SNI"),
        ("dl.google.com", "Google", "Good", "Google CDN, may vary by region"),
    ]
    for r, row_data in enumerate(sni_data, 13):
        for c, val in enumerate(row_data, 1):
            cell = ws.cell(row=r, column=c, value=val)
            fill = SUCCESS_FILL if r == 13 else OPTIONAL_FILL
            style_cell(cell, fill=fill, font=BLACK_NORMAL, alignment=LEFT)
        ws.row_dimensions[r].height = 22

    return ws


# ── Main ────────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Generate VPN config Excel template")
    parser.add_argument("--output", default=None, help="Output .xlsx file path")
    args = parser.parse_args()

    # Default output path: same directory as this script / requirements.xlsx
    script_dir = Path(__file__).parent
    output_path = Path(args.output) if args.output else script_dir / "requirements.xlsx"

    wb = openpyxl.Workbook()
    build_main_sheet(wb)
    build_clients_sheet(wb)
    build_guide_sheet(wb)
    build_cipher_sheet(wb)

    # Save
    output_path.parent.mkdir(parents=True, exist_ok=True)
    wb.save(str(output_path))
    print(f"\n✅ Excel template generated: {output_path}")
    print(f"   Open it, fill Column D on '⚙ Config' sheet, then run:")
    print(f"   python3 prepare/excel_to_json.py\n")


if __name__ == "__main__":
    main()
