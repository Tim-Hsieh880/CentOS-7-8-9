#!/usr/bin/env bash
set -euo pipefail

############################################
# CDNCloud Image Build - Rocky/CentOS/RHEL
# 整合 SSH 金鑰修復與密碼登入強化邏輯
############################################

### ===== 可調參數 =====
HOSTNAME_FQDN="${HOSTNAME_FQDN:-localhost.domain.com}"
ENABLE_ROOT_PASSWORD_LOGIN="${ENABLE_ROOT_PASSWORD_LOGIN:-yes}"
ENABLE_SSH_PASSWORD_LOGIN="${ENABLE_SSH_PASSWORD_LOGIN:-yes}"
DISABLE_SELINUX="${DISABLE_SELINUX:-yes}"
INSTALL_FIREWALLD="${INSTALL_FIREWALLD:-yes}"
DISABLE_FIREWALLD="${DISABLE_FIREWALLD:-yes}"
DNS_MODE="${DNS_MODE:-nm}"
DNS_SERVERS=("8.8.8.8" "1.1.1.1" "114.114.114.114")
NM_CONN_NAME="${NM_CONN_NAME:-auto}"
INSTALL_CLOUD_INIT="${INSTALL_CLOUD_INIT:-yes}"
DISABLE_CLOUD_INIT_NETWORK="${DISABLE_CLOUD_INIT_NETWORK:-yes}"
INSTALL_QGA="${INSTALL_QGA:-yes}"
CHRONY_SERVERS=("120.25.115.20" "203.107.6.88")

### ===== 工具偵測 =====
log(){ echo -e "\n[+] $*"; }
warn(){ echo -e "\n[!] $*" >&2; }

PKG_MGR=""
if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"; else echo "No dnf/yum found." >&2; exit 1; fi

pkg_install(){ $PKG_MGR -y install "$@"; }
ensure_line(){ local line="$1" file="$2"; grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"; }

############################################
# 1) SSH 設定 (整合救援與金鑰產生邏輯)
############################################
log "Configure SSH: Repairing Keys & Enabling Password Login"

# A. 產生所有遺失的預設主機金鑰 (解決 no hostkeys available 報錯)
log "Checking/Generating SSH Host Keys..."
ssh-keygen -A

# B. 確認金鑰檔案是否已產生 (列出供日誌檢查)
ls -l /etc/ssh/ssh_host_*

# C. 修改設定檔：密碼驗證與 Root 登入
if [[ -f /etc/ssh/sshd_config ]]; then
  # 備份原始設定
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d)"
  
  if [[ "$ENABLE_ROOT_PASSWORD_LOGIN" == "yes" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  fi
  
  if [[ "$ENABLE_SSH_PASSWORD_LOGIN" == "yes" ]]; then
    # 強制將 no 改為 yes，並處理被註解的情況
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  fi
fi

# D. 恢復 SELinux 標籤 (避免 Rocky/CentOS 讀不到新產生的金鑰)
if command -v restorecon >/dev/null 2>&1; then
  log "Restoring SELinux contexts for /etc/ssh..."
  restorecon -Rv /etc/ssh
fi

# E. 檢查設定檔語法
log "Validating sshd_config syntax..."
sshd -t

# F. 重啟服務並確認狀態
log "Restarting SSH service..."
if systemctl list-unit-files | grep -q '^sshd\.service'; then
  systemctl enable --now sshd
  systemctl restart sshd
  systemctl status sshd --no-pager
else
  warn "SSHD service not found."
fi

############################################
# 2) Hostname 設定
############################################
log "Set hostname: $HOSTNAME_FQDN"
hostnamectl set-hostname "$HOSTNAME_FQDN" || true

# (中間 3-13 步驟保持不變，包含 SELinux 關閉、網路、套件安裝、Cloud-init、QGA、Sysctl 等)
# ... [此處省略您提供的原有建置邏輯] ...

############################################
# 14) 產生 Change_SSH_Port.sh (略，同原版)
############################################

############################################
# 15) 封裝清理邏輯
############################################
cleanup_and_poweroff(){
  log "Final Cleanup before image capture..."
  
  # 注意：在封裝模板時，通常會清掉 Host Keys 讓新機器開機時自動產生
  # 但如果你希望保留這次產生的 Key，請註解下面這行
  rm -f /etc/ssh/ssh_host_*_key* 2>/dev/null || true

  # 清理其餘日誌與歷史紀錄
  rm -rf /var/lib/cloud/* 2>/dev/null || true
  : > /etc/machine-id
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
  : > /root/.bash_history 2>/dev/null || true
  history -c 2>/dev/null || true
  
  log "Powering off..."
  poweroff
}

# 執行詢問...
read -r -p "Build finished. Cleanup + poweroff? (YES/Enter): " ans
[[ "$ans" == "YES" ]] && cleanup_and_poweroff || log "Exit without cleanup."
