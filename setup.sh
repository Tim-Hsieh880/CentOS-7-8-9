#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與配置清華大學軟體源 (TUNA)
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置系統軟體源 (替換為清華大學鏡像)..."
# 備份原有的 repo 設定
cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup

# 修改 Rocky 8 鏡像源配置為清華大學 (TUNA)，捨棄阿里雲
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.tuna.tsinghua.edu.cn/rocky|g' \
    -i.bak \
    /etc/yum.repos.d/Rocky-*.repo

# 清理並重新建立 DNF 與 YUM 快取
log "清理並重建軟體源快取..."
dnf clean all && dnf makecache
dnf repolist
yum clean all && yum makecache
yum repolist

# 2. 系統更新與安裝基礎工具
log "2. 系統更新與準備基礎工具 (EPEL, 網管套件, Firewalld, Acpid)..."

# 執行系統更新，但排除內核升級，確保雲端映像檔穩定性
log "執行系統更新 (排除 kernel)..."
dnf -y update --exclude=kernel*

# 安裝 EPEL 擴充套件庫
dnf install -y epel-release

# 安裝指定的所有網管、開發、磁碟工具，以及腳本必備元件
dnf install -y \
    python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
    telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
    cloud-utils-growpart e2fsprogs vim \
    policycoreutils-python-utils firewalld acpid

# 升級 pip
pip3 install --upgrade pip

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

# 3. 系統核心守護進程 (Acpid & Firewalld) 狀態檢查與配置
log "3. 系統服務 (Acpid & Firewalld) 配置..."

# Acpid 配置
systemctl enable --now acpid
log "檢查 Acpid 運行狀態："
systemctl status acpid --no-pager || true

# Firewalld 配置
systemctl enable --now firewalld
log "檢查 Firewalld 運行狀態："
systemctl status firewalld --no-pager || true

# 確保預設允許 SSH 服務，防止未來客戶開啟防火牆後被鎖定
firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# 為鏡像封裝準備：暫時關閉並停用防火牆，由客戶自行決定何時開啟
systemctl stop --now firewalld
systemctl disable firewalld
log "Firewalld 已設為預設關閉 (封裝就緒狀態)。"

# 4. SSH 救援、Host Key 修復與 SELinux 解除武裝
log "4. SSH 安全與救援初始化..."
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
fi
setenforce 0 2>/dev/null || true

ssh-keygen -A
restorecon -Rv /etc/ssh || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 5. 網路、DNS 與 DNF 優化
log "5. 配置 DNS 與 DNF..."
cat << 'EOF' > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF

if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

# 6. 寫入 Cloud-init 設定
log "6. 寫入 Cloud-init 設定..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
cat << 'EOF' >> /etc/cloud/cloud.cfg

datasource:
  Ec2: { max_wait: 5 }
  CloudStack: { max_wait: 5 }
network:
  config: disabled
lock_passwd: false
EOF

# 7. 系統核心與資源限制優化
log "7. 寫入 Sysctl 與 Limits 設定..."
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

# 8. 時間同步 (Chrony)
log "8. 設定時間同步 (Chrony)..."
dnf install chrony -y
sed -i '/^server /d' /etc/chrony.conf
cat << 'EOF' >> /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
EOF
systemctl enable --now chronyd
systemctl restart chronyd

# 9. 建立客製化腳本 (QGA / Mount / SSH Port)
log "9. 建立 QGA Watchdog 與客製化腳本..."
# QGA Watchdog
QGA_SH="/usr/lib/systemd/system/cdncloud-qga.sh"
cat << 'EOF' > "$QGA_SH"
#!/bin/bash
while true; do
  sleep 300
  if ! pgrep -x qemu-ga >/dev/null; then
    dnf install -y qemu-guest-agent >> /dev/null 2>&1
    systemctl restart qemu-guest-agent
    systemctl enable --now qemu-guest-agent
  fi
done
EOF
chmod +x "$QGA_SH"

QGA_SVC="/usr/lib/systemd/system/cdncloud-qga.service"
cat << 'EOF' > "$QGA_SVC"
[Unit]
Description=CDNCloud QGA Watchdog
After=network.target
[Service]
Type=simple
ExecStart=/usr/lib/systemd/system/cdncloud-qga.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cdncloud-qga.service

# Cloud-init Scripts
MOUNT_SH="/var/lib/cloud/scripts/per-instance/mount.sh"
mkdir -p "$(dirname "$MOUNT_SH")"
cat << 'EOF' > "$MOUNT_SH"
#!/bin/bash

# Check system version
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ $ID == "centos" ]]; then
        VERSION=$VERSION_ID
        echo "CentOS detected: version $VERSION"
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

# Resize disk based on CentOS version
if [[ $VERSION -eq 7 || $VERSION -eq 9 ]]; then
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
chmod +x "$MOUNT_SH"

# 10. 寫入 Cloud-init per-boot QGA 腳本
QGA_BOOT_SH="/var/lib/cloud/scripts/per-boot/install-qga.sh"
mkdir -p "$(dirname "$QGA_BOOT_SH")"
cat << 'EOF' > "$QGA_BOOT_SH"
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
chmod +x "$QGA_BOOT_SH"

# SSH Port Change Script (加上 Firewall 自動開放規則)
cat << 'EOF' > /root/Change_SSH_Port.sh
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
chmod +x /root/Change_SSH_Port.sh

# 11. 封裝日期與清理
log "11. 押上日期與執行最終清理..."
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

echo "------------------------------------------------------------"
read -p "是否執行封裝清理 (YES/NO): " CLEAN_ANS
if [[ "$CLEAN_ANS" == "YES" ]]; then
  rm -f /etc/ssh/ssh_host_*_key*
  setenforce 0 2>/dev/null || true
  ssh-keygen -A
  restorecon -Rv /etc/ssh || true
  systemctl restart sshd

  cat /dev/null > /etc/machine-id
  
  # 基礎實例清理 (保留 scripts)
  rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance /var/lib/cloud/data/* /var/log/cloud-init*
  rm -rf /tmp/* /var/tmp/*
  
  # 安全深層清理：只刪除 Cloud-init 產生的 Python 編譯快取檔，不傷原始碼
  find /usr/lib/python3.*/site-packages/cloudinit/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

  find /var/log -type f -exec cp /dev/null {} \;
  history -c
  log "清理完成，鏡像封裝就緒！"
fi
