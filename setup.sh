#!/usr/bin/env bash
# ==============================================================================
# CDNCloud Golden Image - 最終完美封裝腳本 (修復 22 Port 與 紀錄抹除)
# ==============================================================================
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置官方軟體源與系統更新..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi
dnf clean all && dnf makecache
dnf -y update --exclude=kernel*

# 2. 安裝基礎工具 (含 Git 用於下載，最後會刪除)
log "2. 安裝基礎工具..."
dnf install -y epel-release
dnf install -y python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim firewalld acpid git

# 3. 系統服務配置
log "3. 服務與防火牆優化 (確保連線暢通)..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# 4. SSH 與帳號安全
log "4. SSH 與帳號優化 (禁用 rocky 帳號)..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable sshd
id rocky &>/dev/null && usermod -L -s /sbin/nologin rocky

# 5. 網路配置 (DNS 優先權 8.8.8.8)
log "5. 網路配置 (防止 DHCP 篡改 DNS)..."
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

# 6. 時區與 Cloud-init
log "6. 時區校正與歷史紀錄格式..."
dnf install -y cloud-init
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
timedatectl set-timezone Asia/Taipei
echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile

# 7. 時間同步
log "7. Chrony 修正..."
cat << 'EOF' > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable --now chronyd && systemctl restart chronyd

# 8. 建立 SSH 自癒服務 (這是新機開機 22 Port 復活的關鍵)
log "8. 建立 SSH 自癒強啟服務..."
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-ssh-keygen.service
[Unit]
Description=CDNCloud SSH Keygen and Auto-Start
Before=sshd.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=/usr/bin/systemctl restart sshd
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cdncloud-ssh-keygen.service

# 9. 保留 Change_SSH_Port.sh 工具
log "9. 保留客製化工具..."
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤: 請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

# 10. 移除 Git 與清理殘留目錄
log "10. 移除 Git 與清理 anaconda 等殘留檔案..."
dnf remove -y git
rm -rf /root/Rocky-8 /root/original-ks.cfg /root/anaconda-ks.cfg

# 11. 終極大掃除
log "11. 執行終極大掃除 (抹除所有痕跡)..."
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/log/cloud-init*
[ -f /etc/machine-id ] && truncate -s 0 /etc/machine-id
[ -f /etc/hostname ] && truncate -s 0 /etc/hostname
find /var/log -type f -exec truncate -s 0 {} +

log "封裝準備完成！系統將在 3 秒後自動『強制斷電』..."
sleep 3

# ==========================================================
# 終極紀錄抹除邏輯：像沒開過機一樣乾淨
# ==========================================================
set +o history
export HISTSIZE=0
export HISTFILESIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
