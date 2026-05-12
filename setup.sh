#!/usr/bin/env bash
# ==============================================================================
# CDNCloud Golden Image Optimization & Cleanup Script
# 功能：DNS優化、SSH自癒、時區校正、帳號鎖定、工具保留、痕跡全抹除、自動關機
# ==============================================================================
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 權限檢查
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置系統軟體源..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi

log "清理並重建軟體源快取..."
dnf clean all && dnf makecache

# 2. 安裝基礎工具
log "2. 系統更新與安裝基礎工具 (含 Git)..."
dnf -y update --exclude=kernel*
dnf install -y epel-release
dnf install -y python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim firewalld acpid git

# 3. 服務配置
log "3. 系統服務基礎配置..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# 4. SSH 與帳號安全
log "4. SSH 安全優化與鎖定預設帳號..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true
ssh-keygen -A
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd
id rocky &>/dev/null && usermod -L -s /sbin/nologin rocky

# 5. 網路配置 (指定 DNS 優先並防止被 DHCP 篡改)
log "5. 統一網卡 eth0 並設定優先 DNS (8.8.8.8)..."
rm -f /etc/sysconfig/network-scripts/ifcfg-ens* || true
cat << 'EOF' > /etc/sysconfig/network-scripts/ifcfg-eth0
TYPE=Ethernet
BOOTPROTO=dhcp
DEVICE=eth0
ONBOOT=yes
USERCTL=no
PEERDNS=no
DNS1=8.8.8.8
DNS2=1.1.1.1
DNS3=114.114.114.114
EOF

# 6. Cloud-init 與系統優化
log "6. 配置 Cloud-init 與核心優化..."
dnf install -y cloud-init
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
timedatectl set-timezone Asia/Taipei
echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile

# 7. 時間同步
log "7. 配置 Chrony 強制同步..."
cat << 'EOF' > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable --now chronyd && systemctl restart chronyd

# 8. 建立 SSH 自癒服務
log "8. 建立 SSH 金鑰自癒 Fail-Safe 服務..."
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-ssh-keygen.service
[Unit]
Description=CDNCloud SSH Keygen Fail-Safe
Before=sshd.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable cdncloud-ssh-keygen.service

# 9. 保留 Change_SSH_Port 工具
log "9. 安裝並保留 Change_SSH_Port.sh 工具..."
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

# 10. 移除 Git 並清理殘留 (包含 anaconda-ks.cfg)
log "10. 移除 Git 並清理安裝殘留檔案..."
dnf remove -y git
rm -rf /root/Rocky-8 /root/original-ks.cfg /root/anaconda-ks.cfg

# 11. 終極大掃除 (日誌、快取、主機指紋)
log "11. 抹除系統所有日誌與主機指紋..."
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/log/cloud-init*
truncate -s 0 /etc/machine-id /etc/hostname
find /var/log -type f -exec truncate -s 0 {} +

log "封裝完成！所有痕跡 (包含歷史紀錄) 已抹除。系統將在 3 秒後自動斷電..."
sleep 3

# ==========================================================
# 終極歷史紀錄抹除：關閉錄影、清空緩存、刪除檔案、強制斷電
# ==========================================================
set +o history
export HISTSIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
