#!/usr/bin/env python3
"""
manager/key_generator.py — Outline SIP002 & VLESS-Reality connection string exporter
Queries /etc/x-ui/x-ui.db and prints client connection URLs + QR codes.

Usage:
    python3 key_generator.py [--db /path/to/x-ui.db] [--qr] [--json]
"""

import sqlite3
import json
import base64
import sys
import os
import subprocess
import argparse
import urllib.request
import urllib.parse
import logging

logging.basicConfig(
    level=logging.INFO,
    format="[KEY_GEN] %(asctime)s %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

DEFAULT_DB = "/etc/x-ui/x-ui.db"


# ── Helpers ───────────────────────────────────────────────────────────────────

def get_external_ip() -> str:
    """Fetch external IP with multiple fallback services."""
    services = [
        "https://api.ipify.org",
        "https://icanhazip.com",
        "https://ifconfig.me",
        "https://ipinfo.io/ip",
    ]
    for svc in services:
        try:
            req = urllib.request.Request(svc, headers={"User-Agent": "curl/7.88"})
            with urllib.request.urlopen(req, timeout=5) as r:
                ip = r.read().decode().strip()
                if ip and "." in ip:
                    return ip
        except Exception:
            continue
    # Fallback: try ip route
    try:
        result = subprocess.run(
            ["hostname", "-I"], capture_output=True, text=True, timeout=3
        )
        return result.stdout.strip().split()[0]
    except Exception:
        return "YOUR_SERVER_IP"


def build_ss_url(server_ip: str, port: int, cipher: str, password: str, name: str) -> str:
    """
    Build SIP002 Shadowsocks URL compatible with Outline client.
    Format: ss://<BASE64_userinfo>@<host>:<port>/?outline=1#<name>
    """
    userinfo = f"{cipher}:{password}"
    userinfo_b64 = base64.urlsafe_b64encode(userinfo.encode()).decode().rstrip("=")
    encoded_name = urllib.parse.quote(name, safe="")
    return f"ss://{userinfo_b64}@{server_ip}:{port}/?outline=1#{encoded_name}"


def build_vless_url(
    server_ip: str, port: int, uuid: str,
    public_key: str, short_id: str, sni: str, name: str
) -> str:
    """
    Build VLESS-Reality URL for Xray/v2rayNG clients.
    """
    params = urllib.parse.urlencode({
        "type": "tcp",
        "security": "reality",
        "pbk": public_key,
        "fp": "chrome",
        "sni": sni,
        "sid": short_id,
        "flow": "xtls-rprx-vision",
        "spx": "%2F"
    })
    encoded_name = urllib.parse.quote(name, safe="")
    return f"vless://{uuid}@{server_ip}:{port}?{params}#{encoded_name}"


def print_qr(url: str, label: str) -> None:
    """Print QR code in terminal using qrencode or Python qrcode."""
    print(f"\n  QR Code for: {label}")
    # Try qrencode system tool
    if subprocess.run(["which", "qrencode"], capture_output=True).returncode == 0:
        subprocess.run(["qrencode", "-t", "ANSIUTF8", url])
        return
    # Try Python qrcode
    try:
        import qrcode
        qr = qrcode.QRCode()
        qr.add_data(url)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except ImportError:
        log.warning("qrencode/qrcode not available. Install: apt-get install qrencode")
        print(f"  URL: {url}")


def load_inbounds(db_path: str) -> list[dict]:
    """Query inbounds from x-ui.db."""
    if not os.path.exists(db_path):
        log.error(f"Database not found: {db_path}")
        sys.exit(1)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    try:
        rows = cursor.execute(
            "SELECT * FROM inbounds WHERE enable = 1 ORDER BY id"
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Export VPN connection keys")
    parser.add_argument("--db", default=DEFAULT_DB, help="Path to x-ui.db")
    parser.add_argument("--qr", action="store_true", help="Print QR codes")
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    args = parser.parse_args()

    log.info("Fetching external IP...")
    server_ip = get_external_ip()
    log.info(f"Server IP: {server_ip}")

    inbounds = load_inbounds(args.db)
    if not inbounds:
        log.warning("No enabled inbounds found in database.")
        sys.exit(0)

    results = []

    print("\n" + "=" * 65)
    print("  VPN CONNECTION KEYS")
    print(f"  Server: {server_ip}")
    print("=" * 65)

    for inbound in inbounds:
        protocol = inbound.get("protocol", "").lower()
        port = inbound.get("port")
        remark = inbound.get("remark", "VPN")
        settings_raw = inbound.get("settings", "{}")
        stream_raw = inbound.get("stream_settings", "{}")

        try:
            settings = json.loads(settings_raw)
            stream = json.loads(stream_raw)
        except json.JSONDecodeError:
            log.warning(f"Invalid JSON in inbound id={inbound.get('id')}. Skipping.")
            continue

        # ── Shadowsocks ───────────────────────────────────────────────────────
        if protocol == "shadowsocks":
            cipher = settings.get("method", "chacha20-ietf-poly1305")
            password = settings.get("password", "")
            if not password:
                # Try from clients list
                clients = settings.get("clients", [])
                if clients:
                    password = clients[0].get("password", "")
            if not password:
                log.warning("No password found for Shadowsocks inbound. Skipping.")
                continue

            url = build_ss_url(server_ip, port, cipher, password, remark)
            print(f"\n  [Shadowsocks / Outline Compatible]")
            print(f"  Port   : {port}")
            print(f"  Cipher : {cipher}")
            print(f"  Pass   : {password}")
            print(f"  URL    : {url}")
            if args.qr:
                print_qr(url, remark)
            results.append({"type": "shadowsocks", "url": url, "port": port,
                           "cipher": cipher, "password": password})

        # ── VLESS Reality ─────────────────────────────────────────────────────
        elif protocol == "vless":
            clients = settings.get("clients", [])
            if not clients:
                continue
            client = clients[0]
            client_uuid = client.get("id", "")
            reality_settings = stream.get("realitySettings", {})
            public_key = reality_settings.get("publicKey", "")
            # Public key may be stored differently — check shortIds
            short_ids = reality_settings.get("shortIds", [""])
            short_id = next((s for s in short_ids if s), "")
            sni = (reality_settings.get("serverNames") or ["gateway.icloud.com"])[0]

            if not public_key:
                log.warning("VLESS-Reality: publicKey not in DB stream settings.")
                # Try reading from credentials file
                cred_file = "/root/.vpn_credentials"
                if os.path.exists(cred_file):
                    with open(cred_file) as f:
                        for line in f:
                            if line.startswith("REALITY_PUBLIC_KEY="):
                                public_key = line.split("=", 1)[1].strip()
                                break

            url = build_vless_url(
                server_ip, port, client_uuid, public_key, short_id, sni, remark
            )
            print(f"\n  [VLESS-Reality (DPI Bypass)]")
            print(f"  Port      : {port}")
            print(f"  UUID      : {client_uuid}")
            print(f"  PublicKey : {public_key}")
            print(f"  ShortID   : {short_id}")
            print(f"  SNI       : {sni}")
            print(f"  URL       : {url}")
            if args.qr:
                print_qr(url, remark)
            results.append({"type": "vless-reality", "url": url, "port": port,
                           "uuid": client_uuid, "public_key": public_key})

    print("\n" + "=" * 65)

    if args.json:
        print("\n  JSON Output:")
        print(json.dumps({"server_ip": server_ip, "connections": results}, indent=2))


if __name__ == "__main__":
    main()
