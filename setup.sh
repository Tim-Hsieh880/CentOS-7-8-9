#!/usr/bin/env bash
set -euo pipefail

################################################################################
# CDNCloud 全自動鏡像封裝腳本 (Rocky/CentOS 8/9 優化版)
################################################################################

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }

# 確保以 root 執行
[[ "$EUID" -ne 0 ]] && echo "請使用 root 權限執行" && exit 1

# 0. 基礎環境準備 (預裝 Python 3 與常用工具)
log "0. 預先安裝基礎套件 (Python 3 & Policycoreutils)"
dnf install -y python3 policycoreutils-python-utils

# 偵測 Python 版本用於後續清理
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

log "1. SSH 安全與救援設定"
# 補齊金鑰並修復 SELinux 標籤，防止重啟後無法啟動
ssh-keygen -A
restorecon -Rv /etc/ssh || true

# 備份設定檔
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak_$(date +%Y%m%d)

# 修正密碼驗證與 Root 登入 (強化 sed 匹配)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

systemctl restart sshd

log "2. 系統基礎優化 (Hostname / SELinux / Firewall)"
# Hostname
hostnamectl set-hostname localhost.domain.com
sed -i '/^127.0.0.1/s/$/ localhost.domain.com/' /etc/hosts
sed -i '/^::1/s/$/ localhost.domain.com/' /etc/hosts

# 關閉 SELinux (重啟生效)
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# 關閉防火牆 (鏡像模板通常預設關閉)
dnf install -y firewalld
systemctl disable --now firewalld || true

log "3. 網路與 DNS 鎖定"
# 防止 NetworkManager 覆蓋 DNS
if [ ! -d /etc/NetworkManager/conf.d ]; then mkdir -p /etc/NetworkManager/conf.d; fi
cat <<EOF > /etc/NetworkManager/conf.d/99-dns-none.conf
[main]
dns=none
EOF

cat <<EOF > /etc/resolv.conf
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 114.114.114.114
EOF
systemctl restart NetworkManager

log "4. 安裝 QGA 與雲端工具"
dnf install -y epel-release
dnf install -y qemu-guest-agent acpid chrony wget net-tools psmisc vim
systemctl enable --now qemu-guest-agent acpid chronyd

log "5. Cloud-init 深度配置 (防止重啟跑掉)"
dnf install -y cloud-init
# 確保 cloud-init 不會覆蓋密碼登入
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg

# 寫入鎖定網路的配置
cat <<EOF > /etc/cloud/cloud.cfg.d/99-custom-config.cfg
datasource:
  Ec2: { max_wait: 5 }
  CloudStack: { max_wait: 5 }
network:
  config: disabled
lock_passwd: false
EOF

# 清理 cloud-init 舊快取
rm -rf /var/lib/cloud/* /var/log/cloud-init*
# 對於 Rocky 8，我們維持 disable cloud-init 直到有需要再開
systemctl disable --now cloud-init cloud-config cloud-final cloud-init-local || true

log "6. 寫入 SSH Port 更換腳本 (/root/Change_SSH_Port.sh)"
cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤：請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd
echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /root/Change_SSH_Port.sh

log "7. 核心參數優化"
cat <<EOF > /etc/sysctl.d/99-cdncloud.conf
vm.swappiness = 0
kernel.sysrq = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl --system

log "8. 封裝前的清理流程"
echo "------------------------------------------------------------"
read -p "是否執行最終清理？(這將刪除金鑰與日誌，但不關機) [YES/NO]: " CLEAN_ANS

if [[ "$CLEAN_ANS" == "YES" ]]; then
    log "開始清理..."
    
    # 刪除主機唯一的金鑰 (開新機時會自動產生新的，這才安全)
    rm -f /etc/ssh/ssh_host_*_key*
    
    # 清理機器識別與日誌
    cat /dev/null > /etc/machine-id
    rm -rf /tmp/* /var/tmp/*
    rm -f /root/.bash_history
    
    # 清理所有日誌檔案
    find /var/log -type f -exec cp /dev/null {} \;
    
    history -c
    log "清理完成！現在你可以重啟機器測試，或直接封裝鏡像。"
else
    log "已跳過清理。"
fi
