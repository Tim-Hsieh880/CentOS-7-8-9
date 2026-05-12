#!/usr/bin/env bash
# ==============================================================================
# CDNCloud Golden Image - 最終完美封裝版
# 核心目標：新機開機自動生成金鑰、自動開啟 22 Port、徹底抹除歷史紀錄
# ==============================================================================
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與環境
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置官方軟體源與系統更新..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi
dnf clean all && dnf makecache
dnf -y update --exclude=kernel*

# 2. 安裝必要工具
log "2. 安裝基礎工具 (含 Git)..."
dnf install -y epel-release
dnf install -y python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim firewalld acpid git

# 3. 系統服務基礎設定
log "3. 服務配置 (預設關閉防火牆以確保連線)..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# 4. SSH 與帳號安全 (鎖定 rocky 帳號)
log "4. 安全優化..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
id rocky &>/dev/null && usermod -L -s /sbin/nologin rocky

# 5. 網路配置 (指定 DNS 優先且防止被 DHCP 篡改)
log "5. 網路優化 (DNS 8.8.8.8 優先)..."
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

# 6. 時區、Cloud-init 與 DNF 優化
log "6. 系統環境優化 (時區: 台北)..."
dnf install -y cloud-init
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
timedatectl set-timezone Asia/Taipei
echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile

# 7. 時間同步配置
log "7. Chrony 強制同步配置..."
cat << 'EOF' > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable --now chronyd && systemctl restart chronyd

# 8. 核心自癒服務 (關鍵！確保新機開機 22 Port 一定會開)
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

# 9. 改 Port 工具保留
log "9. 安裝 Change_SSH_Port.sh 工具..."
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤: 請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd && echo "SSH Port 已成功更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

# 10. 移除 Git 並清理殘留目錄與設定檔
log "10. 移除 Git 工具與安裝殘留 (含 anaconda-ks)..."
dnf remove -y git
rm -rf /root/Rocky-8 /root/original-ks.cfg /root/anaconda-ks.cfg

# 11. 終極大掃除 (日誌、主機金鑰、機器ID)
log "11. 抹除主機指紋與所有日誌..."
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/log/cloud-init*
[ -f /etc/machine-id ] && truncate -s 0 /etc/machine-id
[ -f /etc/hostname ] && truncate -s 0 /etc/hostname
find /var/log -type f -exec truncate -s 0 {} +

log "封裝完成！所有痕跡已抹除。系統將在 3 秒後自動強制斷電..."
log "請注意：開機後 22 Port 會由自癒服務自動啟動，請直接封裝此關機狀態！"
sleep 3

# ==========================================================
# 終極歷史紀錄抹除：關閉錄影、清空緩存、徹底刪除檔案、強制斷電
# ==========================================================
set +o history
export HISTSIZE=0
export HISTFILESIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
