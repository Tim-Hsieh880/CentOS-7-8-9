#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與安裝 Python
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1
log "1. 準備基礎工具..."
dnf install -y python3 policycoreutils-python-utils
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

# 2. SSH 救援、Host Key 修復與 SELinux 解除武裝
log "2. SSH 安全、Host Key 修復與解除 SELinux 阻擋..."
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
fi
setenforce 0 2>/dev/null || true

ssh-keygen -A
restorecon -Rv /etc/ssh || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 3. 寫入 /etc/resolv.conf
log "3. 寫入 DNS 設定..."
cat << 'EOF' > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF

# 4. 寫入 /etc/dnf/dnf.conf
log "4. 寫入 DNF 設定..."
if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

# 5. 寫入 /etc/cloud/cloud.cfg
log "5. 寫入 Cloud-init 設定..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
cat << 'EOF' >> /etc/cloud/cloud.cfg

datasource:
  Ec2:
    max_wait: 5
  CloudStack:
    max_wait: 5
network:
  config: disabled

lock_passwd: false
EOF

# 6. 寫入 /etc/sysctl.conf
log "6. 寫入 Sysctl 設定..."
cat << 'EOF' >> /etc/sysctl.conf

vm.swappiness = 0
kernel.sysrq = 1
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 1024
EOF
sysctl -p

# 7. 寫入 /etc/security/limits.conf
log "7.
