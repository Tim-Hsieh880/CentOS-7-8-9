#!/bin/bash

# =================================================================
# Rocky Linux 9 / CentOS 鏡像封裝自動化腳本
# =================================================================

set -e  # 遇到錯誤立即停止

# 檢查是否為 root
if [ "$EUID" -ne 0 ]; then 
  echo "請以 root 權限執行此腳本。"
  exit 1
fi

echo ">>> [1/7] 正在設定系統基礎環境 (SSH, Hostname, SELinux)..."

# SSH 設定
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Hostname 設定
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# SELinux 關閉
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

# 防火牆設定 (安裝並停用)
dnf install -y firewalld
systemctl enable --now firewalld
systemctl stop --now firewalld
systemctl disable firewalld

# DNS 設定
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

echo ">>> [2/7] 正在優化鏡像源與語言包..."

# DNF 優化
echo "fastestmirror=True" >> /etc/dnf/dnf.conf
cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup 2>/dev/null || true

# Rocky 9 鏡像源切換 (使用阿里雲)
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    -i /etc/yum.repos.d/rocky*.repo

dnf clean all && dnf makecache -y

# 語系設定
dnf install -y glibc-langpack-en
localectl set-locale LANG=en_US.UTF-8
source /etc/locale.conf

echo ">>> [3/7] 正在安裝常用套件與工具..."

yum -y update --exclude=kernel*
yum -y install epel-release
yum -y install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
               dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony
pip3 install --upgrade pip

systemctl enable --now acpid

echo ">>> [4/7] 正在設定 Cloud-init 與 Qemu Guest Agent..."

# Cloud-init 設定
pip3 install urllib3==1.24 six
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

# 寫入 Cloud-init network 選項
if ! grep -q "network:" /etc/cloud/cloud.cfg; then
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
fi

# 清理 Cloud-init 狀態
rm -rf /var/lib/cloud/*
rm -rf /var/log/cloud-init*
systemctl enable --now cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service

# QGA 維護腳本建立
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    yum -y install qemu-guest-agent >> /dev/null
    sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga
    systemctl restart qemu-guest-agent
    systemctl enable --now qemu-guest-agent
  fi
done
EOF
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud Qemu Guest Agent Monitor
After=network.target
[Service]
Type=simple
ExecStart=/usr/lib/systemd/system/cdncloud-qga.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now cdncloud-qga.service

# 自動擴容腳本建立
mkdir -p /var/lib/cloud/scripts/per-instance/
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
growpart /dev/vda 1 || true
xfs_growfs /dev/vda1 || true
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

echo ">>> [5/7] 正在執行系統核心優化與資源限制..."

cat <<EOF >> /etc/sysctl.conf
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

cat <<EOF >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

echo ">>> [6/7] 正在進行時間同步 (Chrony)..."

cat <<EOF > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl restart chronyd

echo ">>> [7/7] 正在清理日誌、紀錄並準備封裝..."

# 押上封裝日期
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清理作業
rm -rf /run/log/journal/*
systemctl restart systemd-journald
rm -f /root/anaconda-ks.cfg /root/original-ks.cfg 2>/dev/null
rm -rf /var/log/anaconda /tmp/* /var/tmp/*
cat /dev/null > /etc/machine-id

# 批量清理日誌檔
LOG_FILES=(boot.log cloud-init.log lastlog btmp wtmp secure cloud-init-output.log cron maillog spooler kdump.log messages yum.log dmesg)
for log in "${LOG_FILES[@]}"; do
    if [ -f "/var/log/$log" ]; then
        echo > "/var/log/$log"
    fi
done

# 清理個人紀錄
rm -rf /root/.ssh/*
rm -rf /root/.pki/*
echo "" > /etc/hostname

echo "====================================================="
echo " 腳本執行完畢！系統將在 3 秒後自動關機。"
echo " 關機後即可進行雲端鏡像 (Snapshot/Image) 封裝。"
echo "====================================================="

sleep 3
echo > ~/.bash_history
history -c
init 0
