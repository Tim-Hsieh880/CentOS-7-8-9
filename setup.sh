#!/usr/bin/env bash
set -euo pipefail

# 彩色輸出
log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\n\033[1;33m[!] $*\033[0m"; }

# 1. 檢查權限與預裝基礎工具
[[ "$EUID" -ne 0 ]] && echo "請使用 root 執行" && exit 1
log "安裝基礎工具 Python3 & Policycoreutils..."
dnf install -y python3 policycoreutils-python-utils

# 偵測 Python 版本
PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

# 2. SSH 救援邏輯 (一開始就確保金鑰存在)
log "SSH 安全與救援初始化..."
ssh-keygen -A
restorecon -Rv /etc/ssh || true
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 3. 系統優化參數
log "寫入核心優化參數與限制..."
cat <<EOF > /etc/sysctl.d/99-cdncloud.conf
vm.swappiness = 0
kernel.sysrq = 1
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 1024
EOF
sysctl --system

cat <<EOF > /etc/security/limits.d/99-cdncloud.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
EOF

# 4. QGA Watchdog 服務
log "建立 QGA Watchdog 服務..."
mkdir -p /usr/local/sbin
cat <<'EOF' > /usr/local/sbin/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ! pgrep -x qemu-ga >/dev/null; then
    dnf install -y qemu-guest-agent >> /dev/null 2>&1
    systemctl enable --now qemu-guest-agent
  fi
done
EOF
chmod +x /usr/local/sbin/cdncloud-qga.sh

cat <<'EOF' > /etc/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud QGA Watchdog
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/cdncloud-qga.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cdncloud-qga.service

# 5. 網路與 DNS 
log "配置網路環境..."
rm -f /etc/NetworkManager/conf.d/99-dns-none.conf || true
if ! grep -q "8.8.8.8" /etc/resolv.conf; then
  echo "nameserver 8.8.8.8" >> /etc/resolv.conf
fi
systemctl restart NetworkManager

# 6. Cloud-init 配置
log "配置 Cloud-init (標準模式)..."
dnf install -y cloud-init
sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg
sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg
rm -f /etc/cloud/cloud.cfg.d/99-cdncloud-lock.cfg || true
systemctl enable cloud-init-local cloud-init cloud-config cloud-final

# 7. 產生 SSH Port 更換腳本
log "建立 /root/Change_SSH_Port.sh..."
cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port (1-65535): " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then echo "錯誤：請輸入數字"; exit 1; fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
# 額外檢查金鑰是否存在，防止重啟失敗
ssh-keygen -A
restorecon -Rv /etc/ssh || true
systemctl restart sshd && echo "SSH Port 已更改為 $NEW_PORT"
EOF
chmod +x /root/Change_SSH_Port.sh

# 8. 封裝前清理 (優化 SSH 處理)
echo "------------------------------------------------------------"
read -p "是否執行封裝清理 (YES/NO): " CLEAN_ANS
if [[ "$CLEAN_ANS" == "YES" ]]; then
  log "執行清理流程..."
  
  # 1. 刪除舊金鑰
  rm -f /etc/ssh/ssh_host_*_key*
  
  # 2. 重要：立即重新生成臨時金鑰，保證當下 SSH 不會斷掉或啟動失敗
  ssh-keygen -A
  restorecon -Rv /etc/ssh || true
  systemctl restart sshd
  
  # 3. 其他清理動作
  cat /dev/null > /etc/machine-id
  rm -rf /var/lib/cloud/* /var/log/cloud-init*
  rm -rf /tmp/* /var/tmp/*
  find /var/log -type f -exec cp /dev/null {} \;
  
  history -c
  log "清理完成！SSH 已自動恢復，現在你可以安全地繼續操作或進行封裝。"
fi
