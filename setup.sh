#!/bin/bash

# =================================================================
# CDNCloud 系統初始化與鏡像封裝自動化腳本
# 適用版本: Rocky Linux 9 / CentOS 系列
# =================================================================

# 檢查是否為 root 執行
if [ "$EUID" -ne 0 ]; then 
  echo "請以 root 權限執行此腳本。"
  exit 1
fi

echo ">>> [1/7] 開始進行系統基礎設定 (SSH, Hostname, SELinux)..."

# SSH 設定
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Hostname 與 Hosts 設定
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# 關閉 SELinux
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

# 防火牆設定 (安裝並停用，確保鏡像預設不阻擋連線)
dnf install -y firewalld
systemctl enable --now firewalld
systemctl stop --now firewalld
systemctl disable firewalld

echo ">>> [2/7] 網路與 DNS 配置..."

# 關閉自動配置 DNS
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

# 停用預設 cloud-init (待套件安裝後再重新配置)
systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local || true

echo ">>> [3/7] 優化 DNF 鏡像源與語言包..."

# DNF 加速
echo "fastestmirror=True" >> /etc/dnf/dnf.conf

# 語系設定
dnf install -y glibc-langpack-en
localectl set-locale LANG=en_US.UTF-8
source /etc/locale.conf

echo ">>> [4/7] 安裝常用套件與工具..."

dnf -y update --exclude=kernel*
dnf -y install epel-release
dnf -y install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
               dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony
pip3 install --upgrade pip

# 啟用 acpid
systemctl enable --now acpid

echo ">>> [5/7] 配置 Cloud-init 與 QGA 自定義服務..."

# Cloud-init 深度配置
pip3 install urllib3==1.24 six
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

# 寫入 cloud.cfg 選項 (Datasource 與 網路禁用)
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

# 清理 Cloud-init 歷史紀錄
PYTHON_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
rm -rf /usr/lib/python${PYTHON_VER}/site-packages/cloudinit/sources/__init__.py[co] 2>/dev/null
rm -rf /var/lib/cloud/*
rm -rf /var/log/cloud-init*
systemctl enable --now cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service

# 建立 QGA 自動維護腳本
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    dnf -y install qemu-guest-agent >> /dev/null
    sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga
    systemctl restart qemu-guest-agent
    systemctl enable --now qemu-guest-agent
  fi
done
EOF
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

# 建立 QGA Service
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

# 建立自動擴容與掛載腳本 (per-instance)
mkdir -p /var/lib/cloud/scripts/per-instance/
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
# 判斷版本並執行硬碟擴容
source /etc/os-release
VERSION=$VERSION_ID
growpart /dev/vda 1 || true
xfs_growfs /dev/vda1 || true
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

echo ">>> [6/7] 系統內核優化與時間同步..."

# 內核參數優化
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

# 資源限制
cat <<EOF >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

# Chrony 時間同步
cat <<EOF > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
systemctl restart chronyd

echo ">>> [7/7] 清理個人資訊與日誌檔，準備封裝..."

# 押上封裝日期
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清理日誌
rm -rf /run/log/journal/*
systemctl restart systemd-journald
rm -f /root/anaconda-ks.cfg 2>/dev/null
rm -rf /var/log/anaconda /tmp/* /var/tmp/*
cat /dev/null > /etc/machine-id

# 批量清空 Log 檔案
LOG_FILES=(boot.log cloud-init.log lastlog btmp wtmp secure cloud-init-output.log cron maillog spooler kdump.log messages dnf.log dmesg)
for log in "${LOG_FILES[@]}"; do
    [ -f "/var/log/$log" ] && echo > "/var/log/$log"
done

# 清理 SSH 與 歷史紀錄
rm -rf /root/.ssh/*
rm -rf /root/.pki/*
echo "" > /etc/hostname

echo "====================================================="
echo " 腳本執行完畢！系統將在 5 秒後自動關機。"
echo " 關機後即可進行雲端鏡像 (Template/Image) 封裝作業。"
echo "====================================================="

sleep 5
echo > ~/.bash_history
history -c
init 0
