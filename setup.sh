#!/bin/bash

# =================================================================
# Rocky Linux 9 鏡像封裝自動化腳本 (保留指定工具版)
# =================================================================

set -e

SCRIPT_PATH=$(readlink -f "$0")
CURRENT_DIR=$(dirname "$SCRIPT_PATH")

# --- 前面的系統優化、QGA、Cloud-init 步驟保持不變 ---
# (這裡省略中間重複的安裝與設定碼，請沿用你目前的內容)

echo ">>> [4/7] 建立並搬移 SSH 端口更換工具..."

# 直接在 /root 建立工具，避免被資料夾清理掉
cat << 'EOF' > /root/Change_SSH_Port.sh
#!/bin/bash
read -p "請輸入新的 SSH Port 號碼: " NEW_PORT
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -le 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "錯誤: 請輸入有效號碼 (1-65535)."
  exit 1
fi
sed -i "s/^#\?Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
systemctl restart sshd
echo "SSH Port 已更改為 $NEW_PORT。"
EOF
chmod +x /root/Change_SSH_Port.sh

# --- 最後的清理階段 ---

echo ">>> [7/7] 正在清理日誌並自動移除暫存目錄..."

# 押日期與清理 Log (保持原樣)
# ...

# --- 修正後的清理邏輯 ---
echo ">>> 正在移除 git clone 的暫存目錄: $CURRENT_DIR"
# 只刪除 clone 下來的資料夾，不刪除 /root 裡的工具
if [[ "$CURRENT_DIR" != "/root" ]]; then
    rm -rf "$CURRENT_DIR"
fi

# 刪除正在執行的腳本自身 (如果它不在 root 下的話)
rm -f "$SCRIPT_PATH"

echo "====================================================="
echo " ✅ 初始化完成！"
echo " 🛠️  SSH 更換工具已保留在: /root/Change_SSH_Port.sh"
echo "====================================================="

echo > ~/.bash_history
history -c
