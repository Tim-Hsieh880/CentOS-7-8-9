#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與配置官方軟體源
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置系統軟體源 (恢復官方源)..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi

log "清理並重建軟體源快取..."
dnf clean all && dnf makecache

# 2. 系統更新與安裝基礎工具
log "2. 系統更新與準備基礎工具..."
dnf -y update --exclude=kernel*
dnf install -y epel-release
dnf install -y python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim firewalld acpid git

# 3. 系統服務配置
log "3. 系統服務 (Acpid & Firewalld) 配置..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# 4. SSH 安全與基礎帳號防護
log "4. SSH 安全與基礎帳號防護..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true
ssh-keygen -A
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd
id rocky &>/dev/null && usermod -L -s /sbin/nologin rocky

# 5. 網路配置 (指定 DNS 優先且防止被 DHCP 篡改)
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

# 6. 配置 Cloud-init、時區與 DNF
log "6. 配置 Cloud-init 與系統優化..."
dnf install -y cloud-init
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
timedatectl set-timezone Asia/Taipei
if ! grep -q "HISTTIMEFORMAT" /etc/profile; then
    echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile
fi

# 7. 時間同步
log "7. 設定時間同步 (Chrony 修正)..."
cat << 'EOF' > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl enable --now chronyd && systemctl restart chronyd

# 8. 建立 SSH 自癒服務 (確保新機器開機自動產生金鑰並開啟 22 Port)
log "8. 建立 SSH 自癒 Fail-Safe 服務..."
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-ssh-keygen.service
[Unit]
Description=CDNCloud SSH Keygen Fail-Safe
Before=sshd.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=/usr/bin/systemctl restart sshd
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cdncloud-ssh-keygen.service

# 9. 工具保留
log "9. 安裝並保留 Change_SSH_Port.sh 工具..."
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

# 10. 移除 Git 並清理殘留
log "10. 移除 Git 並清理安裝殘留檔案..."
dnf remove -y git
rm -rf /root/Rocky-8 /root/original-ks.cfg /root/anaconda-ks.cfg

# 11. 終極大掃除
log "11. 執行終極大掃除 (抹除痕跡)..."
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/log/cloud-init*
# 修正報錯點：改用 truncate 確保不噴錯
[ -f /etc/machine-id ] && truncate -s 0 /etc/machine-id
[ -f /etc/hostname ] && truncate -s 0 /etc/hostname
find /var/log -type f -exec truncate -s 0 {} +

log "封裝完成！所有痕跡 (包含 1-5 筆歷史紀錄) 已抹除。系統將在 3 秒後自動關機..."
sleep 3

# ==========================================================
# 終極歷史紀錄抹除：關閉錄影、清空緩存、刪除檔案、強制斷電
# ==========================================================
set +o history
export HISTSIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
