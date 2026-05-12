#!/usr/bin/env bash
# ==============================================================================
# CDNCloud Golden Image - 終極合併版 (全優化 + 密碼直連 + QGA啟動 + 歷史核平)
# ==============================================================================
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
dnf install -y \
    python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
    telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
    cloud-utils-growpart e2fsprogs vim \
    policycoreutils-python-utils firewalld acpid git

# 3. 系統服務 (Acpid & Firewalld) 配置
log "3. 系統服務配置..."
systemctl enable --now acpid
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1
systemctl stop --now firewalld
systemctl disable firewalld

# ==============================================================================
# 4. SSH 霸王條款 (徹底壓制系統預設，保證密碼登入)
# ==============================================================================
log "4. SSH 與帳號安全 (寫入 00- 最高權重密碼解鎖)..."
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
setenforce 0 2>/dev/null || true

mkdir -p /etc/ssh/sshd_config.d/
rm -f /etc/ssh/sshd_config.d/*cloud-init* || true

cat << 'EOF' > /etc/ssh/sshd_config.d/00-cdncloud-auth.conf
PasswordAuthentication yes
PermitRootLogin yes
EOF
chmod 600 /etc/ssh/sshd_config.d/00-cdncloud-auth.conf

systemctl enable sshd
if id rocky &>/dev/null; then
    usermod -L -s /sbin/nologin rocky
fi

# ==============================================================================
# 5. 網路配置與核心命名還原
# ==============================================================================
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

if ! grep -q "net.ifnames=0" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
fi

# ==============================================================================
# 6. Cloud-init 強制壓制與 DNF 優化
# ==============================================================================
log "6. Cloud-init 優化與 DNF 優化..."
if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

dnf install -y cloud-init
mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

cat << 'EOF' > /etc/cloud/cloud.cfg.d/99-cdncloud-ssh.cfg
disable_root: false
ssh_pwauth: true
EOF

# 匯入使用者提供的 Cloud-init 參數
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

# ==============================================================================
# 7. 系統優化與資源限制
# ==============================================================================
log "7. 寫入核心與資源限制優化..."
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

cat << 'EOF' >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

# ==============================================================================
# 8. 時區與時間同步
# ==============================================================================
log "8. 設定時區與時間同步 (Chrony)..."
timedatectl set-timezone Asia/Taipei
if ! grep -q "HISTTIMEFORMAT" /etc/profile; then
    echo 'export HISTTIMEFORMAT="%F %T "' >> /etc/profile
fi

sed -i '/^server /d' /etc/chrony.conf
echo "server 120.25.115.20 iburst" >> /etc/chrony.conf
echo "server 203.107.6.88 iburst" >> /etc/chrony.conf
systemctl enable --now chronyd && systemctl restart chronyd

# ==============================================================================
# 9. 建立自修復服務與客製化工具
# ==============================================================================
log "9. 建立 SSH 自癒機制與保留改 Port 工具..."
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

cat << 'EOF' > /usr/local/bin/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤: 請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=$NEW_PORT/tcp
    firewall-cmd --reload
fi
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF

# 賦予工具與捷徑執行權限 (加入使用者要求的 chmod)
chmod +x /usr/local/bin/Change_SSH_Port.sh
ln -sf /usr/local/bin/Change_SSH_Port.sh /root/Change_SSH_Port.sh
chmod +x /root/Change_SSH_Port.sh

# ==============================================================================
# 10. 加入 CDNCloud QGA 代理與自動掛載腳本
# ==============================================================================
log "10. 配置 Qemu Guest Agent 與 Cloud-init 掛載腳本..."

# QGA 監控腳本
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
sleep 300
if ps -ef | grep qemu-ga | egrep -v grep >/dev/null
then
 echo " qemu-guest-agent is started!" > /dev/null
else
 yum -y install qemu-guest-agent >> /dev/null
 sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga
 systemctl stop qemu-guest-agent
 systemctl start qemu-guest-agent
 systemctl enable --now qemu-guest-agent
fi
done
EOF

# 賦予執行權限 (使用者要求)
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

# QGA Service
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud Qemu Guest Agent
Documentation=http://www.cdncloud.com
After=network.target
[Service]
Type=simple
ExecStart=/usr/lib/systemd/system/cdncloud-qga.sh
[Install]
WantedBy=multi-user.target
EOF

# 啟動並重載 QGA 服務 (使用者要求 --now)
systemctl daemon-reload
systemctl enable --now cdncloud-qga

# 確保 cloud-init 目錄存在
mkdir -p /var/lib/cloud/scripts/per-instance/
mkdir -p /var/lib/cloud/scripts/per-boot/

# 自動掛載腳本
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash

# Check system version
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ $ID == "centos" || $ID == "rocky" ]]; then
        VERSION=$VERSION_ID
        echo "System detected: version $VERSION"
    else
        echo "Unsupported system: $ID"
        exit 1
    fi
else
    echo "Unknown system, /etc/os-release not found."
    exit 1
fi

# Ensure necessary tools are installed
required_tools=(parted xfsprogs cloud-utils-growpart)
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Installing $tool..."
        if ! sudo yum install -y "$tool"; then
            echo "Failed to install $tool"
            exit 1
        fi
    fi
done

# Function to setup a directory with a disk
setup_directory() {
    local dir=$1
    local disk=$2

    if ! lsblk "$disk" | grep -q "$disk"; then
        if ! [ -d "$dir" ]; then
            mkdir -p "$dir"
        fi
        parted -s "$disk" mklabel gpt
        mkfs.xfs -f "$disk"
        echo "UUID=$(blkid "$disk" | grep -oP 'UUID="\K[^"]+') $dir xfs defaults 0 0" >> /etc/fstab
        mount -a
        echo "$dir has been successfully set up."
    else
        echo "$dir is already configured."
    fi
}

# Main logic
if [[ $1 == '--directory' && -n $2 ]]; then
    disk=$(lsblk -np | grep -i "disk" | awk '{print $1}' | head -n 1)
    case $2 in
        '/data') setup_directory "/data" "$disk" ;;
        '/www') setup_directory "/www" "$disk" ;;
        '/home') setup_directory "/home" "$disk" ;;
        *) echo "Invalid directory. Supported: /data, /www, /home" ;;
    esac
else
    echo "Usage: $0 --directory [path]"
    exit 1
fi

# Resize disk based on CentOS/Rocky version
if [[ $VERSION -eq 7 || $VERSION -eq 9 || $VERSION -eq 8 ]]; then
    growpart /dev/vda 1
    if mount | grep -q "/dev/vda1"; then
        xfs_growfs /dev/vda1
    else
        echo "Failed to mount /dev/vda1"
        exit 1
    fi
else
    echo "Version-specific logic not implemented for this version."
fi
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

# Install QGA 腳本
cat << 'EOF' > /var/lib/cloud/scripts/per-boot/install-qga.sh
#!/bin/bash
if ps -ef | grep qemu-ga | egrep -v grep >/dev/null
then
echo " qemu-guest-agent is started!" > /dev/null
else
yum -y install qemu-guest-agent >> /dev/null
sed -ri '/^BLACKLIST_RPC/s#^##' /etc/sysconfig/qemu-ga
systemctl enable --now qemu-guest-agent
fi
EOF

# 賦予執行權限 (使用者要求)
chmod +x /var/lib/cloud/scripts/per-boot/install-qga.sh

# ==============================================================================
# 11. 終極大掃除 (寫入鏡像時間、清理殘留)
# ==============================================================================
log "11. 執行終極大掃除..."

sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

dnf remove -y git
rm -f /etc/ssh/ssh_host_*_key*
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance /var/lib/cloud/data/* /var/log/cloud-init*
rm -rf /var/lib/cloud/sem/*
rm -rf /run/log/journal/* || true
rm -f ~root/anaconda-ks.cfg
rm -rf /var/log/anaconda /var/tmp/* /tmp/* || true
rm -rf ~/Rocky-8 ~/original-ks.cfg
rm -rf ~root/.ssh/* ~root/.pki/*

cat /dev/null > /etc/machine-id
echo > /etc/hostname

for logfile in boot.log lastlog btmp wtmp secure cron maillog spooler messages yum.log; do
    [ -f "/var/log/$logfile" ] && echo > "/var/log/$logfile"
done

log "封裝完成！系統將在 3 秒後自動斷電關機..."
sleep 3

# ==============================================================================
# 12. 歷史紀錄核平處理 (切斷電源前清空大腦)
# ==============================================================================
set +o history
export HISTSIZE=0
export HISTFILESIZE=0
rm -f /root/.bash_history /root/.history
poweroff -f
