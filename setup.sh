#!/usr/bin/env bash
set -euo pipefail

################################################################################
# CDNCloud 全自動鏡像封裝腳本 (Rocky/CentOS 8/9 適用)
# 修正：移除自動關機指令，清理後保持開機狀態
################################################################################

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 確保以 root 執行
[[ "$EUID" -ne 0 ]] && echo "請使用 root 權限執行" && exit 1

# --- 調整點：先安裝基礎工具 ---
log "0. 預先安裝基礎套件 (Python 3)"
dnf install -y python3 || yum install -y python3

# 偵測 Python 版本
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

log "1. 系統與 SSH 基礎設定"
ssh-keygen -A
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
restorecon -Rv /etc/ssh || true
systemctl restart sshd

# Hostname
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# SELinux 關閉
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# Firewalld 安裝並預設關閉
dnf install -y firewalld
systemctl enable firewalld
systemctl stop --now firewalld
systemctl disable firewalld

log "2. 網路與 DNS 設定"
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager
systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local || true

log "3. 系統優化與套件安裝"
echo "fastestmirror=True" >> /etc/dnf/dnf.conf
dnf install -y glibc-langpack-en
yum -y update --exclude=kernel*
yum -y install epel-release
yum -y install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
               dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony
pip3 install --upgrade pip
systemctl enable --now acpid chronyd

log "4. Cloud-init 配置"
yum install cloud-init -y
pip3 install urllib3==1.24 six --upgrade
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

cat >> /etc/cloud/cloud.cfg << "EOF"
datasource:
  Ec2:
    max_wait: 5
  CloudStack:
    max_wait: 5
network:
  config: disabled
lock_passwd: false
EOF

rm -rf /usr/lib/python${PY_VER}/site-packages/cloudinit/sources/__init__.py[co] || true
rm -rf /var/lib/cloud/* /var/log/cloud-init*
cloud-init init --local || true
systemctl enable cloud-init-local cloud-init cloud-config cloud-final

log "5. 寫入 CDNCloud 專屬腳本 (QGA Watchdog / Mount / SSH Port)"
cat <<'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    yum -y install qemu-guest-agent >> /dev/null
    sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga || true
    systemctl restart qemu-guest-agent
    systemctl enable --now qemu-guest-agent
  fi
done
EOF

cat <<'EOF' > /usr/lib/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud Qemu Guest Agent Watchdog
After=network.target
[Service]
Type=simple
ExecStart=/usr/lib/systemd/system/cdncloud-qga.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/lib/cloud/scripts/per-instance/
cat <<'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
# (此處為您原本保留的 mount.sh 區塊)
EOF

mkdir -p /var/lib/cloud/scripts/per-boot/
cat <<'EOF' > /var/lib/cloud/scripts/per-boot/install-qga.sh
#!/bin/bash
if ! pgrep -x qemu-ga >/dev/null; then
  yum -y install qemu-guest-agent
  sed -ri '/^#\?BLACKLIST_RPC/s#^#*##' /etc/sysconfig/qemu-ga || true
  systemctl enable --now qemu-guest-agent
fi
EOF

cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi
read -p "Please enter the new SSH port number: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
  echo "Error: Please enter a valid number."
  exit 1
fi
if [ "$NEW_PORT" -le 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "Error: Please enter a number between 1 and 65535."
  exit 1
fi
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
if systemctl is-active --quiet sshd; then
  systemctl restart sshd
  echo "SSH port has been changed to $NEW_PORT."
elif systemctl is-active --quiet ssh; then
  systemctl restart ssh
  echo "SSH port has been changed to $NEW_PORT."
else
  echo "SSH service not found. Please restart manually."
fi
EOF

chmod +x /usr/lib/systemd/system/cdncloud-qga.sh
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh
chmod +x /var/lib/cloud/scripts/per-boot/install-qga.sh
chmod +x /root/Change_SSH_Port.sh
systemctl daemon-reload
systemctl enable --now cdncloud-qga

log "6. 核心參數優化 (sysctl & limits)"
cat <<EOF >> /etc/sysctl.conf
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

cat <<EOF >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

log "7. 時間同步設定"
sed -i '/^server/d' /etc/chrony.conf
echo "server 120.25.115.20 iburst" >> /etc/chrony.conf
echo "server 203.107.6.88 iburst" >> /etc/chrony.conf
systemctl restart chronyd

log "8. 鏡像日期標記與清理"
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

echo "============================================================"
echo " 系統建置完成，準備進入清理階段。"
echo "============================================================"
read -p "是否執行最終清理？(YES/NO): " CLEAN_ANS

if [[ "$CLEAN_ANS" == "YES" ]]; then
    log "執行清理中 (不關機)..."
    rm -rf /run/log/journal/*
    systemctl restart systemd-journald
    rm -f /root/anaconda-ks.cfg
    rm -rf /var/log/anaconda /tmp/* /var/tmp/*
    
    cat /dev/null > /etc/machine-id
    for logfile in boot.log cloud-init.log lastlog btmp wtmp secure \
                   cloud-init-output.log cron maillog spooler kdump.log \
                   messages dmesg dmesg.old yum.log; do
        [[ -f /var/log/$logfile ]] && echo > /var/log/$logfile
    done
    
    rm -rf /root/.ssh/* /root/.pki/*
    : > /etc/hostname
    : > /root/.bash_history
    history -c
    log "清理完成，系統保持開機狀態。"
else
    log "腳本結束，未執行清理。"
fi
