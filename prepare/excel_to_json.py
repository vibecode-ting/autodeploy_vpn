#!/usr/bin/env python3
"""
prepare/excel_to_json.py — Convert filled requirements.xlsx → config/config.json

Reads Column D (Your Value) from the Excel file, merges with defaults,
and writes a valid config.json ready for step2.sh.

Usage:
    python3 prepare/excel_to_json.py
    python3 prepare/excel_to_json.py --excel /path/to/requirements.xlsx
    python3 prepare/excel_to_json.py --excel requirements.xlsx --output config/config.json
    python3 prepare/excel_to_json.py --validate   # Validate only, don't write
"""

import json
import argparse
import sys
from pathlib import Path

try:
    import openpyxl
except ImportError:
    print("Installing openpyxl...")
    import subprocess
    subprocess.run([sys.executable, "-m", "pip", "install", "openpyxl", "--quiet"], check=True)
    import openpyxl

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_XLSX  = SCRIPT_DIR / "requirements.xlsx"
DEFAULT_JSON  = PROJECT_ROOT / "config" / "config.json"

# ── JSON Key → Default value mapping ──────────────────────────────────────────
# Mirrors config.json structure exactly
DEFAULTS = {
    "node.name":           "ting-vvip-server(SG)",
    "node.timezone":       "Asia/Rangoon",
    "node.description":    "VPN Node",

    "admin.port":          2053,
    "admin.username":      "admin",
    "admin.password":      "ChangeMe123!",
    "admin.web_path":      "/",
    "admin.secret_token":  "auto-generate",
    "admin.enable_tls":    False,
    "admin.cert_file":     "",
    "admin.key_file":      "",

    "shadowsocks.enabled":  True,
    "shadowsocks.port":     25762,
    "shadowsocks.cipher":   "chacha20-ietf-poly1305",
    "shadowsocks.password": "auto-generate",
    "shadowsocks.network":  "tcp,udp",
    "shadowsocks.remark":   "Outline-SS",

    "vless_reality.enabled":      True,
    "vless_reality.port":         443,
    "vless_reality.sni":          "gateway.icloud.com",
    "vless_reality.dest":         "gateway.icloud.com:443",
    "vless_reality.server_names": ["gateway.icloud.com", "itunes.apple.com"],
    "vless_reality.flow":         "xtls-rprx-vision",
    "vless_reality.fingerprint":  "chrome",
    "vless_reality.private_key":  "",
    "vless_reality.public_key":   "",
    "vless_reality.short_id":     "",
    "vless_reality.remark":       "VLESS-Reality",
    "vless_reality.xver":         0,

    "system.swap_size_gb":     4,
    "system.enable_bbr":       True,
    "system.fd_limit":         1000000,
    "system.socket_buffer_mb": 64,
    "system.enable_fastopen":  True,

    "install.install_3xui":  True,
    "install.3xui_version":  "latest",
    "install.skip_if_running": False,
    "install.generate_keys": True,
    "install.show_qr":       True,

    "gcp.enabled":        False,
    "gcp.project":        "",
    "gcp.region":         "asia-southeast1",
    "gcp.zone":           "asia-southeast1-b",
    "gcp.network_tier":   "STANDARD",
    "gcp.vm_name":        "vpn-node-01",
    "gcp.machine_type":   "e2-small",
    "gcp.disk_size_gb":   20,
    "gcp.image_family":   "ubuntu-2204-lts",
    "gcp.image_project":  "ubuntu-os-cloud",

    "firewall.backend":               "auto",
    "firewall.allow_ssh":             True,
    "firewall.ssh_port":              22,
    "firewall.additional_tcp_ports":  [],
    "firewall.additional_udp_ports":  [],
    "firewall.gcp_rule_name":         "allow-vpn-traffic",
    "firewall.gcp_target_tags":       ["vpn-node"],

    "notifications.telegram_bot_token":  "",
    "notifications.telegram_chat_id":    "",
    "notifications.notify_on_startup":   False,
    "notifications.notify_on_quota_hit": False,
}

# Type coercions per key
INT_KEYS  = {"admin.port", "shadowsocks.port", "vless_reality.port",
             "system.swap_size_gb", "system.fd_limit", "system.socket_buffer_mb",
             "firewall.ssh_port", "gcp.disk_size_gb", "vless_reality.xver"}
BOOL_KEYS = {"shadowsocks.enabled", "vless_reality.enabled", "system.enable_bbr",
             "system.enable_fastopen", "install.install_3xui", "install.skip_if_running",
             "install.generate_keys", "install.show_qr", "gcp.enabled",
             "firewall.allow_ssh", "admin.enable_tls",
             "notifications.notify_on_startup", "notifications.notify_on_quota_hit"}
LIST_KEYS = {"vless_reality.server_names", "firewall.additional_tcp_ports",
             "firewall.additional_udp_ports", "firewall.gcp_target_tags"}


# ── Helpers ────────────────────────────────────────────────────────────────────

def coerce(key: str, raw_value):
    """Coerce raw Excel cell value to correct Python type."""
    if raw_value is None or str(raw_value).strip() == "":
        return DEFAULTS.get(key)

    val = str(raw_value).strip()

    if key in BOOL_KEYS:
        return val.lower() in ("true", "1", "yes", "on")

    if key in INT_KEYS:
        try:
            return int(float(val))
        except (ValueError, TypeError):
            return DEFAULTS.get(key)

    if key in LIST_KEYS:
        if val.startswith("["):
            try:
                return json.loads(val)
            except json.JSONDecodeError:
                pass
        # Comma-separated fallback
        items = [x.strip() for x in val.split(",") if x.strip()]
        # Try to int-cast items (for port lists)
        try:
            return [int(x) for x in items]
        except ValueError:
            return items

    # Keep as string (strip auto-generate sentinel)
    if val.lower() == "auto-generate":
        return ""
    return val


def set_nested(d: dict, dotted_key: str, value) -> None:
    """Set d[a][b][c] = value from 'a.b.c' key."""
    keys = dotted_key.split(".")
    for k in keys[:-1]:
        d = d.setdefault(k, {})
    d[keys[-1]] = value


def read_config_sheet(ws) -> dict:
    """
    Parse the '⚙ Config' sheet.
    Column B = JSON key (dotted path), Column D = user value.
    """
    overrides = {}
    for row in ws.iter_rows(min_row=4, values_only=True):
        json_key = row[1] if len(row) > 1 else None  # Column B
        user_val = row[3] if len(row) > 3 else None  # Column D

        if not json_key or str(json_key).startswith("_"):
            continue
        json_key = str(json_key).strip()
        if json_key not in DEFAULTS:
            continue
        if user_val is not None and str(user_val).strip() != "":
            overrides[json_key] = coerce(json_key, user_val)

    return overrides


def read_clients_sheet(ws) -> list:
    """
    Parse the '👥 Clients' sheet.
    Returns list of client dicts.
    """
    clients = []
    for row in ws.iter_rows(min_row=3, values_only=True):
        name    = row[0] if len(row) > 0 else None
        email   = row[1] if len(row) > 1 else None
        proto   = row[2] if len(row) > 2 else None
        data_gb = row[3] if len(row) > 3 else 0
        exp_d   = row[4] if len(row) > 4 else 0
        ip_lim  = row[5] if len(row) > 5 else 0
        enabled = row[6] if len(row) > 6 else "true"
        notes   = row[7] if len(row) > 7 else ""

        # Skip empty rows
        if not email or str(email).strip() == "":
            continue

        client = {
            "name":           str(name or "").strip(),
            "email":          str(email).strip(),
            "protocol":       str(proto or "shadowsocks").strip().lower(),
            "data_limit_gb":  int(float(data_gb)) if data_gb else 0,
            "expiry_days":    int(float(exp_d)) if exp_d else 0,
            "ip_limit":       int(float(ip_lim)) if ip_lim else 0,
            "enabled":        str(enabled or "true").lower() in ("true", "1", "yes"),
        }
        if notes:
            client["notes"] = str(notes).strip()
        clients.append(client)

    return clients


def build_config(overrides: dict, clients: list) -> dict:
    """Merge overrides into default config structure."""
    config = {
        "_comment": "VPN Node Configuration — Generated by prepare/excel_to_json.py",
        "_version": "2.0",
        "node": {},
        "admin": {},
        "shadowsocks": {},
        "vless_reality": {},
        "system": {},
        "install": {},
        "gcp": {},
        "firewall": {},
        "clients": [],
        "notifications": {},
    }

    # Populate from defaults
    for key, default in DEFAULTS.items():
        set_nested(config, key, default)

    # Apply user overrides
    for key, val in overrides.items():
        set_nested(config, key, val)
        print(f"  ✔ {key} = {val!r}")

    # Auto-fix: dest should match sni
    if not overrides.get("vless_reality.dest"):
        sni = config["vless_reality"]["sni"]
        config["vless_reality"]["dest"] = f"{sni}:443"

    # Auto-fix: server_names should include sni
    if not overrides.get("vless_reality.server_names"):
        sni = config["vless_reality"]["sni"]
        config["vless_reality"]["server_names"] = [sni]

    # Clients
    config["clients"] = clients if clients else [
        {"name": "default-outline", "email": "outline-client@vpn",
         "protocol": "shadowsocks", "data_limit_gb": 0, "expiry_days": 0, "enabled": True},
        {"name": "default-reality", "email": "reality-client@vpn",
         "protocol": "vless", "data_limit_gb": 0, "expiry_days": 0, "enabled": True},
    ]

    return config


# ── Validation ─────────────────────────────────────────────────────────────────

def validate_config(config: dict) -> list:
    """Return list of warning/error messages."""
    issues = []

    pwd = config.get("admin", {}).get("password", "")
    if pwd in ("ChangeMe123!", "admin", "password", "123456", ""):
        issues.append("⚠  admin.password is weak or default. Change before deploying!")

    admin_port = config.get("admin", {}).get("port", 2053)
    ss_port    = config.get("shadowsocks", {}).get("port", 25762)
    vless_port = config.get("vless_reality", {}).get("port", 443)
    ports = [admin_port, ss_port, vless_port]
    if len(ports) != len(set(ports)):
        issues.append(f"❌  Port conflict detected: {ports}")

    if config.get("gcp", {}).get("enabled") and not config["gcp"].get("project"):
        issues.append("⚠  gcp.enabled=true but gcp.project is empty")

    if vless_port != 443:
        issues.append(f"⚠  vless_reality.port={vless_port} — port 443 is recommended for best DPI bypass")

    return issues


# ── Main ────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Convert Excel config to JSON")
    parser.add_argument("--excel", default=str(DEFAULT_XLSX), help="Input .xlsx file")
    parser.add_argument("--output", default=str(DEFAULT_JSON), help="Output JSON file")
    parser.add_argument("--validate", action="store_true", help="Validate only, don't write")
    parser.add_argument("--pretty", action="store_true", default=True, help="Pretty-print JSON")
    args = parser.parse_args()

    xlsx_path = Path(args.excel)
    json_path = Path(args.output)

    if not xlsx_path.exists():
        print(f"❌ Excel file not found: {xlsx_path}")
        print(f"   Run first: python3 prepare/generate_excel.py")
        sys.exit(1)

    print(f"\n📊 Reading Excel: {xlsx_path}")
    wb = openpyxl.load_workbook(str(xlsx_path), data_only=True)

    # Find sheets by name (partial match for emoji prefix)
    config_ws = None
    clients_ws = None
    for name in wb.sheetnames:
        clean = name.replace("⚙", "").replace("👥", "").strip().lower()
        if "config" in clean:
            config_ws = wb[name]
        elif "client" in clean:
            clients_ws = wb[name]

    if not config_ws:
        print(f"❌ Could not find '⚙ Config' sheet. Sheets: {wb.sheetnames}")
        sys.exit(1)

    print("\n📋 Reading config overrides...")
    overrides = read_config_sheet(config_ws)

    clients = []
    if clients_ws:
        print("\n👥 Reading clients...")
        clients = read_clients_sheet(clients_ws)
        print(f"   Found {len(clients)} client(s)")

    print("\n🔧 Building config...")
    config = build_config(overrides, clients)

    print("\n✅ Validating...")
    issues = validate_config(config)
    if issues:
        print("\n⚠  Issues found:")
        for issue in issues:
            print(f"   {issue}")
    else:
        print("   No issues found!")

    if args.validate:
        print("\n(Validate-only mode — JSON not written)")
        return

    # Write JSON
    json_path.parent.mkdir(parents=True, exist_ok=True)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"\n✅ Config written to: {json_path}")
    print(f"\n🚀 Now deploy with:")
    print(f"   sudo bash step2.sh")
    print(f"   (or: sudo bash step2.sh --config {json_path})\n")


if __name__ == "__main__":
    main()
