#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# 1. 確保權限與配置官方軟體源
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1

log "1. 配置系統軟體源 (恢復官方源，捨棄無效的清華源)..."
if [ -d "/etc/yum.repos.d.backup" ]; then
    \cp -rf /etc/yum.repos.d.backup/* /etc/yum.repos.d/
else
    cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
fi

log "清理並重建軟體源快取..."
dnf clean all && dnf makecache
dnf repolist

# 2. 系統更新與安裝基礎工具
log "2. 系統更新與準備基礎工具 (EPEL, 網管套件, Firewalld, Acpid)..."

log "執行系統更新 (排除 kernel)..."
dnf -y update --exclude=kernel*

dnf install -y epel-release

dnf install -y \
    python3 python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
    telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
    cloud-utils-growpart e2fsprogs vim \
    policycoreutils-python-utils firewalld acpid

pip3 install --upgrade pip

PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

# 3. 系統核心守護進程 (Acpid & Firewalld) 狀態檢查與配置
log "3. 系統服務 (Acpid & Firewalld) 配置..."

systemctl enable --now acpid
log "檢查 Acpid 運行狀態："
systemctl status acpid --no-pager || true

systemctl enable --now firewalld
log "檢查 Firewalld 運行狀態："
systemctl status firewalld --no-pager || true

firewall-cmd --permanent --add-service=ssh > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

systemctl stop --now firewalld
systemctl disable firewalld
log "Firewalld 已設為預設關閉 (封裝就緒狀態)。"

# 4. SSH 救援、Host Key 修復與基礎帳號安全
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

# 5. 統一網卡設定為 eth0 與鎖定網路配置
log "5. 統一網卡命名為 eth0 與網路配置..."
rm -f /etc/sysconfig/network-scripts/ifcfg-ens* || true
cat << 'EOF' > /etc/sysconfig/network-scripts/ifcfg-eth0
TYPE=Ethernet
BOOTPROTO=dhcp
DEVICE=eth0
ONBOOT=yes
USERCTL=no
EOF

mkdir -p /etc/cloud/cloud.cfg.d/
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

if ! grep -q "net.ifnames=0" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 /' /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg || true
fi

# 6. 配置 DNS 與 DNF 優化
log "6. 配置 DNS 與 DNF..."
cat << 'EOF' > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF

if ! grep -q "fastestmirror=True" /etc/dnf/dnf.conf; then
  echo "fastestmirror=True" >> /etc/dnf/dnf.conf
fi

# 7. 寫入 Cloud-init 設定
log "7. 寫入 Cloud-init 設定..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
cat << 'EOF' >> /etc/cloud/cloud.cfg

datasource:
  Ec2: { max_wait: 5 }
  CloudStack: { max_wait: 5 }
lock_passwd: false
EOF

# 8. 系統核心與資源限制優化
log "8. 寫入 Sysctl、Limits 與環境變數設定..."
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

echo 'export HISTTIMEFORMAT="%F %T "' > /etc/profile.d/history_time.sh
source /etc/profile.d/history_time.sh || true
log "指令歷史紀錄 (History) 已加入時間戳記"

# 9. 時間同步 (Chrony)
log "9. 設定時間同步 (Chrony)..."
sed -i '/^server /d' /etc/chrony.conf
cat << 'EOF' >> /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
EOF
systemctl enable --now chronyd
systemctl restart chronyd

# 10. 建立客製化腳本 (QGA / Mount / SSH Port)
log "10. 建立 QGA Watchdog 與客製化腳本..."
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

MOUNT_SH="/var/lib/cloud/scripts/per-instance/mount.sh"
mkdir -p "$(dirname "$MOUNT_SH")"
cat << 'EOF' > "$MOUNT_SH"
#!/bin/bash

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ $ID == "centos" ]] || [[ $ID == "rocky" ]]; then
        VERSION=$VERSION_ID
        echo "OS detected: version $VERSION"
    else
        echo "Unsupported system: $ID"
        exit 1
    fi
else
    echo "Unknown system, /etc/os-release not found."
    exit 1
fi

required_tools=(parted xfsprogs cloud-utils-growpart)
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        if ! sudo dnf install -y "$tool"; then
            exit 1
        fi
    fi
done

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
    fi
}

if [[ ${1:-} == '--directory' && -n ${2:-} ]]; then
    disk=$(lsblk -np | grep -i "disk" | awk '{print $1}' | head -n 1)
    case $2 in
        '/data') setup_directory "/data" "$disk" ;;
        '/www') setup_directory "/www" "$disk" ;;
        '/home') setup_directory "/home" "$disk" ;;
        *) echo "Invalid directory." ;;
    esac
else
    echo "Usage: $0 --directory [path]"
    exit 1
fi

if [[ $VERSION == 7* || $VERSION == 8* || $VERSION == 9* ]]; then
    growpart /dev/vda 1 || true
    if mount | grep -q "/dev/vda1"; then
        xfs_growfs /dev/vda1 || true
    fi
fi
EOF
chmod +x "$MOUNT_SH"

QGA_BOOT_SH="/var/lib/cloud/scripts/per-boot/install-qga.sh"
mkdir -p "$(dirname "$QGA_BOOT_SH")"
cat << 'EOF' > "$QGA_BOOT_SH"
#!/bin/bash
if ps -ef | grep qemu-ga | egrep -v grep >/dev/null
then
echo " qemu-guest-agent is started!" > /dev/null
else
dnf -y install qemu-guest-agent >> /dev/null
sed -ri '/^BLACKLIST_RPC/s#^##' /etc/sysconfig/qemu-ga
systemctl enable --now qemu-guest-agent
fi
EOF
chmod +x "$QGA_BOOT_SH"

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

# 11. 封裝日期與終極大掃除
log "11. 押上日期與執行終極大掃除..."
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

echo "------------------------------------------------------------"
read -p "是否執行封裝前終極大掃除並自動關機？ (YES/NO): " CLEAN_ANS
if [[ "$CLEAN_ANS" == "YES" ]]; then
  log "開始執行終極潔癖大掃除..."
  
  # 1. 清理 SSH 金鑰，確保新機器重新生成
  rm -f /etc/ssh/ssh_host_*_key*
  
  # 2. 清理 Cloud-init 基礎實例與 Python 快取 (保留腳本)
  rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance /var/lib/cloud/data/* /var/log/cloud-init*
  find /usr/lib/python3.*/site-packages/cloudinit/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

  # 3. 清理系統日誌與 Journal
  rm -rf /run/log/journal/* || true
  systemctl restart systemd-journald || true

  # 4. 清理安裝紀錄與暫存檔
  rm -f ~root/anaconda-ks.cfg
  rm -rf /var/log/anaconda
  rm -rf /tmp/*
  rm -rf /var/tmp/*
  
  # 5. 清空系統識別碼與 hostname (開機後會自動產生新的)
  cat /dev/null > /etc/machine-id
  echo > /etc/hostname

  # 6. 清空各類日誌檔案
  echo > /var/log/boot.log
  echo > /var/log/cloud-init.log
  echo > /var/log/lastlog
  echo > /var/log/btmp
  echo > /var/log/wtmp
  echo > /var/log/secure
  echo > /var/log/cloud-init-output.log
  echo > /var/log/cron
  echo > /var/log/maillog
  echo > /var/log/spooler
  echo > /var/log/kdump.log
  echo > /var/log/multi-queue-hw.log
  echo > /var/log/dmesg
  echo > /var/log/dmesg.old
  echo > /var/log/yum.log
  echo > /var/log/messages

  # 7. 清理 Root 使用者紀錄與金鑰
  rm -rf ~root/.ssh/*
  rm -rf ~root/.pki/*
  echo > ~/.bash_history
  echo > ~/.history
  
  log "所有紀錄已清空，系統即將關機。請在關機後於母機後台建立鏡像！"
  
  # 8. 清空當前指令紀錄並安全關機
  history -c
  poweroff
else
  log "已跳過清理步驟。腳本執行完畢。"
fi
