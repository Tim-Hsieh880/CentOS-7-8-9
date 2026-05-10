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
dnf repolist

# 2. 系統更新與安裝基礎工具
log "2. 系統更新與準備基礎工具..."
dnf -y update --exclude=kernel*
dnf install -y epel-release
dnf install -y \
    python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
    telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
    cloud-utils-growpart e2fsprogs vim \
    policycoreutils-python-utils firewalld acpid git

pip3 install --upgrade pip

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
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
fi
setenforce 0 2>/dev/null || true

ssh-keygen -A
restorecon -Rv /etc/ssh || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

if id rocky &>/dev/null; then
    usermod -L -s /sbin/nologin rocky
    log "帳號 rocky 已成功禁用 (密碼鎖定且 Shell 已關閉)"
fi

# 5. 網路配置 (指定 DNS 並配合 PEERDNS=no)
log "5. 統一網卡命名為 eth0 與網路配置 (指定 8.8.8.8)..."
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

mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

if ! grep -q "net.ifnames=0" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
fi

# 6. 配置 DNF 優化
log "6. 配置 DNF 優化..."
if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

# 7. Cloud-init 設定
log "7. 寫入 Cloud-init 設定與 SSH 金鑰策略..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
if ! grep -q "\- ssh$" /etc/cloud/cloud.cfg; then
  sed -i '/cloud_init_modules:/a \ - ssh' /etc/cloud/cloud.cfg
fi
cat << 'EOF' >> /etc/cloud/cloud.cfg
datasource:
  Ec2: { max_wait: 5 }
  CloudStack: { max_wait: 5 }
lock_passwd: false
ssh_genkeytypes: ['rsa', 'ecdsa', 'ed25519']
EOF

# 8. 系統優化
log "8. 寫入核心與資源限制優化..."
cat << 'EOF' >> /etc/sysctl.conf
vm.swappiness = 0
kernel.sysrq = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
EOF
sysctl -p
cat << 'EOF' >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
EOF

# 9. 時間同步
log "9. 設定時間同步 (Chrony)..."
sed -i '/^server /d' /etc/chrony.conf
echo "server 120.25.115.20 iburst" >> /etc/chrony.conf
systemctl enable --now chronyd

# 10. 建立自修復服務與客製化工具
log "10. 建立 SSH 自癒機制與保留工具..."
# SSH 金鑰自癒服務：保證開機沒金鑰時自動補齊，防 22 Port 斷線
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-ssh-keygen.service
[Unit]
Description=CDNCloud SSH Keygen Fail-Safe
Before=sshd.service
ConditionPathExists=!/etc/ssh/ssh_host_rsa_key
[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=-/usr/sbin/restorecon -Rv /etc/ssh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable cdncloud-ssh-keygen.service

# 保留改 Port 工具在本體 /usr/local/bin/ 並建立快捷方式
cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$NEW_PORT/tcp
    firewall-cmd --reload
fi
ssh-keygen -A
restorecon -Rv /etc/ssh || true
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh

# 11. 終極大掃除與自動關機
log "11. 執行終極大掃除並自動關機..."
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清理金鑰、日誌與 Cloud-init
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance /var/lib/cloud/data/* /var/log/cloud-init*
rm -rf /var/lib/cloud/sem/*
rm -rf /run/log/journal/* || true
rm -f ~root/anaconda-ks.cfg
rm -rf /var/log/anaconda /var/tmp/* /tmp/* || true

cat /dev/null > /etc/machine-id
echo > /etc/hostname

for logfile in boot.log lastlog btmp wtmp secure cron maillog spooler messages yum.log; do
    [ -f "/var/log/$logfile" ] && echo > "/var/log/$logfile"
done

# 清理指定的殘留與移除 Git
log "清理 ~/Rocky-8, ~/original-ks.cfg 並移除 Git..."
rm -rf ~/Rocky-8 ~/original-ks.cfg
dnf remove -y git

# 清理 Root 紀錄 (防呆檢查)
rm -rf ~root/.ssh/*
rm -rf ~root/.pki/*
[ -f ~root/.bash_history ] && echo > ~root/.bash_history
[ -f ~root/.history ] && echo > ~root/.history
history -c

log "封裝完成！Change_SSH_Port.sh 已保留。系統將在 3 秒後自動關機..."
sleep 3
poweroff
