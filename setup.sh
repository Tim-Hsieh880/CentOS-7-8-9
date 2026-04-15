#!/bin/bash

# =================================================================
# Rocky Linux 9 終極鏡像封裝自動化腳本
# =================================================================

set -e  # 遇到錯誤立即停止

# 取得腳本自身的絕對路徑
SCRIPT_PATH=$(readlink -f "$0")
CURRENT_DIR=$(dirname "$SCRIPT_PATH")

# 檢查是否為 root
if [ "$EUID" -ne 0 ]; then 
  echo "請以 root 權限執行此腳本。"
  exit 1
fi

echo ">>> [1/7] 設定基礎環境 (SSH, Hostname, SELinux, Network)..."

# SSH 設定：移除衝突設定並開啟密碼登入
rm -f /etc/ssh/sshd_config.d/*.conf
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

# 網路與 DNS 設定
mkdir -p /etc/sysconfig/network-scripts/
sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf || echo "dns=none" >> /etc/NetworkManager/NetworkManager.conf
cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

echo ">>> [2/7] 優化鏡像源與語言包..."

# DNF 優化
echo "fastestmirror=True" >> /etc/dnf/dnf.conf

# 判斷 repo 檔案是否存在再執行 sed
if ls /etc/yum.repos.d/rocky*.repo 1> /dev/null 2>&1; then
    sed -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
        -i /etc/yum.repos.d/rocky*.repo
fi

dnf clean all && dnf makecache -y

# 語系設定
dnf install -y glibc-langpack-en
localectl set-locale LANG=en_US.UTF-8
source /etc/locale.conf

echo ">>> [3/7] 安裝常用套件與工具..."

dnf -y update --exclude=kernel*
dnf -y install epel-release
dnf -y install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
               dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim acpid qemu-guest-agent chrony
pip3 install --upgrade pip
systemctl enable --now acpid

echo ">>> [4/7] 建立 SSH 端口更換工具並存放到 /root ..."

# 直接在 /root 下產生工具，確保不會被後續的目錄清理刪除
cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
# CDNCloud SSH Port 更換工具
read -p "請輸入新的 SSH Port 號碼: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -le 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "錯誤: 請輸入有效號碼 (1-65535)."
  exit 1
fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd
echo "SSH Port 已更改為 $NEW_PORT，請記得在防火牆放行該端口。"
EOF
chmod +x /root/Change_SSH_Port.sh

echo ">>> [5/7] 設定 Cloud-init 與 QGA 維護服務..."

# Cloud-init 基礎設定
pip3 install urllib3==1.24 six
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

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

# QGA 維護服務
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! ps -ef | grep qemu-ga | grep -v grep >/dev/null; then
    dnf -y install qemu-guest-agent >> /dev/null
    systemctl restart qemu-guest-agent
    systemctl enable --now qemu-guest-agent
  fi
done
EOF
chmod +x /usr/lib/systemd/system/cdncloud-qga.sh

cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud Qemu Guest Agent
