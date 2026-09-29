#!/usr/bin/env bash
# =============================================================================
# core/bbr_tune.sh — Kernel & Network Stack Performance Tuner
#
# Standalone tuner called by step2.sh or run independently.
# Applies: TCP BBR, file descriptor limits, socket buffers, swap (optional).
# Compatible: Ubuntu 20.04 / 22.04 / 24.04, Debian 11 / 12
# =============================================================================
set -euo pipefail

LOG_FILE="/var/log/vpn_step2.log"

log()  { echo "[BBR_TUNE] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
warn() { echo "[BBR_TUNE][WARN] $*" | tee -a "$LOG_FILE"; }

[[ $EUID -ne 0 ]] && { echo "Run as root (sudo)."; exit 1; }

log "Starting kernel & network tuning..."

# ── 1. TCP BBR Congestion Control ─────────────────────────────────────────────
log "Enabling TCP BBR..."
KERNEL_VER=$(uname -r | awk -F'.' '{print $1*100+$2}')
if [[ $KERNEL_VER -lt 409 ]]; then
    warn "Kernel $(uname -r) may not support BBR. Skipping BBR config."
else
    sed -i '/net.core.default_qdisc/d'        /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf << 'EOF'

# VPN BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    log "BBR settings written."
fi

# ── 2. File Descriptor & Socket Limits ────────────────────────────────────────
log "Raising file descriptor limits..."
sed -i '/# VPN-tuning/,/# End VPN-tuning/d' /etc/security/limits.conf
cat >> /etc/security/limits.conf << 'EOF'
# VPN-tuning
*    soft nofile 1000000
*    hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
# End VPN-tuning
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/vpn-limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1000000
DefaultLimitNPROC=65535
EOF

# ── 3. Socket & Network Buffer Tuning ─────────────────────────────────────────
log "Tuning socket buffers..."
for key in fs.file-max net.core.rmem_max net.core.wmem_max \
           net.ipv4.tcp_fastopen net.ipv4.tcp_keepalive_time \
           net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes; do
    sed -i "/^${key}/d" /etc/sysctl.conf
done

cat >> /etc/sysctl.conf << 'EOF'

# VPN Socket Tuning
fs.file-max=1000000
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=250000
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
EOF

# ── 4. Apply ───────────────────────────────────────────────────────────────────
log "Applying sysctl settings..."
sysctl -p /etc/sysctl.conf 2>/dev/null || warn "Some sysctl params may require reboot."
systemctl daemon-reload

log "Kernel & network tuning complete."
