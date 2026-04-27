#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與安裝 Python
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1
log "1. 準備基礎工具..."
dnf install -y python3 policycoreutils-python-utils
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

# 2. SSH 救援、Host Key 修復與 SELinux 解除武裝
log "2. SSH 安全、Host Key 修復與解除 SELinux 阻擋..."
if [ -f /etc/selinux/config ]; then
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
fi
setenforce 0 2>/dev/null || true

ssh-keygen -A
restorecon -Rv /etc/ssh || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 3. 寫入 /etc/resolv.conf
log "3. 寫入 DNS 設定..."
cat << 'EOF' > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF

# 4. 寫入 /etc/dnf/dnf.conf
log "4. 寫入 DNF 設定..."
if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

# 5. 寫入 /etc/cloud/cloud.cfg
log "5. 寫入 Cloud-init 設定..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
cat << 'EOF' >> /etc/cloud/cloud.cfg

datasource:
  Ec2:
    max_wait: 5
  CloudStack:
    max_wait: 5
network:
  config: disabled

lock_passwd: false
EOF

# 6. 寫入 /etc/sysctl.conf
log "6. 寫入 Sysctl 設定..."
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

# 7. 寫入 /etc/security/limits.conf
log "7. 寫入 Limits 設定..."
cat << 'EOF' >> /etc/security/limits.conf

* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

# 8. 時間同步設置 (Chrony)
log "8. 設定時間同步 (Chrony)..."
dnf install chrony -y
sed -i '/^server /d' /etc/chrony.conf
sed -i '/^pool /d' /etc/chrony.conf
cat << 'EOF' >> /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
EOF
systemctl enable --now chronyd
systemctl restart chronyd

# 9. 寫入 QGA 相關腳本與服務
log "9. 建立 QGA 服務與腳本..."
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
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

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
systemctl daemon-reload
systemctl enable --now cdncloud-qga.service

# 10. 寫入 Cloud-init per-instance mount 腳本
log "10. 建立自動掛載腳本 (mount.sh)..."
mkdir -p /var/lib/cloud/scripts/per-instance/
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
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
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

# 11. 寫入 Cloud-init per-boot QGA 腳本
log "11. 建立開機 QGA 啟動腳本 (install-qga.sh)..."
mkdir -p /var/lib/cloud/scripts/per-boot/
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
chmod +x /var/lib/cloud/scripts/per-boot/install-qga.sh

# 12. 建立安全的 Change_SSH_Port.sh
log "12. 建立 /root/Change_SSH_Port.sh..."
cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port (1-65535): " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤：請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config

# 防錯：暫時將 SELinux 設為寬容，防止修改 Port 後被暗殺 (status=255)
setenforce 0 2>/dev/null || true
ssh-keygen -A
restorecon -Rv /etc/ssh || true
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /root/Change_SSH_Port.sh

# 13. 押上鏡像封裝日期
log "13. 押上鏡像封裝日期到 /etc/os-release..."
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release
log "目前標記日期為: $(grep IMAGE_CREATION_DATE /etc/os-release)"

# 14. 封裝清理階段
echo "------------------------------------------------------------"
read -p "是否執行封裝清理 (YES/NO): " CLEAN_ANS
if [[ "$CLEAN_ANS" == "YES" ]]; then
  log "執行清理流程..."
  
  rm -f /etc/ssh/ssh_host_*_key*
  
  setenforce 0 2>/dev/null || true
  ssh-keygen -A
  restorecon -Rv /etc/ssh || true
  systemctl restart sshd

  cat /dev/null > /etc/machine-id
  rm -rf /var/lib/cloud/* /var/log/cloud-init*
  rm -rf /tmp/* /var/tmp/*
  find /var/log -type f -exec cp /dev/null {} \;
  history -c
  log "清理完成，SSH 服務已自動恢復，現在可以安全封裝鏡像。"
fi

echo "------------------------------------------------------------"
log "時間同步狀態檢查："
chronyc sources || true
