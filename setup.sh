#!/bin/bash

# =================================================================
# CDNCloud 系統優化與鏡像封裝自動化腳本
# =================================================================

# 確保以 root 執行
if [ "$EUID" -ne 0 ]; then 
  echo "請以 root 權限執行此腳本。"
  exit 1
fi

echo ">>> [1/6] 正在進行核心參數 (sysctl) 與 資源限制 (limits) 優化..."

# 系統核心參數優化
cat <<EOF > /etc/sysctl.d/99-cdncloud-optimization.conf
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
sysctl -p /etc/sysctl.d/99-cdncloud-optimization.conf

# 資源限制優化
cat <<EOF >> /etc/security/limits.conf
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

echo ">>> [2/6] 正在建立 QGA 守護進程與服務..."

# 建立 QGA 監控腳本
cat << 'EOF' > /usr/lib/systemd/system/cdncloud-qga.sh
#!/bin/bash
while true; do
  sleep 300
  if ps -ef | grep qemu-ga | egrep -v grep >/dev/null; then
    echo "qemu-guest-agent is started!" > /dev/null
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

# 建立 QGA 系統服務
cat <<EOF > /usr/lib/systemd/system/cdncloud-qga.service
[Unit]
Description=CDNCloud Qemu Guest Agent Monitor
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

echo ">>> [3/6] 正在建立磁碟擴容與 QGA 初始化腳本 (Cloud-init)..."

# 建立每台實例啟動時執行的磁碟擴容腳本
mkdir -p /var/lib/cloud/scripts/per-instance/
cat << 'EOF' > /var/lib/cloud/scripts/per-instance/mount.sh
#!/bin/bash
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    VERSION=$VERSION_ID
fi

# 安裝必要工具
required_tools=(parted xfsprogs cloud-utils-growpart)
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        yum install -y "$tool"
    fi
done

# 根分區自動擴容 (針對 vda1)
growpart /dev/vda 1 || true
xfs_growfs /dev/vda1 || true
EOF
chmod +x /var/lib/cloud/scripts/per-instance/mount.sh

# 建立每次開機執行的 QGA 檢查
mkdir -p /var/lib/cloud/scripts/per-boot/
cat << 'EOF' > /var/lib/cloud/scripts/per-boot/install-qga.sh
#!/bin/bash
if ! ps -ef | grep qemu-ga | egrep -v grep >/dev/null; then
    yum -y install qemu-guest-agent >> /dev/null
    sed -ri '/^#\?FILTER_RPC_ARGS/s/^#\?//' /etc/sysconfig/qemu-ga
    systemctl enable --now qemu-guest-agent
fi
EOF
chmod +x /var/lib/cloud/scripts/per-boot/install-qga.sh

echo ">>> [4/6] 正在產生 SSH 端口更換工具 (Change_SSH_Port.sh)..."

cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port 號碼: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -le 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "錯誤: 請輸入有效的端口號碼 (1-65535)."
  exit 1
fi

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config

if systemctl list-unit-files | grep -q '^ssh.socket'; then
    systemctl restart ssh.socket
    systemctl enable ssh.socket
fi
systemctl restart sshd
echo "SSH Port 已更改為 $NEW_PORT。"
EOF
chmod +x /root/Change_SSH_Port.sh

echo ">>> [5/6] 正在設定時間同步 (Chrony)..."

yum install chrony -y
sed -i 's/^pool /#pool /' /etc/chrony.conf
cat <<EOF >> /etc/chrony.conf
server 120.25.115.20 iburst
server 203.107.6.88 iburst
EOF
systemctl restart chronyd
chronyc sources

echo ">>> [6/6] 正在清理系統並執行封裝前置作業..."

# 押上鏡像封裝日期
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release

# 清理日誌與快取
rm -rf /run/log/journal/*
systemctl restart systemd-journald
rm -f /root/anaconda-ks.cfg /root/original-ks.cfg 2>/dev/null
rm -rf /var/log/anaconda /tmp/* /var/tmp/* /var/lib/cloud/instances/*

# 重置 Machine ID
cat /dev/null > /etc/machine-id

# 批量清空日誌檔案內容 (不刪除檔案)
LOG_FILES=(
  "/var/log/boot.log" "/var/log/cloud-init.log" "/var/log/lastlog" 
  "/var/log/btmp" "/var/log/wtmp" "/var/log/secure" 
  "/var/log/cloud-init-output.log" "/var/log/cron" "/var/log/maillog" 
  "/var/log/spooler" "/var/log/messages" "/var/log/yum.log"
)

for file in "${LOG_FILES[@]}"; do
  [ -f "$file" ] && cat /dev/null > "$file"
done

# 清理 SSH 密鑰與歷史紀錄
rm -rf /root/.ssh/*
rm -rf /root/.pki/*
echo "" > /etc/hostname

echo "====================================================="
echo " 腳本執行完畢！系統已準備好進行封裝。"
echo " 請手動執行以下最後一組指令以完成最終清理並關機："
echo "====================================================="
echo " history -c && history -w && init 0"
