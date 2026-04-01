#!/usr/bin/env bash
set -euo pipefail

############################################
# CDNCloud Image Build - Rocky/CentOS/RHEL
# - SSH: root+password login enable
# - Hostname set
# - SELinux disable (config)
# - firewalld install (optionally disable)
# - NetworkManager: DHCP + DNS policy
# - dnf/yum mirror speed tweak
# - Common packages + acpid
# - cloud-init install/config (optional)
# - qemu-guest-agent install + watchdog service
# - sysctl + limits
# - chrony time sync
# - stamp image creation date
# - optional cleanup + poweroff
############################################

### ===== 可調參數（你要做模板時改這裡）=====
HOSTNAME_FQDN="${HOSTNAME_FQDN:-localhost.domain.com}"

ENABLE_ROOT_PASSWORD_LOGIN="${ENABLE_ROOT_PASSWORD_LOGIN:-yes}"   # yes/no
ENABLE_SSH_PASSWORD_LOGIN="${ENABLE_SSH_PASSWORD_LOGIN:-yes}"     # yes/no

DISABLE_SELINUX="${DISABLE_SELINUX:-yes}"                         # yes/no
INSTALL_FIREWALLD="${INSTALL_FIREWALLD:-yes}"                     # yes/no
DISABLE_FIREWALLD="${DISABLE_FIREWALLD:-yes}"                     # yes/no

# DNS 策略：
# - mode=nm : 用 NetworkManager 設定 ignore-auto-dns + 自訂 DNS（較推薦）
# - mode=none : 設定 dns=none 並手寫 /etc/resolv.conf（你原始寫法，可能被覆蓋）
DNS_MODE="${DNS_MODE:-nm}"   # nm / none / skip
DNS_SERVERS=(
  "${DNS1:-8.8.8.8}"
  "${DNS2:-1.1.1.1}"
  "${DNS3:-114.114.114.114}"
)

# DHCP 連線名：若你知道固定叫 eth0 就填 eth0；不知道就留 auto
NM_CONN_NAME="${NM_CONN_NAME:-auto}"  # auto / eth0 / ens3 ...etc

# cloud-init / QGA
INSTALL_CLOUD_INIT="${INSTALL_CLOUD_INIT:-yes}"   # yes/no
DISABLE_CLOUD_INIT_NETWORK="${DISABLE_CLOUD_INIT_NETWORK:-yes}" # yes/no (network: config disabled)
INSTALL_QGA="${INSTALL_QGA:-yes}"                 # yes/no

# chrony servers
CHRONY_SERVERS=(
  "${CHRONY1:-120.25.115.20}"
  "${CHRONY2:-203.107.6.88}"
)

### ===== 工具/環境偵測 =====
log(){ echo -e "\n[+] $*"; }
warn(){ echo -e "\n[!] $*" >&2; }

PKG_MGR=""
if command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  echo "No dnf/yum found." >&2
  exit 1
fi

pkg_install(){
  # shellcheck disable=SC2086
  $PKG_MGR -y install "$@"
}

pkg_update_no_kernel(){
  if [[ "$PKG_MGR" == "dnf" ]]; then
    dnf -y update --exclude=kernel* || true
  else
    yum -y update --exclude=kernel* || true
  fi
}

ensure_line(){
  local line="$1" file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

service_restart_ssh(){
  # RHEL系多半是 sshd
  if systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl enable --now sshd || true
    systemctl restart sshd || true
  elif systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl enable --now ssh || true
    systemctl restart ssh || true
  else
    warn "SSH service not found (sshd/ssh)."
  fi
}

pick_nm_connection(){
  # 回傳一個最可能的連線名
  local picked=""
  if ! command -v nmcli >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  if [[ "$NM_CONN_NAME" != "auto" ]]; then
    if nmcli -t -f NAME con show | grep -qx "$NM_CONN_NAME"; then
      echo "$NM_CONN_NAME"
      return 0
    else
      warn "NM_CONN_NAME=$NM_CONN_NAME not found, will auto-pick."
    fi
  fi

  # 優先選有 DEVICE 的 ethernet 連線
  picked="$(nmcli -t -f NAME,TYPE,DEVICE con show | awk -F: '$2=="ethernet" && $3!="" {print $1; exit}')"
  if [[ -n "$picked" ]]; then
    echo "$picked"
    return 0
  fi

  # 次選第一個連線
  picked="$(nmcli -t -f NAME con show | head -n 1 || true)"
  echo "$picked"
}

############################################
# 1) SSH 設定
############################################
log "Configure SSH (PermitRootLogin/PasswordAuthentication)"
if [[ -f /etc/ssh/sshd_config ]]; then
  if [[ "$ENABLE_ROOT_PASSWORD_LOGIN" == "yes" ]]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  fi
  if [[ "$ENABLE_SSH_PASSWORD_LOGIN" == "yes" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  fi
fi
service_restart_ssh

############################################
# 2) Hostname
############################################
log "Set hostname: $HOSTNAME_FQDN"
hostnamectl set-hostname "$HOSTNAME_FQDN" || true

if [[ -f /etc/hosts ]]; then
  if grep -qE '^127\.0\.0\.1' /etc/hosts; then
    grep -q "$HOSTNAME_FQDN" /etc/hosts || sed -i "/^127\.0\.0\.1/s/$/ $HOSTNAME_FQDN/" /etc/hosts
  fi
  if grep -qE '^::1' /etc/hosts; then
    grep -q "$HOSTNAME_FQDN" /etc/hosts || sed -i "/^::1/s/$/ $HOSTNAME_FQDN/" /etc/hosts
  fi
fi

############################################
# 3) SELinux
############################################
if [[ "$DISABLE_SELINUX" == "yes" && -f /etc/selinux/config ]]; then
  log "Disable SELinux in /etc/selinux/config (effective after reboot)"
  sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config || true
  grep "^SELINUX=" /etc/selinux/config || true
fi

############################################
# 4) firewalld
############################################
if [[ "$INSTALL_FIREWALLD" == "yes" ]]; then
  log "Install firewalld"
  pkg_install firewalld || true
  systemctl enable --now firewalld || true
  systemctl status firewalld --no-pager || true

  if [[ "$DISABLE_FIREWALLD" == "yes" ]]; then
    log "Disable firewalld"
    systemctl stop --now firewalld || true
    systemctl disable firewalld || true
  fi
fi

############################################
# 5) Network / DNS
############################################
log "Network configuration: DHCP + DNS_MODE=$DNS_MODE"
if command -v nmcli >/dev/null 2>&1; then
  CONN="$(pick_nm_connection)"
  log "Picked NM connection: ${CONN:-<none>}"

  if [[ -n "$CONN" ]]; then
    nmcli con mod "$CONN" ipv4.method auto || true
    nmcli con mod "$CONN" connection.autoconnect yes || true
  fi

  if [[ "$DNS_MODE" == "none" ]]; then
    # 你原本的方式：dns=none + 直接寫 resolv.conf（可能被覆寫）
    sed -i '/^\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf || true
    systemctl restart NetworkManager || true

    # 寫入 resolv.conf（避免重複）
    for ns in "${DNS_SERVERS[@]}"; do
      grep -q "nameserver $ns" /etc/resolv.conf 2>/dev/null || echo "nameserver $ns" >> /etc/resolv.conf
    done
    systemctl restart NetworkManager || true
  elif [[ "$DNS_MODE" == "nm" ]]; then
    # 推薦：用 NM 設定 ignore-auto-dns + dns servers
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-dns.conf <<EOF
[main]
dns=default
EOF
    systemctl restart NetworkManager || true

    if [[ -n "$CONN" ]]; then
      nmcli con mod "$CONN" ipv4.ignore-auto-dns yes || true
      nmcli con mod "$CONN" ipv4.dns "$(IFS=,; echo "${DNS_SERVERS[*]}")" || true
      # 套用：模板封裝通常不怕斷線；如果你正在 SSH 操作，建議在 console 跑
      nmcli con up "$CONN" || true
    fi
  else
    log "DNS_MODE=skip, do nothing."
  fi

  nmcli connection show || true
else
  warn "nmcli not found; skip NM network/DNS steps."
fi

############################################
# 6) DNF fastestmirror
############################################
log "Enable dnf fastestmirror"
ensure_line "fastestmirror=True" /etc/dnf/dnf.conf || true

############################################
# 7) repo backup（你原文說阿里雲不要用，所以只備份，不做替換）
############################################
log "Backup yum/dnf repos dir"
cp -r /etc/yum.repos.d "/etc/yum.repos.d.backup.$(date +%Y%m%d)" 2>/dev/null || true
$PKG_MGR clean all || true
$PKG_MGR makecache || true
$PKG_MGR repolist || true

############################################
# 8) Common packages
############################################
log "Update packages (exclude kernel) + install common tools"
pkg_update_no_kernel

# epel
pkg_install epel-release || true

pkg_install python3-pip gcc gcc-c++ wget net-tools psmisc lsof bzip2 telnet nmap lrzsz rsync zip unzip \
  dos2unix gdisk parted cloud-utils-growpart e2fsprogs vim || true

python3 -m pip install --upgrade pip || true
pip3 --version || true

log "Install & enable acpid"
pkg_install acpid || true
systemctl enable --now acpid || true
systemctl status acpid --no-pager || true

############################################
# 9) cloud-init install/config
############################################
if [[ "$INSTALL_CLOUD_INIT" == "yes" ]]; then
  log "Install cloud-init"
  pkg_install cloud-init || true
  python3 -m pip install --upgrade six || true

  # cloud.cfg tweak
  if [[ -f /etc/cloud/cloud.cfg ]]; then
    sed -i 's/^\(disable_root:\).*$/\1 false/g' /etc/cloud/cloud.cfg || true
    sed -i 's/^\(ssh_pwauth:\).*$/\1 true/g' /etc/cloud/cloud.cfg || true
  fi

  mkdir -p /etc/cloud/cloud.cfg.d
  cat > /etc/cloud/cloud.cfg.d/99-datasource-timeout.cfg <<'EOF'
datasource:
  Ec2:
    max_wait: 5
  CloudStack:
    max_wait: 5
EOF

  if [[ "$DISABLE_CLOUD_INIT_NETWORK" == "yes" ]]; then
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network:
  config: disabled
EOF
  fi

  systemctl enable --now cloud-init-local cloud-init cloud-config cloud-final || true

  # 清理 cloud-init 狀態（封裝模板前必做）
  log "Clean cloud-init state (safe for template)"
  rm -rf /var/lib/cloud/* 2>/dev/null || true
  rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log 2>/dev/null || true

  cloud-init status || true
else
  log "INSTALL_CLOUD_INIT=no, skip."
fi

############################################
# 10) QGA install + watchdog service
############################################
if [[ "$INSTALL_QGA" == "yes" ]]; then
  log "Install qemu-guest-agent"
  pkg_install qemu-guest-agent || true
  systemctl enable --now qemu-guest-agent || true

  log "Create cdncloud-qga watchdog script+service"
  cat > /usr/local/sbin/cdncloud-qga.sh <<'EOF'
#!/usr/bin/env bash
set -e
while true; do
  sleep 300
  if pgrep -f qemu-ga >/dev/null; then
    :
  else
    (dnf -y install qemu-guest-agent || yum -y install qemu-guest-agent) >/dev/null 2>&1 || true
    systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
  fi
done
EOF
  chmod +x /usr/local/sbin/cdncloud-qga.sh

  cat > /etc/systemd/system/cdncloud-qga.service <<'EOF'
[Unit]
Description=CDNCloud Qemu Guest Agent Watchdog
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cdncloud-qga.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cdncloud-qga.service
fi

############################################
# 11) sysctl + limits
############################################
log "Apply sysctl/limits"
cat >> /etc/sysctl.conf <<'EOF'
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
sysctl -p || true

cat >> /etc/security/limits.conf <<'EOF'
* soft nofile 655360
* hard nofile 131072
* soft nproc 655350
* hard nproc 655350
* soft memlock unlimited
* hard memlock unlimited
EOF

############################################
# 12) Chrony
############################################
log "Configure chrony"
pkg_install chrony || true

for s in "${CHRONY_SERVERS[@]}"; do
  ensure_line "server $s iburst" /etc/chrony.conf
done

systemctl enable --now chronyd || true
systemctl restart chronyd || true
chronyc sources || true

############################################
# 13) Stamp image creation date
############################################
log "Stamp image creation date"
sed -i '/^#IMAGE_CREATION_DATE=/d' /etc/os-release || true
echo "#IMAGE_CREATION_DATE=\"$(date +%Y%m%d)\"" >> /etc/os-release || true

############################################
# 14) 可選：放 Change_SSH_Port.sh（照你原本）
############################################
log "Create Change_SSH_Port.sh"
cat > /root/Change_SSH_Port.sh <<'EOF'
#!/bin/bash
read -p "Please enter the new SSH port number: " NEW_PORT
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]]; then
  echo "Error: Please enter a valid number."
  exit 1
fi
if [ "$NEW_PORT" -le 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "Error: Please enter a number between 1 and 65535."
  exit 1
fi
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
if grep -q "^#Port 22" /etc/ssh/sshd_config; then
  sed -i "s/^#Port 22/Port $NEW_PORT/" /etc/ssh/sshd_config
elif grep -q "^Port " /etc/ssh/sshd_config; then
  sed -i "s/^Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
else
  echo "Port $NEW_PORT" >> /etc/ssh/sshd_config
fi

if systemctl list-unit-files | grep -q '^ssh.socket'; then
  systemctl restart ssh.socket || true
  systemctl enable ssh.socket || true
  systemctl enable ssh.service || true
  systemctl restart ssh.service || true
else
  if systemctl is-active --quiet sshd; then
    systemctl restart sshd
  elif systemctl is-active --quiet ssh; then
    systemctl restart ssh
  else
    echo "SSH service not found. Please restart the SSH service manually."
  fi
fi

echo "SSH port has been changed to $NEW_PORT. Please use the new port to connect."
EOF
chmod +x /root/Change_SSH_Port.sh

############################################
# 15) 詢問是否清理並關機（封裝前用）
############################################
cleanup_and_poweroff(){
  log "Cleanup logs/history/machine-id/cloud-init state then poweroff"

  systemctl stop rsyslog 2>/dev/null || true
  systemctl stop systemd-journald 2>/dev/null || true

  rm -rf /run/log/journal/* 2>/dev/null || true
  rm -f /root/anaconda-ks.cfg 2>/dev/null || true
  rm -rf /var/log/anaconda 2>/dev/null || true
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id 2>/dev/null || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

  rm -rf /var/lib/cloud/* 2>/dev/null || true
  rm -f /var/log/cloud-init.log /var/log/cloud-init-output.log 2>/dev/null || true

  for f in \
    /var/log/boot.log /var/log/lastlog /var/log/btmp /var/log/wtmp \
    /var/log/secure /var/log/cron /var/log/maillog /var/log/spooler \
    /var/log/kdump.log /var/log/dmesg /var/log/dmesg.old /var/log/yum.log \
    /var/log/messages
  do
    [[ -f "$f" ]] && : > "$f" || true
  done

  rm -rf /root/.ssh/* 2>/dev/null || true
  rm -rf /root/.pki/* 2>/dev/null || true
  : > /root/.bash_history 2>/dev/null || true
  history -c 2>/dev/null || true

  # 你原文有清 hostname，這裡保留 hostname 也可以；若你要封裝成「空白 hostname」再打開
  # : > /etc/hostname

  systemctl start systemd-journald 2>/dev/null || true
  log "Poweroff now"
  poweroff
}

echo
echo "============================================================"
echo "Build steps finished."
echo "Next: if you are ready to CAPTURE image/template, run cleanup."
echo "Type 'YES' to cleanup + poweroff, otherwise press Enter to exit."
echo "============================================================"
read -r -p "Cleanup + poweroff? (YES/Enter): " ans
if [[ "$ans" == "YES" ]]; then
  cleanup_and_poweroff
else
  log "Skip cleanup. You can run cleanup later by re-running this script and typing YES, or manually."
fi

