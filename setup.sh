#!/bin/bash

# =================================================================
# Rocky Linux 9 / CentOS 鏡像自動化封裝腳本
# =================================================================

# 取得腳本自身的絕對路徑
SCRIPT_PATH=$(readlink -f "$0")

# 檢查是否為 root 執行
if [ "$(id -u)" -ne 0 ]; then
    echo "請以 root 權限執行此腳本。"
    exit 1
fi

echo ">>> 開始執行系統初始化與鏡像封裝流程..."

# --- 二、系統設定 ---
echo "--- 設定 SSH ---"
# 移除可能干擾的 sshd_config.d 設定並開啟 root/密碼登入
rm -f /etc/ssh/sshd_config.d/*.conf
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

echo "--- 設定 Hostname ---"
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

echo "--- 關閉 SELinux ---"
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
setenforce 0 2>/dev/null

echo "--- 設定防火牆 (預設開啟並設定後關閉) ---"
dnf install -y firewalld
systemctl enable --now firewalld
systemctl stop --now firewalld
systemctl disable firewalld

echo "--- 處理網路設定 (建立目錄與 DNS) ---"
mkdir -p /etc/sysconfig/network-scripts/
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

echo "--- 停用 cloud-init (初始設定階段) ---"
systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local

# --- 3. 優化與鏡像源設定 ---
echo "--- 優化 DNF 加速與鏡像源 (Rocky 9) ---"
echo "fastestmirror=True" >> /etc/dnf/dnf.conf
cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup

# 替換為阿里雲鏡像
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    -i /etc/yum.repos.d/rocky*.repo

dnf clean all && dnf makecache -y

echo "--- 設定語系 ---"
dnf install -y glibc-langpack-en
source /etc/locale.conf

# --- 三、安裝套件 ---
echo "--- 安裝常用工具套件 ---"
yum -y update --exclude=kernel*
yum -y install epel-release
yum -y install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
               dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony

pip3 install --upgrade pip
systemctl enable --now acpid

# --- 2. 安裝與設定 Cloud-init ---
echo "--- 設定 Cloud-init 配置 ---"
pip3 install urllib3==1.24 six
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

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

PYTHON_VAL=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
rm -rf /usr/lib/python${PYTHON_VAL}/site-packages/cloudinit/sources/__init__.pyc 2>/dev/null
rm -rf /usr/lib/python${PYTHON_VAL}/site-packages/cloudinit/sources/__init__.pyo 2>/dev/null
rm -rf /var/lib/cloud/*
rm -rf /var/log/cloud-init*
systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service

# --- 3. 安裝 QGA 維護腳本 ---
echo "--- 建立 QGA 自動維護服務 ---"
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    yum -y install qemu-guest-agent >> /dev/null
    sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga
    systemctl restart qemu-guest-agent
    systemctl enable qemu-guest-agent
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

# --- 四、系統優化 ---
echo "--- 內核參數與資源限制優化 ---"
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

# --- 五、建立自動掛載與擴容腳本 ---
echo "--- 建立 Cloud-init 自定義執行腳本 ---"
mkdir -p /var/lib/cloud/scripts/per-instance/
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
source /etc/os-release
VERSION=$VERSION_ID
# 擴容根分區範例
growpart /dev/vda 1 && xfs_growfs /dev/vda1
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

# --- 六、時間同步 ---
echo "--- 設定 Chrony 時間同步 ---"
cat <<EOF > /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl restart chronyd

# --- 七、清理與封裝 ---
echo "--- 封裝前最後清理 ---"
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

rm -rf /run/log/journal/*
systemctl restart systemd-journald
rm -f ~root/anaconda-ks.cfg
rm -rf /var/log/anaconda
rm -rf /tmp/* /var/tmp/*
cat /dev/null > /etc/machine-id

LOGS=(boot.log cloud-init.log lastlog btmp wtmp secure cloud-init-output.log cron maillog spooler kdump.log messages yum.log)
for logfile in "${LOGS[@]}"; do
    echo > /var/log/$logfile 2>/dev/null
done

# --- 八、刪除本腳本與歷史紀錄 ---
echo ">>> 刪除初始化腳本與歷史紀錄..."
rm -f "$SCRIPT_PATH"
rm -rf ~root/.ssh/*
rm -rf ~root/.pki/*
echo "" > /etc/hostname
echo > ~/.bash_history
echo > ~/.history

echo ">>> 所有流程已完成。系統即將在 5 秒後關機以供封裝..."
sleep 5
history -c && init 0
