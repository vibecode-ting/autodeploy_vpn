#!/usr/bin/env python3
"""
core/db_seeder.py — Programmatic SQLite database injector for 3X-UI
Reads ALL configuration from config/config.json (or --config path).

Usage:
    python3 core/db_seeder.py [--config /path/to/config.json] [--db /path/to/x-ui.db]
    python3 core/db_seeder.py --dry-run
"""

import sqlite3
import json
import uuid
import os
import sys
import subprocess
import secrets
import hashlib
import base64
import argparse
import logging
from pathlib import Path
from typing import Optional
from datetime import datetime, timedelta

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE = "/var/log/vpn_step2.log"
logging.basicConfig(
    level=logging.INFO,
    format="[DB_SEEDER] %(asctime)s %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, mode="a"),
    ],
)
log = logging.getLogger(__name__)

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR   = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_DB   = "/etc/x-ui/x-ui.db"
DEFAULT_CFG  = PROJECT_ROOT / "config" / "config.json"

XRAY_BIN_PATHS = [
    "/usr/local/x-ui/bin/xray-linux-amd64",
    "/usr/local/x-ui/bin/xray",
    "/usr/bin/xray",
    "/usr/local/bin/xray",
]


# ── Config Loader ─────────────────────────────────────────────────────────────

def load_config(config_path: str) -> dict:
    p = Path(config_path)
    if not p.exists():
        log.error(f"Config not found: {config_path}")
        sys.exit(1)
    with open(p) as f:
        cfg = json.load(f)
    log.info(f"Loaded config from {config_path}")
    return cfg



# ── Crypto Helpers ────────────────────────────────────────────────────────────

def bcrypt_hash(password: str) -> str:
    """Hash with bcrypt (preferred) or auto-install."""
    try:
        import bcrypt as bcrypt_lib
        return bcrypt_lib.hashpw(password.encode(), bcrypt_lib.gensalt(rounds=10)).decode()
    except ImportError:
        log.info("bcrypt not found. Installing...")
        try:
            PIP_OPTS = []
            ver = sys.version_info
            if ver.major > 3 or (ver.major == 3 and ver.minor >= 11):
                PIP_OPTS = ["--break-system-packages"]
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "bcrypt", "--quiet"] + PIP_OPTS,
                check=True, timeout=120
            )
            import bcrypt as bcrypt_lib
            return bcrypt_lib.hashpw(password.encode(), bcrypt_lib.gensalt(rounds=10)).decode()
        except Exception as e:
            log.error(f"bcrypt install failed: {e}")
            log.warning("Using SHA-256 fallback — 3X-UI auth may not work correctly!")
            return hashlib.sha256(password.encode()).hexdigest()


def generate_ss_password(length: int = 24) -> str:
    return secrets.token_urlsafe(length)


def find_xray_binary() -> Optional[str]:
    for path in XRAY_BIN_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    try:
        result = subprocess.run(
            ["find", "/usr", "/opt", "/usr/local", "-name", "xray*", "-type", "f"],
            capture_output=True, text=True, timeout=10
        )
        for line in result.stdout.splitlines():
            line = line.strip()
            if line and os.access(line, os.X_OK) and "xray" in Path(line).name:
                return line
    except Exception:
        pass
    return None


def generate_reality_keys(xray_bin: Optional[str]) -> tuple:
    """Generate x25519 key pair via xray or Python cryptography."""
    if xray_bin:
        try:
            result = subprocess.run(
                [xray_bin, "x25519"], capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                priv = pub = ""
                for line in result.stdout.strip().splitlines():
                    if "Private key:" in line:
                        priv = line.split(":", 1)[1].strip()
                    elif "Public key:" in line:
                        pub = line.split(":", 1)[1].strip()
                if priv and pub:
                    log.info("Reality keys generated via xray x25519.")
                    return priv, pub
        except Exception as e:
            log.warning(f"xray x25519 failed: {e}")

    # Fallback: Python cryptography
    try:
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    except ImportError:
        log.info("Installing cryptography library...")
        PIP_OPTS = []
        ver = sys.version_info
        if ver.major > 3 or (ver.major == 3 and ver.minor >= 11):
            PIP_OPTS = ["--break-system-packages"]
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "cryptography", "--quiet"] + PIP_OPTS,
            check=True, timeout=120
        )
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    private = X25519PrivateKey.generate()
    public  = private.public_key()
    priv_b64 = base64.urlsafe_b64encode(private.private_bytes_raw()).rstrip(b"=").decode()
    pub_b64  = base64.urlsafe_b64encode(public.public_bytes_raw()).rstrip(b"=").decode()
    log.info("Reality keys generated via Python cryptography.")
    return priv_b64, pub_b64


def generate_short_id(length: int = 8) -> str:
    return secrets.token_hex(length)


def expiry_timestamp(days: int) -> int:
    """Return Unix milliseconds for expiry, or 0 for never."""
    if days <= 0:
        return 0
    dt = datetime.utcnow() + timedelta(days=days)
    return int(dt.timestamp() * 1000)


# ── Schema ────────────────────────────────────────────────────────────────────

def ensure_schema(cursor: sqlite3.Cursor) -> None:
    cursor.executescript("""
        CREATE TABLE IF NOT EXISTS "settings" (
            "id"    INTEGER PRIMARY KEY AUTOINCREMENT,
            "key"   TEXT NOT NULL UNIQUE,
            "value" TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS "users" (
            "id"           INTEGER PRIMARY KEY AUTOINCREMENT,
            "username"     TEXT NOT NULL UNIQUE,
            "password"     TEXT NOT NULL,
            "secret"       TEXT NOT NULL DEFAULT '',
            "login_secret" TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS "inbounds" (
            "id"              INTEGER PRIMARY KEY AUTOINCREMENT,
            "user_id"         INTEGER NOT NULL DEFAULT 1,
            "up"              INTEGER NOT NULL DEFAULT 0,
            "down"            INTEGER NOT NULL DEFAULT 0,
            "total"           INTEGER NOT NULL DEFAULT 0,
            "remark"          TEXT NOT NULL,
            "enable"          INTEGER NOT NULL DEFAULT 1,
            "expiry_time"     INTEGER NOT NULL DEFAULT 0,
            "listen"          TEXT NOT NULL DEFAULT '',
            "port"            INTEGER NOT NULL,
            "protocol"        TEXT NOT NULL,
            "settings"        TEXT NOT NULL,
            "stream_settings" TEXT NOT NULL,
            "tag"             TEXT NOT NULL DEFAULT '',
            "sniffing"        TEXT NOT NULL DEFAULT '{}'
        );
        CREATE TABLE IF NOT EXISTS "inbound_client_ips" (
            "id"           INTEGER PRIMARY KEY AUTOINCREMENT,
            "client_email" TEXT NOT NULL UNIQUE,
            "ips"          TEXT
        );
    """)


# ── Seeders ───────────────────────────────────────────────────────────────────

def seed_settings(cursor: sqlite3.Cursor, cfg: dict) -> None:
    admin = cfg.get("admin", {})
    settings = {
        "webPort":      str(admin.get("port", 2053)),
        "webListen":    admin.get("listen", ""),
        "webBasePath":  admin.get("web_path", "/"),
        "webCertFile":  admin.get("cert_file", ""),
        "webKeyFile":   admin.get("key_file", ""),
        "secret":       secrets.token_hex(32),
        "timeLocation": cfg.get("node", {}).get("timezone", "Asia/Rangoon"),
    }
    for key, value in settings.items():
        cursor.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, str(value))
        )
    log.info(f"Settings seeded (panel port={admin.get('port', 2053)}, path={admin.get('web_path', '/')})")


def seed_admin_user(cursor: sqlite3.Cursor, cfg: dict) -> str:
    admin = cfg.get("admin", {})
    username = admin.get("username", "admin")
    password = admin.get("password", "ChangeMe123!")
    secret   = secrets.token_hex(16)

    log.info(f"Hashing password for user '{username}'...")
    hashed = bcrypt_hash(password)

    cursor.execute("DELETE FROM users WHERE username = ?", (username,))
    cursor.execute(
        "INSERT INTO users (username, password, secret) VALUES (?, ?, ?)",
        (username, hashed, secret)
    )
    log.info(f"Admin user '{username}' seeded.")
    return password


def build_ss_clients(cfg: dict, default_password: str) -> list[dict]:
    """Build client list for SS inbound from config.clients."""
    clients = cfg.get("clients", [])
    result = []
    ss_cfg = cfg.get("shadowsocks", {})
    cipher = ss_cfg.get("cipher", "chacha20-ietf-poly1305")

    for c in clients:
        if c.get("protocol", "").lower() != "shadowsocks":
            continue
        if not c.get("enabled", True):
            continue
        result.append({
            "method":   cipher,
            "password": default_password,
            "email":    c.get("email", f"{c.get('name', 'client')}@vpn"),
        })

    if not result:
        result.append({
            "method":   cipher,
            "password": default_password,
            "email":    "outline-client@vpn",
        })
    return result


def seed_shadowsocks(cursor: sqlite3.Cursor, cfg: dict) -> dict:
    ss = cfg.get("shadowsocks", {})
    if not ss.get("enabled", True):
        log.info("Shadowsocks disabled. Skipping.")
        return {}

    port   = ss.get("port", 25762)
    cipher = ss.get("cipher", "chacha20-ietf-poly1305")
    pw     = ss.get("password", "")
    remark = ss.get("remark", "Outline-SS")
    network = ss.get("network", "tcp,udp")

    if not pw or pw in ("auto-generate", ""):
        pw = generate_ss_password()
        log.info(f"Generated SS password: {pw}")

    clients = build_ss_clients(cfg, pw)

    ss_settings = {
        "method":   cipher,
        "password": pw,
        "network":  network,
        "clients":  clients,
    }
    stream_settings = {"network": "tcp"}
    sniffing = {"enabled": False, "destOverride": []}

    cursor.execute("""
        INSERT OR REPLACE INTO inbounds
        (user_id, up, down, total, remark, enable, expiry_time, listen,
         port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (1, 0, 0, 0, ?, 1, 0, '', ?, 'shadowsocks', ?, ?, 'inbound-ss', ?)
    """, (remark, port, json.dumps(ss_settings), json.dumps(stream_settings), json.dumps(sniffing)))

    log.info(f"Shadowsocks inbound seeded: port={port}, cipher={cipher}")
    return {"port": port, "cipher": cipher, "password": pw}


def build_vless_clients(cfg: dict) -> list[dict]:
    """Build VLESS client list from config.clients."""
    clients = cfg.get("clients", [])
    result = []

    for c in clients:
        if c.get("protocol", "").lower() != "vless":
            continue
        if not c.get("enabled", True):
            continue
        result.append({
            "id":         str(uuid.uuid4()),
            "flow":       "xtls-rprx-vision",
            "email":      c.get("email", f"{c.get('name', 'client')}@vpn"),
            "limitIp":    c.get("ip_limit", 0),
            "totalGB":    c.get("data_limit_gb", 0) * (1024 ** 3),
            "expiryTime": expiry_timestamp(c.get("expiry_days", 0)),
            "enable":     True,
            "tgId":       "",
            "subId":      "",
        })

    if not result:
        result.append({
            "id":         str(uuid.uuid4()),
            "flow":       "xtls-rprx-vision",
            "email":      "reality-client@vpn",
            "limitIp":    0,
            "totalGB":    0,
            "expiryTime": 0,
            "enable":     True,
            "tgId":       "",
            "subId":      "",
        })
    return result


def seed_vless_reality(cursor: sqlite3.Cursor, cfg: dict, xray_bin: Optional[str]) -> dict:
    vr = cfg.get("vless_reality", {})
    if not vr.get("enabled", True):
        log.info("VLESS-Reality disabled. Skipping.")
        return {}

    port    = vr.get("port", 443)
    sni     = vr.get("sni", "gateway.icloud.com")
    dest    = vr.get("dest", f"{sni}:443")
    names   = vr.get("server_names", [sni])
    flow    = vr.get("flow", "xtls-rprx-vision")
    fp      = vr.get("fingerprint", "chrome")
    remark  = vr.get("remark", "VLESS-Reality")
    xver    = vr.get("xver", 0)

    priv_key = vr.get("private_key", "")
    pub_key  = vr.get("public_key", "")
    short_id = vr.get("short_id", "")

    if not priv_key or not pub_key:
        priv_key, pub_key = generate_reality_keys(xray_bin)
    if not short_id:
        short_id = generate_short_id(8)

    if not names:
        names = [sni]

    clients = build_vless_clients(cfg)
    primary_uuid = clients[0]["id"] if clients else str(uuid.uuid4())

    vless_settings = {
        "clients":    clients,
        "decryption": "none",
        "fallbacks":  [],
    }

    stream_settings = {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": {
            "show":        False,
            "dest":        dest,
            "xver":        xver,
            "serverNames": names,
            "privateKey":  priv_key,
            "publicKey":   pub_key,
            "shortIds":    ["", short_id],
            "fingerprint": fp,
        },
        "tcpSettings": {
            "acceptProxyProtocol": False,
            "header": {"type": "none"},
        },
    }

    sniffing = {
        "enabled":    True,
        "destOverride": ["http", "tls", "quic", "fakedns"],
    }

    cursor.execute("""
        INSERT OR REPLACE INTO inbounds
        (user_id, up, down, total, remark, enable, expiry_time, listen,
         port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (1, 0, 0, 0, ?, 1, 0, '', ?, 'vless', ?, ?, 'inbound-reality', ?)
    """, (remark, port, json.dumps(vless_settings), json.dumps(stream_settings), json.dumps(sniffing)))

    log.info(f"VLESS-Reality inbound seeded: port={port}, sni={sni}")
    return {
        "port":        port,
        "uuid":        primary_uuid,
        "public_key":  pub_key,
        "private_key": priv_key,
        "short_id":    short_id,
        "sni":         sni,
        "fingerprint": fp,
    }


def write_credentials(cfg: dict, admin_pass: str, ss_info: dict, reality_info: dict) -> None:
    """Write all generated credentials to /root/.vpn_credentials."""
    admin = cfg.get("admin", {})
    lines = [
        "# ============================================================",
        "# VPN Node Credentials — KEEP SECURE",
        f"# Generated: {datetime.now().isoformat()}",
        "# ============================================================",
        "",
        "## Admin Panel",
        f"ADMIN_URL=http://<SERVER_IP>:{admin.get('port', 2053)}{admin.get('web_path', '/')}",
        f"ADMIN_USER={admin.get('username', 'admin')}",
        f"ADMIN_PASS={admin_pass}",
        "",
    ]
    if ss_info:
        lines += [
            "## Shadowsocks (Outline Compatible)",
            f"SS_PORT={ss_info.get('port')}",
            f"SS_CIPHER={ss_info.get('cipher')}",
            f"SS_PASSWORD={ss_info.get('password')}",
            "",
        ]
    if reality_info:
        r = reality_info
        lines += [
            "## VLESS-Reality",
            f"REALITY_PORT={r.get('port')}",
            f"REALITY_UUID={r.get('uuid')}",
            f"REALITY_PUBLIC_KEY={r.get('public_key')}",
            f"REALITY_PRIVATE_KEY={r.get('private_key')}",
            f"REALITY_SHORT_ID={r.get('short_id')}",
            f"REALITY_SNI={r.get('sni')}",
            f"REALITY_FINGERPRINT={r.get('fingerprint')}",
            "",
        ]
    cred_path = "/root/.vpn_credentials"
    with open(cred_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(cred_path, 0o600)
    log.info(f"Credentials saved to {cred_path} (chmod 600)")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="3X-UI SQLite database seeder")
    parser.add_argument("--config", default=str(DEFAULT_CFG), help="Path to config.json")
    parser.add_argument("--db",     default=DEFAULT_DB, help="Path to x-ui.db")
    parser.add_argument("--dry-run", action="store_true", help="Preview without writing")
    args = parser.parse_args()

    if not args.dry_run and os.geteuid() != 0:
        log.error("Must run as root")
        sys.exit(1)

    cfg = load_config(args.config)

    if args.dry_run:
        log.info("DRY RUN — no changes.")
        print(json.dumps(cfg, indent=2))
        return

    db_path = args.db
    os.makedirs(os.path.dirname(db_path), exist_ok=True)

    xray_bin = find_xray_binary()
    log.info(f"Xray binary: {xray_bin or 'not found (using Python fallback)'}")

    log.info(f"Opening database: {db_path}")
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    try:
        ensure_schema(cursor)
        seed_settings(cursor, cfg)
        admin_pass   = seed_admin_user(cursor, cfg)
        ss_info      = seed_shadowsocks(cursor, cfg)
        reality_info = seed_vless_reality(cursor, cfg, xray_bin)
        conn.commit()
        log.info("Database seeded successfully.")
    except Exception as e:
        conn.rollback()
        log.error(f"DB seeding failed: {e}")
        raise
    finally:
        conn.close()

    write_credentials(cfg, admin_pass, ss_info, reality_info)

    # Print summary
    admin = cfg.get("admin", {})
    print("\n" + "=" * 62)
    print("  3X-UI DATABASE SEEDED")
    print("=" * 62)
    print(f"  Admin User  : {admin.get('username', 'admin')}")
    print(f"  Admin Pass  : {admin_pass}")
    print(f"  Admin Port  : {admin.get('port', 2053)}")
    if ss_info:
        print(f"\n  [Shadowsocks]  port={ss_info['port']}  cipher={ss_info['cipher']}")
        print(f"  Password: {ss_info['password']}")
    if reality_info:
        print(f"\n  [VLESS-Reality]  port={reality_info['port']}  sni={reality_info['sni']}")
        print(f"  UUID:       {reality_info['uuid']}")
        print(f"  PublicKey:  {reality_info['public_key']}")
        print(f"  ShortID:    {reality_info['short_id']}")
    print("=" * 62)
    print(f"  Credentials: /root/.vpn_credentials")
    print("=" * 62 + "\n")


if __name__ == "__main__":
    main()
