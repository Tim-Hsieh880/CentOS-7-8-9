#!/usr/bin/env bash
set -euo pipefail

################################################################################
# CDNCloud 全自動鏡像封裝腳本 (Rocky/CentOS 8/9 適用)
# 修正：預先安裝 Python 3 以確保版本偵測正常執行
################################################################################

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 確保以 root 執行
[[ "$EUID" -ne 0 ]] && echo "請使用 root 權限執行" && exit 1

# --- 調整點：先安裝基礎工具 ---
log "0. 預先安裝基礎套件 (Python 3)"
# 確保系統有 Python 3 才能執行後續的版本偵測
dnf install -y python3 || yum install -y python3

# 現在偵測 Python 版本就不會報錯了
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

log "1. 系統與 SSH 基礎設定"
# SSH 救援邏輯與密碼登入
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
# 停用 NM 自動配置 DNS
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

# 停用原本的 cloud-init
systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local || true

log "3. 系統優化與套件安裝"
# 加速鏡像源
echo "fastestmirror=True" >> /etc/dnf/dnf.conf

# 系統更新與常用工具 (Python 3 已在步驟 0 安裝，此處補齊其餘工具)
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

# 修正 cloud.cfg
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

# 寫入自定義 cloud-init 設定
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

# 清理舊狀態
rm -rf /usr/lib/python${PY_VER}/site-packages/cloudinit/sources/__init__.py[co] || true
rm -rf /var/lib/cloud/* /var/log/cloud-init*
cloud-init init --local || true
systemctl enable cloud-init-local cloud-init cloud-config cloud-final

log "5. 寫入 CDNCloud 專屬腳本 (QGA Watchdog / Mount / SSH Port)"
# QGA Watchdog 腳本
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

# QGA Service
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

# 自動掛載與擴容腳本 (Per-instance)
mkdir -p /var/lib/cloud/scripts/per-instance/
cat <<'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
# (此處請填入您完整的 mount.sh 邏輯)
EOF

# 啟動時自動檢查 QGA
mkdir -p /var/lib/cloud/scripts/per-boot/
cat <<'EOF' > /var/lib/cloud/scripts/per-boot/install-qga.sh
#!/bin/bash
if ! pgrep -x qemu-ga >/dev/null; then
  yum -y install qemu-guest-agent
  sed -ri '/^#\?BLACKLIST_RPC/s#^#*##' /etc/sysconfig/qemu-ga || true
  systemctl enable --now qemu-guest-agent
fi
EOF

# SSH Port 更換腳本
cat <<'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
# (此處保留原本 Change_SSH_Port.sh 內容)
EOF

# 賦予所有腳本權限
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
read -p "是否執行最終清理並關機？(YES/NO): " CLEAN_ANS

if [[ "$CLEAN_ANS" == "YES" ]]; then
    log "執行最後清理..."
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
    log "封裝完成，系統即將關機。"
    init 0
else
    log "腳本結束，未執行清理。"
fi
