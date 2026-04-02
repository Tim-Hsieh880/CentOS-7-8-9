#!/bin/bash

# =================================================================
# Rocky Linux 9 系統初始化與鏡像封裝自動化腳本
# =================================================================

set -e # 遇到錯誤立即停止執行

echo "開始進行系統設定..."

# 1. SSH 設定
echo ">>> 設定 SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 2. Hostname 與 Network 設定
echo ">>> 設定 Hostname 與 網路..."
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# 關閉 SELinux
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

# 設定網卡 eth0 模板
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << "EOF"
TYPE=Ethernet
BOOTPROTO=dhcp
DEVICE=eth0
NAME=eth0
ONBOOT=yes
USERCTL=no
PERSISTENT_DHCLIENT=yes
EOF

# 關閉自動配置 DNS 並手動指定
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

# 3. 優化 DNF 鏡像源 (使用 阿里雲)
echo ">>> 優化 DNF 鏡像源..."
echo "fastestmirror=True" >> /etc/dnf/dnf.conf

cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    -i /etc/yum.repos.d/rocky*.repo

dnf clean all
dnf makecache -y

# 4. 安裝常用套件
echo ">>> 安裝基礎套件..."
dnf install -y epel-release
dnf install -y python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony

pip3 install --upgrade pip
systemctl enable --now acpid
systemctl enable --now qemu-guest-agent

# 5. Cloud-init 設定
echo ">>> 設定 Cloud-init..."
pip3 install urllib3==1.24 six
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

# 禁用 cloud-init 網路管理並設定 datasource
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

# 清理舊狀態
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
rm -rf /usr/lib/python${PY_VER}/site-packages/cloudinit/sources/__init__.py[co]
rm -rf /var/lib/cloud/*
rm -rf /var/log/cloud-init*

systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service

# 6. 系統核心與資源限制優化
echo ">>> 進行系統核心優化..."
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

# 7. 建立自定義服務與腳本
echo ">>> 建立自定義管理腳本..."

# QGA 維護腳本
cat > /usr/lib/systemd/system/cdncloud-qga.sh << "EOF"
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    yum -y install qemu-guest-agent
    sed -i '/^# FILTER_RPC_ARGS/s/^# //' /etc/sysconfig/qemu-ga
    systemctl restart qemu-guest-agent
  fi
done
EOF
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

# QGA Service
cat > /usr/lib/systemd/system/cdncloud-qga.service << "EOF"
[Unit]
Description=CDNCloud Qemu Guest Agent Maintenance
After=network.target

[Service]
Type=simple
ExecStart=/usr/lib/systemd/system/cdncloud-qga.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable cdncloud-qga

# 自動擴容與掛載腳本 (Per-instance)
mkdir -p /var/lib/cloud/scripts/per-instance/
cat > /var/lib/cloud/scripts/per-instance/mount.sh << "EOF"
#!/bin/bash
# 自動擴容根分區
growpart /dev/vda 1 || true
xfs_growfs /dev/vda1 || true
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

# 8. 時間同步
echo ">>> 設定時間同步 (Chrony)..."
cat > /etc/chrony.conf << "EOF"
server 120.25.115.20 iburst
server 203.107.6.88 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl restart chronyd

# 9. 封裝前清理作業
echo ">>> 開始最後清理..."
# 押上日期
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清除日誌與暫存
rm -rf /run/log/journal/*
systemctl restart systemd-journald
rm -f ~root/anaconda-ks.cfg
rm -rf /var/log/anaconda
rm -rf /tmp/*
rm -rf /var/tmp/*
cat /dev/null > /etc/machine-id

LOG_FILES=("/var/log/boot.log" "/var/log/cloud-init.log" "/var/log/lastlog" "/var/log/btmp" "/var/log/wtmp" "/var/log/secure" "/var/log/cron" "/var/log/messages" "/var/log/yum.log")
for log in "${LOG_FILES[@]}"; do
    [ -f "$log" ] && echo > "$log"
done

# 清理個人隱私與指令歷史
rm -rf ~root/.ssh/*
rm -rf ~root/.pki/*
echo > /etc/hostname
history -c

echo "====================================================="
echo " 系統初始化完成！"
echo " 提示：請手動執行 'init 0' 關機以進行鏡像製作。"
echo "====================================================="
