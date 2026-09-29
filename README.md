# 3X-UI VPN Automation — v2.0

> **Two-step, JSON-driven, fully automated** anti-censorship VPN node.
> Deploy on any empty Linux VPS in < 3 minutes.

---

## 🚀 Quick Start (3 Steps)

### Step 1 — Install Prerequisites (Fresh VPS)
```bash
sudo bash step1.sh
```
Installs: Python 3, git, GitHub CLI (gh), Google Cloud CLI (gcloud),
UFW, sqlite3, qrencode, whiptail, bcrypt, cryptography, openpyxl.
Also handles optional gcloud and gh authentication interactively.

---

### Step 2 — Configure (Fill the Excel, Generate JSON)

**Option A — Excel (Recommended for non-technical users):**
```bash
# On Windows/Linux with Python:
python prepare/generate_excel.py   # Already done — requirements.xlsx exists

# Fill in Column D in prepare/requirements.xlsx
# Then convert to JSON:
python prepare/excel_to_json.py
```

**Option B — Edit JSON directly:**
```bash
nano config/config.json    # Edit values directly
```

---

### Step 3 — Deploy VPN
```bash
sudo bash step2.sh
```
Done. Admin URL, credentials, and connection keys are printed at the end.

---

## 📁 File Structure

```
automation_build_vpn_on_current_host/
│
├── step1.sh                  ← FIRST: Install tools & auth setup
├── step2.sh                  ← THEN: Main installer (reads config.json)
│
├── config/
│   └── config.json           ← Master config (all settings here)
│
├── prepare/                  ← Fill this to generate config.json
│   ├── requirements.xlsx     ← Excel template (open & fill Column D)
│   ├── generate_excel.py     ← Regenerate the Excel template
│   └── excel_to_json.py      ← Convert filled Excel → config.json
│
├── core/
│   ├── bbr_tune.sh           ← Kernel/BBR/socket tuning
│   ├── db_seeder.py          ← SQLite injector (reads config.json)
│   └── gcp_firewall.sh       ← Firewall sync (GCP/UFW/iptables)
│
├── manager/
│   ├── menu.sh               ← Interactive TUI (8-option menu)
│   └── key_generator.py      ← ss:// + vless:// + QR codes
│
└── deploy_gcp.sh             ← Optional: GCP cloud orchestrator
```

---

## ⚙️ Configuration — `config/config.json`

All settings are driven by this JSON file. Key sections:

| Section | Key fields |
|---------|-----------|
| `node` | `name`, `timezone` |
| `admin` | `port` (2053), `username`, `password` ⚠ change this! |
| `shadowsocks` | `enabled`, `port` (25762), `cipher`, `password` |
| `vless_reality` | `enabled`, `port` (443), `sni`, `fingerprint` |
| `system` | `swap_size_gb`, `enable_bbr`, `fd_limit` |
| `install` | `install_3xui`, `show_qr` |
| `firewall` | `backend` (auto/gcp/ufw/iptables), `ssh_port` |
| `gcp` | `enabled`, `project`, `region` |
| `clients` | Array of users with quotas and expiry |
| `notifications` | Telegram bot for startup alerts |

---

## 🔑 Excel Workflow (prepare/)

```
  requirements.xlsx         ← 4 sheets:
  ├── ⚙ Config              ← Fill Column D with your values
  ├── 👥 Clients            ← Add users (name, email, quota, expiry)
  ├── 📖 How To Use         ← Step-by-step guide
  └── 🔑 Cipher Reference   ← Cipher + SNI comparison table

  ↓ python prepare/excel_to_json.py

  config/config.json        ← Ready for step2.sh
```

---

## 🔒 Default Ports

| Port | Protocol | Service |
|------|----------|---------|
| `22` | TCP | SSH (always kept open) |
| `443` | TCP | VLESS-Reality |
| `2053` | TCP | 3X-UI Admin Dashboard |
| `25762` | TCP+UDP | Shadowsocks / Outline |

---

## 🖥️ Management TUI

```bash
sudo bash manager/menu.sh
```

Options: View keys, change SS port, add users, check bandwidth, rotate IP, open dashboard.

---

## 🔧 step2.sh Flags

```bash
sudo bash step2.sh                          # Full install
sudo bash step2.sh --config /path/cfg.json  # Custom config path
sudo bash step2.sh --skip-3xui             # Skip 3X-UI install
sudo bash step2.sh --no-swap               # Skip swap
sudo bash step2.sh --no-bbr               # Skip BBR tuning
sudo bash step2.sh --no-firewall           # Skip firewall
sudo bash step2.sh --keys-only             # Regenerate keys only
sudo bash step2.sh --dry-run               # Preview config, no changes
```

---

## 🔄 90-Day GCP Rotation

```bash
# On new GCP Cloud Shell:
bash deploy_gcp.sh --project NEW_PROJECT_ID

# Or on fresh Ubuntu VPS:
sudo bash step1.sh && sudo bash step2.sh
```
