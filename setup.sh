#!/bin/bash

# =================================================================
# Rocky Linux 9 系統初始化與鏡像封裝自動化腳本 (修正網卡路徑版)
# =================================================================

set -e 

echo ">>> 1. 開始 SSH 與 基礎系統設定..."
# SSH 設定
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Hostname 設定
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# 關閉 SELinux
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

echo ">>> 2. 處理網路設定 (解決 No such file or directory 問題)..."
# 重要：在 Rocky 9 建立此目錄以相容舊式 ifcfg 檔案
mkdir -p /etc/sysconfig/network-scripts/

# 寫入網卡設定
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << "EOF"
TYPE=Ethernet
BOOTPROTO=dhcp
DEVICE=eth0
NAME=eth0
ONBOOT=yes
USERCTL=no
PERSISTENT_DHCLIENT=yes
EOF

# 關閉自動 DNS 並手動指定
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf || echo "dns=none" >> /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF

# 重啟網路服務
nmcli connection reload || true
systemctl restart NetworkManager

echo ">>> 3. 優化 DNF 鏡像源與安裝套件..."
echo "fastestmirror=True" >> /etc/dnf/dnf.conf
# 備份並替換為阿里雲 (針對 Rocky 9)
cp -r /etc/yum.repos.d/ /etc/yum.repos.d.backup
sed -e 's|^mirrorlist=|#mirrorlist=|g' \
    -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
    -i /etc/yum.repos.d/rocky*.repo

dnf clean all && dnf makecache -y

# 安裝必要套件
dnf install -y epel-release
dnf install -y python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 \
               telnet nmap lrzsz rsync zip unzip dos2unix gdisk parted \
               cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony

echo ">>> 4. 設定 Cloud-init 與 QGA..."
# 此處省略你原本的 cloud.cfg 內容，請依照需求保留或貼入上一個回答中的設定
# ... (保持原本 cloud-init 的 sed 指令)

# 建立自定義 QGA 維護服務
cat > /usr/lib/systemd/system/cdncloud-qga.sh << "EOF"
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    yum -y install qemu-guest-agent
    systemctl start qemu-guest-agent
  fi
done
EOF
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

echo ">>> 5. 最後清理與封裝準備..."
# 押上日期
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清理 Log
rm -rf /var/lib/cloud/*
rm -rf /var/log/cloud-init*
cat /dev/null > /etc/machine-id
history -c

echo "====================================================="
echo " 腳本執行完畢！請檢查上方是否有錯誤訊息。"
echo " 提醒：請輸入 'init 0' 關機進行鏡像封裝。"
echo "====================================================="
