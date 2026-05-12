#!/usr/bin/env bash
# ==============================================================================
# CDNCloud Golden Image - 終極密碼直連版
# 功能：自動金鑰生成(防死鎖)、強制允許密碼登入、歷史紀錄徹底核平
# ==============================================================================
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置軟體源與系統更新..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi
dnf clean all && dnf makecache
dnf -y update --exclude=kernel*

log "2. 安裝必要工具 (含 Git)..."
dnf install -y epel-release
dnf install -y python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim firewalld acpid git

log "3. 服務與防火牆基礎配置..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# ==============================================================================
# 修改處：第 4 步 (加入霸王條款，強制開啟密碼與 Root 登入)
# ==============================================================================
log "4. SSH 與帳號安全優化 (強制啟用密碼直連)..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true

# 建立最高優先級的 SSH 設定檔，防止被 Cloud-init 覆蓋
mkdir -p /etc/ssh/sshd_config.d/
cat << 'EOF' > /etc/ssh/sshd_config.d/99-cdncloud-auth.conf
PasswordAuthentication yes
PermitRootLogin yes
EOF
chmod 600 /etc/ssh/sshd_config.d/99-cdncloud-auth.conf

systemctl enable sshd
id rocky &>/dev/null && usermod -L -s /sbin/nologin rocky

log "5. 網路配置 (DNS 8.8.8.8 優先權)..."
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

log "6. 時區與指令歷史時間格式..."
dnf install -y cloud-init
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
timedatectl set-timezone Asia/Taipei
if ! grep -q "HISTTIMEFORMAT" /etc/profile; then
    echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile
fi

log "7. Chrony 時間同步修正..."
cat << 'EOF' > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable --now chronyd && systemctl restart chronyd

log "8. 建立 SSH 自癒強啟服務 (無死鎖版)..."
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-ssh-keygen.service
[Unit]
Description=CDNCloud SSH Keygen
Before=sshd.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
RequiredBy=sshd.service
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cdncloud-ssh-keygen.service

log "9. 保留 Change_SSH_Port.sh 工具..."
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤: 請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd && echo "SSH Port 已成功更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

log "10. 移除 Git 並清理殘留 (含 anaconda-ks)..."
dnf remove -y git
rm -rf /root/Rocky-8 /root/original-ks.cfg /root/anaconda-ks.cfg

log "11. 終極大掃除 (核平所有痕跡)..."
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/log/cloud-init*
[ -f /etc/machine-id ] && truncate -s 0 /etc/machine-id
[ -f /etc/hostname ] && truncate -s 0 /etc/hostname
find /var/log -type f -exec truncate -s 0 {} +

log "封裝完成！系統將在 3 秒後自動『強制斷電』..."
sleep 3

# --- 歷史紀錄核平處理 ---
set +o history
export HISTSIZE=0
export HISTFILESIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
