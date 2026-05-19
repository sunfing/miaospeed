#!/bin/bash
# ============================================================
# MiaoSpeed 测试后端一键部署脚本
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# 脚本特性: 配置独立 / 安全更新 / 防宕机回滚 / 完整交互管理
# Telegram: https://t.me/i_chl
# ============================================================
set -uo pipefail

INSTALL_DIR="/opt/miaospeed"
LOG_DIR="${INSTALL_DIR}/log"
BACKUP_DIR="${INSTALL_DIR}/backup"
LOG_FILE="${LOG_DIR}/miaospeed.log"
ERR_LOG="${LOG_DIR}/miaospeed-error.log"
UPDATE_LOG="${LOG_DIR}/update.log"
CONF_FILE="${INSTALL_DIR}/miaospeed.conf"
RUN_SCRIPT="${INSTALL_DIR}/run.sh"
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"
SERVICE_NAME="miaospeed"
BIN_NAME=""

# 彩色输出
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

# ============================================================
# 1. 基础环境与卸载流程
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
  err "致命错误: 必须以 root 身份执行此脚本！"
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  say "开始彻底卸载 MiaoSpeed..."
  systemctl stop ${SERVICE_NAME} >/dev/null 2>&1
  systemctl disable ${SERVICE_NAME} >/dev/null 2>&1
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload >/dev/null 2>&1
  
  /etc/init.d/${SERVICE_NAME} stop >/dev/null 2>&1
  /etc/init.d/${SERVICE_NAME} disable >/dev/null 2>&1
  rm -f /etc/init.d/${SERVICE_NAME}

  pkill -9 -f "miaospeed" >/dev/null 2>&1
  rm -rf "$INSTALL_DIR"
  rm -f /usr/bin/miao
  rm -f /etc/logrotate.d/miaospeed
  
  crontab -l 2>/dev/null | grep -v "miaospeed" | crontab -

  ok "MiaoSpeed 及所有残留已完全清除。"
  exit 0
fi

# ============================================================
# 2. 系统检测与依赖安装
# ============================================================
say "检测系统环境并初始化目录..."
mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$BACKUP_DIR"

if [ -f "/etc/openwrt_release" ]; then
  OS_TYPE="openwrt"
elif [ -f "/etc/os-release" ]; then
  OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d '=' -f2 | tr -d '"')
  if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" ]]; then
    OS_TYPE="debian"
  else
    OS_TYPE="other"
  fi
else
  OS_TYPE="other"
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64"; DEFAULT_CONN=64 ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64"; DEFAULT_CONN=32 ;;
  *) err "当前架构 $ARCH 不受支持"; exit 1 ;;
esac
ok "系统: $OS_TYPE | 架构: $ARCH"

say "安装必要依赖..."
if [ "$OS_TYPE" = "openwrt" ]; then
  opkg update && opkg install wget curl unzip net-tools
elif [ "$OS_TYPE" = "debian" ]; then
  apt update && apt install -y wget curl unzip net-tools cron logrotate
fi

# ============================================================
# 3. 获取版本与配置收集
# ============================================================
say "获取最新版本信息..."
LATEST_VERSION=$(curl -s --connect-timeout 5 https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4 || echo "")
if [ -z "$LATEST_VERSION" ]; then
  warn "获取最新版本失败，回退至默认版本 4.6.1"
  LATEST_VERSION="4.6.1"
fi

say "=== 开始配置参数 ==="
read -p "监听端口 (默认: 6699): " INPUT_PORT
PORT=${INPUT_PORT:-6699}

if command -v netstat >/dev/null 2>&1; then
  if netstat -tunlp | grep -q ":${PORT} "; then
    err "端口 ${PORT} 已被占用，请更换端口或清理占用进程！"
    exit 1
  fi
fi

read -p "WebSocket Path (默认: /miaospeed): " INPUT_PATH
PATH_WS=${INPUT_PATH:-/miaospeed}
[[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"

read -p "后端连接 Token (留空自动生成安全随机值): " INPUT_TOKEN
TOKEN=${INPUT_TOKEN:-""}
if [ -z "$TOKEN" ] || [ "$TOKEN" = "defaulttoken" ]; then
  set +o pipefail
  TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  set -o pipefail
  warn "已自动生成强 Token: ${TOKEN}"
fi

read -p "最大并发连接数 (默认推荐 ${DEFAULT_CONN}): " INPUT_CONN
CONNTHREAD=${INPUT_CONN:-$DEFAULT_CONN}

read -p "BotID 白名单 (为空允许所有): " INPUT_WHITE
WHITELIST=${INPUT_WHITE:-""}

read -p "是否下载并启用 MMDB GEOIP 数据库? (y/n 默认: n): " INPUT_MMDB
USE_MMDB=${INPUT_MMDB:-n}

echo "1) systemd (标准 Linux)"
echo "2) procd (OpenWrt 专用)"
read -p "请选择服务管理方式 (1/2 默认: 1): " INPUT_SVC
SERVICE_MODE=${INPUT_SVC:-1}

read -p "是否启用每日凌晨 4:00 无人值守自动更新? (y/n 默认: n): " INPUT_CRON
ENABLE_AUTO_UPDATE=${INPUT_CRON:-n}

# ============================================================
# 4. 核心下载与文件架构组装
# ============================================================
say "开始执行核心部署..."
set -e

systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
/etc/init.d/${SERVICE_NAME} stop >/dev/null 2>&1 || true

cd "$INSTALL_DIR"

if [ -f "$CONF_FILE" ]; then
  cp "$CONF_FILE" "${BACKUP_DIR}/miaospeed.conf.bak"
  ok "已备份旧配置"
fi

FILE_NAME="${BIN_NAME}-${LATEST_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${LATEST_VERSION}/${FILE_NAME}"

say "下载核心程序 ${LATEST_VERSION}..."
wget --connect-timeout 15 -O "${FILE_NAME}" "${DOWNLOAD_URL}"

say "获取并校验 SHA256..."
if wget -q --connect-timeout 5 -O "${FILE_NAME}.sha256" "${DOWNLOAD_URL}.sha256"; then
  LOCAL_SHA256=$(sha256sum "${FILE_NAME}" | awk '{print $1}')
  REMOTE_SHA256=$(cat "${FILE_NAME}.sha256" | awk '{print $1}')
  if [ "$LOCAL_SHA256" = "$REMOTE_SHA256" ]; then
    ok "SHA256 校验通过"
  else
    err "SHA256 校验失败！文件损坏或被劫持。"
    rm -f "${FILE_NAME}" "${FILE_NAME}.sha256"
    exit 1
  fi
  rm -f "${FILE_NAME}.sha256"
else
  warn "无远程 SHA256 校验文件，跳过校验。"
fi

tar -zxvf "${FILE_NAME}" >/dev/null 2>&1
mv "${BIN_NAME}" "miaospeed"
rm -f "${FILE_NAME}"
chmod +x "miaospeed"

if [[ "$USE_MMDB" =~ [yY] ]]; then
  say "拉取 MMDB 数据库..."
  wget -q --connect-timeout 15 -O GeoLite2-City.mmdb "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
  wget -q --connect-timeout 15 -O GeoLite2-ASN.mmdb "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb"
fi

set +e

# ============================================================
# 5. 生成配置文件与 Wrapper
# ============================================================
cat > "${CONF_FILE}" <<EOF
PORT="${PORT}"
PATH_WS="${PATH_WS}"
TOKEN="${TOKEN}"
WHITELIST="${WHITELIST}"
CONNTHREAD="${CONNTHREAD}"
TASKLIMIT="150"
SPEEDLIMIT="0"
PAUSESECOND="0"
USE_MMDB="${USE_MMDB}"
SERVICE_MODE="${SERVICE_MODE}"
EOF

cat > "${RUN_SCRIPT}" <<'EOF'
#!/bin/sh
ulimit -n 65535 2>/dev/null
. /opt/miaospeed/miaospeed.conf

ARGS="server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"

[ -n "$WHITELIST" ] && ARGS="${ARGS} -whitelist ${WHITELIST}"
if [[ "$USE_MMDB" =~ [yY] ]]; then
  ARGS="${ARGS} -mmdb /opt/miaospeed/GeoLite2-ASN.mmdb,/opt/miaospeed/GeoLite2-City.mmdb"
fi

exec /opt/miaospeed/miaospeed ${ARGS}
EOF
chmod +x "${RUN_SCRIPT}"

# ============================================================
# 6. 服务注册与配置
# ============================================================
if [ "$SERVICE_MODE" = "1" ]; then
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=MiaoSpeed Backend Service
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
ExecStart=${RUN_SCRIPT}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${ERR_LOG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
  systemctl restart ${SERVICE_NAME}
  
  if command -v logrotate >/dev/null 2>&1; then
    cat > /etc/logrotate.d/miaospeed <<EOF
/opt/miaospeed/log/*.log {
    daily
    rotate 3
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
  fi
else
  cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PROG=${RUN_SCRIPT}
LOG_FILE=${LOG_FILE}

start_service() {
    procd_open_instance
    procd_set_param command \$PROG
    procd_set_param limits core="unlimited" nofile="65535"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file \$LOG_FILE
    procd_close_instance
}
EOF
  chmod +x /etc/init.d/${SERVICE_NAME}
  /etc/init.d/${SERVICE_NAME} enable
  /etc/init.d/${SERVICE_NAME} restart
fi

# ============================================================
# 7. 自动更新与时间戳防宕机回滚系统
# ============================================================
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -uo pipefail

DIR="/opt/miaospeed"
BIN="${DIR}/miaospeed"
CONF="${DIR}/miaospeed.conf"
BACKUP_DIR="${DIR}/backup"
LOG="${DIR}/log/update.log"

[ ! -f "$CONF" ] && exit 1
. "$CONF"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64" ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64" ;;
  *) exit 1 ;;
esac

CUR_VER=$($BIN -version 2>/dev/null | grep '^version:' | awk '{print $2}')
LAT_VER=$(curl -s --connect-timeout 5 "https://api.github.com/repos/airportr/miaospeed/releases/latest" | grep tag_name | cut -d '"' -f4 || echo "")
[ -z "$LAT_VER" ] && { echo "[Warn] 获取最新版本失败，退出更新。" >> "$LOG"; exit 1; }

if [ "$CUR_VER" != "$LAT_VER" ]; then
  echo ">>> 发现新版本: v$CUR_VER -> v$LAT_VER"
  
  # 带有时间戳的精准备份
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$BIN" "${BACKUP_DIR}/miaospeed_${TS}_bak" >/dev/null 2>&1
  cp "$CONF" "${BACKUP_DIR}/miaospeed.conf_${TS}_bak" >/dev/null 2>&1
  
  FILE_NAME="${BIN_NAME}-${LAT_VER}.tar.gz"
  DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${LAT_VER}/${FILE_NAME}"
  
  echo "正在拉取程序..."
  if ! wget -q --connect-timeout 15 -O "${DIR}/new.tar.gz" "${DOWNLOAD_URL}"; then
      echo "[Error] 下载失败，中止更新。"
      rm -f "${DIR}/new.tar.gz"
      exit 1
  fi
  
  if wget -q --connect-timeout 5 -O "${DIR}/new.tar.gz.sha256" "${DOWNLOAD_URL}.sha256"; then
    L_SHA=$(sha256sum "${DIR}/new.tar.gz" | awk '{print $1}')
    R_SHA=$(cat "${DIR}/new.tar.gz.sha256" | awk '{print $1}')
    if [ "$L_SHA" != "$R_SHA" ]; then
      echo "[Error] SHA256 不匹配！文件已丢弃，更新中止。"
      rm -f "${DIR}/new.tar.gz"*
      exit 1
    fi
  fi

  [ "$SERVICE_MODE" = "1" ] && systemctl stop miaospeed || /etc/init.d/miaospeed stop
  
  cd "$DIR" && tar -zxvf new.tar.gz >/dev/null
  mv "${BIN_NAME}" miaospeed && chmod +x miaospeed && rm -f new.tar.gz*
  
  [ "$SERVICE_MODE" = "1" ] && systemctl restart miaospeed || /etc/init.d/miaospeed restart
  echo "服务已重启，等待 5 秒进行健康检查..."
  sleep 5
  
  IS_ALIVE=0
  if [ "$SERVICE_MODE" = "1" ]; then
    systemctl is-active --quiet miaospeed && IS_ALIVE=1
  else
    pgrep -f "/opt/miaospeed/run.sh" >/dev/null && IS_ALIVE=1
  fi

  if [ $IS_ALIVE -eq 1 ]; then
    echo "✅ [更新成功] 当前版本已升级至: $LAT_VER"
    # 可选：清理超过 30 天的老旧备份
    find "$BACKUP_DIR" -type f -name "*_bak" -mtime +30 -exec rm -f {} \;
  else
    echo "❌ [严重错误] 新版本启动宕机，触发安全回滚机制！"
    [ "$SERVICE_MODE" = "1" ] && systemctl stop miaospeed || /etc/init.d/miaospeed stop
    # 精准回滚至本次更新刚刚生成的备份
    cp "${BACKUP_DIR}/miaospeed_${TS}_bak" "$BIN" >/dev/null 2>&1
    cp "${BACKUP_DIR}/miaospeed.conf_${TS}_bak" "$CONF" >/dev/null 2>&1
    [ "$SERVICE_MODE" = "1" ] && systemctl restart miaospeed || /etc/init.d/miaospeed restart
    echo "⚠️ [回滚完成] 已恢复至旧版本 v$CUR_VER"
  fi
else
  echo "✅ 当前已是最新版 ($CUR_VER)。"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

if [[ "$ENABLE_AUTO_UPDATE" =~ [yY] ]]; then
  CRON_JOB="0 4 * * * ${UPDATE_SCRIPT} >> ${UPDATE_LOG} 2>&1"
  (crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}"; echo "$CRON_JOB") | crontab -
  ok "已开启凌晨 4:00 防宕机安全自动更新"
fi

# ============================================================
# 8. 全局交互式控制台 (miao)
# ============================================================
cat > /usr/bin/miao <<'EOF'
#!/bin/bash
set -uo pipefail

CONF_FILE="/opt/miaospeed/miaospeed.conf"
[ ! -f "$CONF_FILE" ] && echo "未找到配置！请先安装。" && exit 1
. "$CONF_FILE"

RESTART_STATUS="❌ 未开启"
if crontab -l 2>/dev/null | grep -q "30 4 .*miaospeed restart"; then
  RESTART_STATUS="✅ 已开启 (每日 04:30)"
fi

clear
echo -e "\033[1;34m==========================================\033[0m"
echo -e "      \033[1;32mMiaoSpeed 安全交互式控制台\033[0m"
echo -e "\033[1;34m==========================================\033[0m"
echo " 1. 查看当前运行状态与配置"
echo " 2. 修改配置参数 (安全全量重写)"
echo " 3. 手动检查并更新程序 (防宕机)"
echo " 4. 重启 MiaoSpeed 服务"
echo " 5. 停止 MiaoSpeed 服务"
echo " 6. 实时查看运行日志"
echo " 7. 开启/关闭 防假死定时重启 (当前: $RESTART_STATUS)"
echo " 8. 彻底卸载 MiaoSpeed"
echo " 0. 退出"
echo -e "\033[1;34m==========================================\033[0m"
read -p "请输入序号: " choice

case "$choice" in
  1)
    echo -e "\n--- 当前配置信息 ---"
    cat "$CONF_FILE"
    echo -e "\n--- 服务状态 ---"
    if [ "$SERVICE_MODE" = "1" ]; then systemctl status miaospeed --no-pager | grep Active; else /etc/init.d/miaospeed status; fi
    ;;
  2)
    cp "$CONF_FILE" "/opt/miaospeed/backup/miaospeed.conf_$(date +%Y%m%d_%H%M%S).bak"
    
    # 扩展的修改项
    read -p "监听端口 [$PORT]: " N_PORT; PORT=${N_PORT:-$PORT}
    read -p "WebSocket 路径 [$PATH_WS]: " N_PATH; PATH_WS=${N_PATH:-$PATH_WS}
    read -p "Token [$TOKEN]: " N_TOK; TOKEN=${N_TOK:-$TOKEN}
    read -p "白名单(为空允许所有) [$WHITELIST]: " N_WHITE; WHITELIST=${N_WHITE:-$WHITELIST}
    read -p "最大并发数 [$CONNTHREAD]: " N_CONN; CONNTHREAD=${N_CONN:-$CONNTHREAD}
    
    cat > "$CONF_FILE" <<CONF
PORT="${PORT}"
PATH_WS="${PATH_WS}"
TOKEN="${TOKEN}"
WHITELIST="${WHITELIST}"
CONNTHREAD="${CONNTHREAD}"
TASKLIMIT="${TASKLIMIT}"
SPEEDLIMIT="${SPEEDLIMIT}"
PAUSESECOND="${PAUSESECOND}"
USE_MMDB="${USE_MMDB}"
SERVICE_MODE="${SERVICE_MODE}"
CONF
    
    echo "✅ 配置已重写并备份。正在重启..."
    if [ "$SERVICE_MODE" = "1" ]; then systemctl restart miaospeed; else /etc/init.d/miaospeed restart; fi
    ;;
  3)
    bash /opt/miaospeed/update.sh
    ;;
  4)
    if [ "$SERVICE_MODE" = "1" ]; then systemctl restart miaospeed; else /etc/init.d/miaospeed restart; fi
    echo "✅ 服务已重启"
    ;;
  5)
    if [ "$SERVICE_MODE" = "1" ]; then systemctl stop miaospeed; else /etc/init.d/miaospeed stop; fi
    echo "✅ 服务已停止"
    ;;
  6)
    tail -f /opt/miaospeed/log/miaospeed.log
    ;;
  7)
    if crontab -l 2>/dev/null | grep -q "30 4 .*miaospeed restart"; then
      crontab -l 2>/dev/null | grep -v "30 4 .*miaospeed restart" | crontab -
      echo "✅ 防假死自动重启已关闭！"
    else
      if [ "$SERVICE_MODE" = "1" ]; then
        CRON_CMD="30 4 * * * /bin/systemctl restart miaospeed >/dev/null 2>&1"
      else
        CRON_CMD="30 4 * * * /etc/init.d/miaospeed restart >/dev/null 2>&1"
      fi
      (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
      echo "✅ 已开启防假死策略：每日凌晨 04:30 自动错峰重启服务！"
    fi
    ;;
  8)
    read -p "⚠️ 确定要彻底卸载并清理残留吗? (y/n): " confirm
    if [[ "$confirm" =~ [yY] ]]; then
      # 这里的真实地址在你托管到 GitHub 后替换即可
      bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InMiSp.sh) --uninstall 2>/dev/null || echo "请手动执行安装脚本并加 --uninstall 参数。"
    fi
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x /usr/bin/miao

# ============================================================
# 9. 部署完成提示
# ============================================================
say "部署完成！"
ok "控制台面板命令: ${C_G}miao${C_0}"
warn "防火墙放行提示: 请确保安全组或本地防火墙已放行 TCP 端口 ${PORT}"
