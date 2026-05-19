#!/bin/bash
# ============================================================
# MiaoSpeed 测试后端安装与管理脚本
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# 脚本特性: 配置独立 / 更新前校验 / 失败回滚 / 交互式管理
# Telegram: https://t.me/i_chl
# ============================================================

# 全局严格模式
set -uo pipefail

# 目录定义
INSTALL_DIR="/opt/miaospeed"
LOG_DIR="${INSTALL_DIR}/log"
DATA_DIR="${INSTALL_DIR}/data"
TMP_DIR="${INSTALL_DIR}/tmp"
BACKUP_DIR="${INSTALL_DIR}/backup"

CONF_FILE="${INSTALL_DIR}/miaospeed.conf"
RUN_SCRIPT="${INSTALL_DIR}/run.sh"
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"
SERVICE_NAME="miaospeed"
BIN_NAME=""
SERVICE_MODE=1 # 1=systemd, 2=procd

# 彩色输出
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

is_yes() {
  case "${1:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

random_alnum() {
  local len="${1:-32}" value
  set +o pipefail
  value=$(tr -dc A-Za-z0-9 </dev/urandom | head -c "$len")
  set -o pipefail
  printf '%s' "$value"
}

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_path() {
  [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

validate_token() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._/-]+$ ]]
}

validate_botid() {
  [[ -z "${1:-}" || "${1:-}" =~ ^[0-9]+$ ]]
}

random_port() {
  local port
  while true; do
    port=$((10000 + RANDOM % 50000))
    if ! netstat -tunlp 2>/dev/null | grep -q ":${port} "; then
      printf '%s' "$port"
      return 0
    fi
  done
}

# ============================================================
# 1. 基础环境与卸载流程
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
  err "致命错误: 必须以 root 身份执行此脚本！"
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  say "开始卸载 MiaoSpeed..."
  systemctl stop ${SERVICE_NAME} >/dev/null 2>&1 || true
  systemctl disable ${SERVICE_NAME} >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/${SERVICE_NAME}.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  
  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/${SERVICE_NAME} stop >/dev/null 2>&1 || true
    /etc/init.d/${SERVICE_NAME} disable >/dev/null 2>&1 || true
    rm -f /etc/init.d/${SERVICE_NAME}
  fi

  # 只清理本脚本创建的服务、进程和定时任务。
  pkill -9 -f "^${INSTALL_DIR}/miaospeed" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR"
  rm -f /usr/bin/miao
  rm -f /etc/logrotate.d/miaospeed
  
  crontab -l 2>/dev/null \
    | grep -v -F "${UPDATE_SCRIPT}" \
    | grep -v -F "/bin/systemctl restart ${SERVICE_NAME}" \
    | grep -v -F "/etc/init.d/${SERVICE_NAME} restart" \
    | crontab -

  ok "MiaoSpeed 相关文件和定时任务已清理。"
  exit 0
fi

# ============================================================
# 2. 系统检测与依赖安装
# ============================================================
say "检测系统环境并初始化目录..."
mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$DATA_DIR" "$TMP_DIR" "$BACKUP_DIR"

if [ -f "/etc/openwrt_release" ]; then
  OS_TYPE="openwrt"
  SERVICE_MODE=2
else
  OS_TYPE="debian"
  SERVICE_MODE=1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64"; DEFAULT_CONN=64 ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64"; DEFAULT_CONN=32 ;;
  *) err "当前架构 $ARCH 不受支持"; exit 1 ;;
esac
ok "系统: $OS_TYPE | 架构: $ARCH | 服务管理: $([ $SERVICE_MODE -eq 1 ] && echo 'systemd' || echo 'procd')"

say "安装核心依赖..."
if [ "$OS_TYPE" = "openwrt" ]; then
  if ! opkg update >/dev/null 2>&1 || ! opkg install bash wget curl unzip net-tools >/dev/null 2>&1; then
    err "依赖安装失败，请检查 opkg 源和网络连接。"
    exit 1
  fi
else
  if ! apt update >/dev/null 2>&1 || ! apt install -y wget curl unzip net-tools cron logrotate >/dev/null 2>&1; then
    err "依赖安装失败，请检查 apt 源和网络连接。"
    exit 1
  fi
fi

# ============================================================
# 3. 参数配置向导
# ============================================================
say "获取远端最新版本..."
LATEST_VERSION=$(curl -s --connect-timeout 5 https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4 || echo "")
if [ -z "$LATEST_VERSION" ]; then
  warn "获取最新版本失败，回退至默认版本 4.6.1"
  LATEST_VERSION="4.6.1"
fi

echo -e "\n${C_G}=== 阶段一: 基础连接参数 (直接回车自动生成) ===${C_0}"

# 端口生成逻辑
read -p "监听端口 (直接回车随机分配 10000-59999 端口): " INPUT_PORT
if [ -z "$INPUT_PORT" ]; then
  PORT=$(random_port)
  ok "已自动分配空闲端口: ${PORT}"
else
  PORT=$INPUT_PORT
  if ! validate_port "$PORT"; then
    err "端口必须是 1-65535 之间的数字。"
    exit 1
  fi
  if netstat -tunlp 2>/dev/null | grep -q ":${PORT} "; then
    err "端口 ${PORT} 已被占用！" && exit 1
  fi
fi

# WS Path 生成逻辑
read -p "WebSocket 路径 (直接回车生成 32 位随机路径): " INPUT_PATH
if [ -z "$INPUT_PATH" ]; then
  PATH_WS="/$(random_alnum 32)"
  ok "已自动生成路径: ${PATH_WS}"
else
  PATH_WS=$INPUT_PATH
  [[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"
  if ! validate_path "$PATH_WS"; then
    err "WebSocket 路径仅允许字母、数字、点、下划线、短横线和斜杠，并且必须以 / 开头。"
    exit 1
  fi
fi

# Token 生成逻辑
read -p "连接 Token (直接回车生成 32 位随机 Token): " INPUT_TOKEN
if [ -z "$INPUT_TOKEN" ] || [ "$INPUT_TOKEN" = "defaulttoken" ]; then
  TOKEN=$(random_alnum 32)
  ok "已自动生成 Token: ${TOKEN}"
else
  TOKEN=$INPUT_TOKEN
  if ! validate_token "$TOKEN"; then
    err "Token 仅允许字母、数字、点、下划线、短横线和斜杠。"
    exit 1
  fi
fi

# 进阶参数预设
CONNTHREAD=$DEFAULT_CONN
TASKLIMIT=150
SPEEDLIMIT=0
PAUSESECOND=0
WHITELIST=""

echo -e "\n${C_Y}=== 阶段二: 运行参数 ===${C_0}"
read -p "是否需要手工配置进阶参数 (并发/队列/白名单等)？(y/N 默认: N): " EDIT_ADV
if is_yes "$EDIT_ADV"; then
  read -p "BotID 白名单 (仅数字，留空允许所有) []: " INPUT_WHITE; WHITELIST=${INPUT_WHITE:-""}
  if ! validate_botid "$WHITELIST"; then err "BotID 白名单仅允许数字，或留空。"; exit 1; fi
  read -p "最大并发连接数 [${DEFAULT_CONN}]: " INPUT_CONN; CONNTHREAD=${INPUT_CONN:-$DEFAULT_CONN}
  if ! validate_uint "$CONNTHREAD"; then err "最大并发连接数必须是非负整数。"; exit 1; fi
  read -p "最大任务队列 [150]: " INPUT_TASK; TASKLIMIT=${INPUT_TASK:-150}
  if ! validate_uint "$TASKLIMIT"; then err "最大任务队列必须是非负整数。"; exit 1; fi
  read -p "测速限速 (字节/秒, 0即不限速) [0]: " INPUT_SPEED; SPEEDLIMIT=${INPUT_SPEED:-0}
  if ! validate_uint "$SPEEDLIMIT"; then err "测速限速必须是非负整数。"; exit 1; fi
  read -p "任务间隔秒数 [0]: " INPUT_PAUSE; PAUSESECOND=${INPUT_PAUSE:-0}
  if ! validate_uint "$PAUSESECOND"; then err "任务间隔秒数必须是非负整数。"; exit 1; fi
fi

echo -e "\n${C_B}=== 阶段三: 自动维护选项 ===${C_0}"
read -p "是否下载并启用 MMDB GEOIP 数据库 (存放于 data 目录)? (y/N 默认: N): " INPUT_MMDB
USE_MMDB=${INPUT_MMDB:-n}

read -p "是否启用每日 04:00 自动更新? (y/N 默认: N): " INPUT_CRON
ENABLE_AUTO_UPDATE=${INPUT_CRON:-n}

read -p "是否启用每日 04:30 定时重启服务? (Y/n 默认: Y): " INPUT_RESTART
ENABLE_RESTART=${INPUT_RESTART:-y}

# ============================================================
# 4. 核心程序下载与短暂停机部署
# ============================================================
say "下载并校验核心程序..."
set -e # 开启出错即中断保护

cd "$TMP_DIR"
FILE_NAME="${BIN_NAME}-${LATEST_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${LATEST_VERSION}/${FILE_NAME}"

wget -q --show-progress --connect-timeout 15 -O "${FILE_NAME}" "${DOWNLOAD_URL}"

if wget -q --connect-timeout 5 -O "${FILE_NAME}.sha256" "${DOWNLOAD_URL}.sha256"; then
  L_SHA=$(sha256sum "${FILE_NAME}" | awk '{print $1}')
  R_SHA=$(cat "${FILE_NAME}.sha256" | awk '{print $1}')
  if [ "$L_SHA" = "$R_SHA" ]; then
    ok "核心程序 SHA256 校验通过！"
  else
    err "SHA256 校验失败！下载包异常，中止安装。" && exit 1
  fi
fi

tar -zxvf "${FILE_NAME}" >/dev/null 2>&1
if [ ! -f "${BIN_NAME}" ]; then
  err "安装包中未找到预期的可执行文件 ${BIN_NAME}。"
  exit 1
fi
chmod +x "${BIN_NAME}"

if is_yes "$USE_MMDB"; then
  say "下载 GEOIP 数据库..."
  wget -q --connect-timeout 15 -O "${DATA_DIR}/GeoLite2-City.mmdb" "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
  wget -q --connect-timeout 15 -O "${DATA_DIR}/GeoLite2-ASN.mmdb" "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb"
fi

# 确认所有文件完好后，短暂停止服务并替换程序
[ "$SERVICE_MODE" = "1" ] && systemctl stop miaospeed >/dev/null 2>&1 || true
[ "$SERVICE_MODE" = "2" ] && /etc/init.d/miaospeed stop >/dev/null 2>&1 || true

mv "${TMP_DIR}/${BIN_NAME}" "${INSTALL_DIR}/miaospeed"
rm -rf "${TMP_DIR:?}"/*

set +e

# ============================================================
# 5. 配置文件与启动包装器
# ============================================================
cat > "${CONF_FILE}" <<EOF
PORT="${PORT}"
PATH_WS="${PATH_WS}"
TOKEN="${TOKEN}"
WHITELIST="${WHITELIST}"
CONNTHREAD="${CONNTHREAD}"
TASKLIMIT="${TASKLIMIT}"
SPEEDLIMIT="${SPEEDLIMIT}"
PAUSESECOND="${PAUSESECOND}"
USE_MMDB="${USE_MMDB}"
EOF
# 锁死配置权限，仅限 root 读写
chmod 600 "${CONF_FILE}"

# 生成启动包装器。配置值已在写入前限制字符集，避免参数拆分异常。
cat > "${RUN_SCRIPT}" <<'EOF'
#!/bin/sh
ulimit -n 65535 2>/dev/null
CONF="/opt/miaospeed/miaospeed.conf"

# 纯文本安全解析变量
_GET() { grep "^$1=" "$CONF" | sed -e "s/^$1=//;s/^\"//;s/\"$//"; }

PORT=$(_GET PORT)
PATH_WS=$(_GET PATH_WS)
TOKEN=$(_GET TOKEN)
WHITELIST=$(_GET WHITELIST)
CONNTHREAD=$(_GET CONNTHREAD)
TASKLIMIT=$(_GET TASKLIMIT)
SPEEDLIMIT=$(_GET SPEEDLIMIT)
PAUSESECOND=$(_GET PAUSESECOND)
USE_MMDB=$(_GET USE_MMDB)

ARGS="server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"

[ -n "$WHITELIST" ] && ARGS="${ARGS} -whitelist ${WHITELIST}"

# POSIX 标准 case 判断
case "$USE_MMDB" in
  y|Y|yes|YES) ARGS="${ARGS} -mmdb /opt/miaospeed/data/GeoLite2-ASN.mmdb,/opt/miaospeed/data/GeoLite2-City.mmdb" ;;
esac

exec /opt/miaospeed/miaospeed $ARGS
EOF
chmod +x "${RUN_SCRIPT}"

# ============================================================
# 6. 系统级服务注册
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
StandardOutput=append:${LOG_DIR}/miaospeed.log
StandardError=append:${LOG_DIR}/miaospeed-error.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
  systemctl start ${SERVICE_NAME}
  
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
LOG_FILE=${LOG_DIR}/miaospeed.log

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
  /etc/init.d/${SERVICE_NAME} start
fi

# ============================================================
# 7. 更新脚本 (原子锁 + 校验 + 回滚)
# ============================================================
cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail
DIR="/opt/miaospeed"
BIN="${DIR}/miaospeed"
CONF="${DIR}/miaospeed.conf"
TMP="${DIR}/tmp"
BACKUP="${DIR}/backup"
LOCK_DIR="${TMP}/update.lock"
WORK_DIR="${TMP}/update-work"
LOG="${DIR}/log/update.log"

[ ! -f "$CONF" ] && exit 1

mkdir -p "$TMP" "$BACKUP" "${DIR}/log"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[Warn] 检测到更新任务正在运行，本次退出。" >> "$LOG"
  exit 1
fi

cleanup() { rm -rf "$WORK_DIR" "$LOCK_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

SVC_MODE=$( [ -f "/etc/systemd/system/miaospeed.service" ] && echo 1 || echo 2 )
stop_service() {
  if [ "$SVC_MODE" -eq 1 ]; then systemctl stop miaospeed; else /etc/init.d/miaospeed stop; fi
}
start_service() {
  if [ "$SVC_MODE" -eq 1 ]; then systemctl start miaospeed; else /etc/init.d/miaospeed start; fi
}

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64" ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64" ;;
  *) exit 1 ;;
esac

CUR_VER=$($BIN -version 2>/dev/null | grep '^version:' | awk '{print $2}' || echo "unknown")
LAT_VER=$(curl -s --connect-timeout 5 "https://api.github.com/repos/airportr/miaospeed/releases/latest" | grep tag_name | cut -d '"' -f4 || echo "")
[ -z "$LAT_VER" ] && { echo "[Warn] 获取最新版本失败。" >> "$LOG"; exit 1; }

if [ "$CUR_VER" != "$LAT_VER" ]; then
  echo ">>> 发现新版本: v$CUR_VER -> v$LAT_VER"
  
  TS=$(date +%Y%m%d_%H%M%S)
  
  FILE="${BIN_NAME}-${LAT_VER}.tar.gz"
  URL="https://github.com/airportr/miaospeed/releases/download/${LAT_VER}/${FILE}"
  
  echo ">>> 下载更新包到临时目录..."
  if ! wget -q --connect-timeout 15 -O "${WORK_DIR}/${FILE}" "${URL}"; then
      echo "[Error] 下载失败，业务未中断。"
      exit 1
  fi
  
  if wget -q --connect-timeout 5 -O "${WORK_DIR}/${FILE}.sha256" "${URL}.sha256"; then
    L_SHA=$(sha256sum "${WORK_DIR}/${FILE}" | awk '{print $1}')
    R_SHA=$(cat "${WORK_DIR}/${FILE}.sha256" | awk '{print $1}')
    if [ "$L_SHA" != "$R_SHA" ]; then
      echo "[Error] SHA256 校验阻断！文件丢弃。"
      exit 1
    fi
  fi

  tar -zxvf "${WORK_DIR}/${FILE}" -C "$WORK_DIR" >/dev/null 2>&1
  if [ ! -f "${WORK_DIR}/${BIN_NAME}" ]; then
    echo "[Error] 更新包中未找到可执行文件 ${BIN_NAME}，业务未中断。"
    exit 1
  fi
  chmod +x "${WORK_DIR}/${BIN_NAME}"

  cp "$BIN" "${BACKUP}/miaospeed_${TS}_bak" >/dev/null 2>&1 || true
  cp "$CONF" "${BACKUP}/miaospeed.conf_${TS}_bak" >/dev/null 2>&1 || true
  
  echo ">>> 校验完成，短暂停止服务并替换程序..."
  stop_service || true
  if ! mv "${WORK_DIR}/${BIN_NAME}" "$BIN"; then
    echo "[Error] 替换程序失败，尝试恢复服务。"
    start_service || true
    exit 1
  fi
  chmod +x "$BIN"
  start_service || true
  
  echo ">>> 服务已重启，5 秒后进行健康检查..."
  sleep 5
  
  IS_ALIVE=0
  if [ "$SVC_MODE" -eq 1 ]; then
    systemctl is-active --quiet miaospeed && IS_ALIVE=1
  else
    pgrep -f "${DIR}/miaospeed" >/dev/null && IS_ALIVE=1
  fi

  if [ $IS_ALIVE -eq 1 ]; then
    echo "✅ [更新成功] 已升级至: $LAT_VER"
    find "$BACKUP" -type f -name "*_bak" -mtime +30 -exec rm -f {} \;
  else
    echo "❌ [错误] 新版本启动失败，开始回滚。"
    stop_service || true
    cp "${BACKUP}/miaospeed_${TS}_bak" "$BIN" >/dev/null 2>&1 || true
    cp "${BACKUP}/miaospeed.conf_${TS}_bak" "$CONF" >/dev/null 2>&1 || true
    start_service || true
    echo "⚠️ [回滚完成] 已恢复旧版本。"
  fi
else
  echo "✅ 当前已是最新版 ($CUR_VER)。"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# 注入定时任务
if is_yes "$ENABLE_AUTO_UPDATE"; then
  CRON_JOB="0 4 * * * ${UPDATE_SCRIPT} >> ${LOG_DIR}/update.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}"; echo "$CRON_JOB") | crontab -
fi

if is_yes "$ENABLE_RESTART"; then
  if [ "$SERVICE_MODE" = "1" ]; then
    CRON_RESTART="30 4 * * * /bin/systemctl restart miaospeed >/dev/null 2>&1"
  else
    CRON_RESTART="30 4 * * * /etc/init.d/miaospeed restart >/dev/null 2>&1"
  fi
  (crontab -l 2>/dev/null \
    | grep -v -F "/bin/systemctl restart miaospeed" \
    | grep -v -F "/etc/init.d/miaospeed restart"; echo "$CRON_RESTART") | crontab -
fi

# ============================================================
# 8. 交互式管理命令
# ============================================================
cat > /usr/bin/miao <<'EOF'
#!/bin/bash
set -uo pipefail
CONF_FILE="/opt/miaospeed/miaospeed.conf"
[ ! -f "$CONF_FILE" ] && echo "未找到配置！请先安装。" && exit 1

_GET() { grep "^$1=" "$CONF_FILE" | sed -e "s/^$1=//;s/^\"//;s/\"$//"; }
validate_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
validate_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
validate_path() { [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]; }
validate_token() { [[ "${1:-}" =~ ^[A-Za-z0-9._/-]+$ ]]; }
validate_botid() { [[ -z "${1:-}" || "${1:-}" =~ ^[0-9]+$ ]]; }
has_restart_cron() {
  crontab -l 2>/dev/null | grep -F -q "/bin/systemctl restart miaospeed" \
    || crontab -l 2>/dev/null | grep -F -q "/etc/init.d/miaospeed restart"
}

PORT=$(_GET PORT); PATH_WS=$(_GET PATH_WS); TOKEN=$(_GET TOKEN); WHITELIST=$(_GET WHITELIST)
CONNTHREAD=$(_GET CONNTHREAD); TASKLIMIT=$(_GET TASKLIMIT); SPEEDLIMIT=$(_GET SPEEDLIMIT)
PAUSESECOND=$(_GET PAUSESECOND); USE_MMDB=$(_GET USE_MMDB)
SVC_MODE=$( [ -f "/etc/systemd/system/miaospeed.service" ] && echo 1 || echo 2 )

RESTART_STATUS="❌ 未开启"
has_restart_cron && RESTART_STATUS="✅ 已开启 (每日 04:30)"

clear
echo -e "\033[1;34m==========================================\033[0m"
echo -e "      \033[1;32mMiaoSpeed 管理控制台\033[0m"
echo -e "\033[1;34m==========================================\033[0m"
echo " 1. 查看运行状态与配置详情"
echo " 2. 修改运行参数"
echo " 3. 手动检查并更新程序"
echo " 4. 重启 MiaoSpeed 服务"
echo " 5. 停止 MiaoSpeed 服务"
echo " 6. 实时查看运行日志"
echo " 7. 开启/关闭 定时重启 (当前: $RESTART_STATUS)"
echo " 8. 卸载节点服务"
echo " 0. 退出"
echo -e "\033[1;34m==========================================\033[0m"
read -p "请输入序号: " choice

case "$choice" in
  1)
    echo -e "\n--- 当前配置 ---"
    grep "=" "$CONF_FILE"
    echo -e "\n--- 守护进程状态 ---"
    [ "$SVC_MODE" -eq 1 ] && systemctl status miaospeed --no-pager | grep Active || /etc/init.d/miaospeed status
    ;;
  2)
    cp "$CONF_FILE" "/opt/miaospeed/backup/miaospeed.conf_$(date +%Y%m%d_%H%M%S)_bak"
    echo -e "\n--- 基础配置 (直接回车保持不变) ---"
    read -p "监听端口 [$PORT]: " N_PORT; PORT=${N_PORT:-$PORT}
    if ! validate_port "$PORT"; then echo "端口必须是 1-65535 之间的数字。"; exit 1; fi
    read -p "WebSocket 路径 [$PATH_WS]: " N_PATH; PATH_WS=${N_PATH:-$PATH_WS}
    [[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"
    if ! validate_path "$PATH_WS"; then echo "WebSocket 路径包含非法字符。"; exit 1; fi
    read -p "连接 Token [$TOKEN]: " N_TOK; TOKEN=${N_TOK:-$TOKEN}
    if ! validate_token "$TOKEN"; then echo "Token 包含非法字符。"; exit 1; fi
    
    echo -e "\n--- 运行参数 (直接回车保持不变) ---"
    echo "提示: 没有明确性能瓶颈时建议保持默认。"
    read -p "最大并发数 [$CONNTHREAD]: " N_CONN; CONNTHREAD=${N_CONN:-$CONNTHREAD}
    if ! validate_uint "$CONNTHREAD"; then echo "最大并发数必须是非负整数。"; exit 1; fi
    read -p "最大任务队列 [$TASKLIMIT]: " N_TASK; TASKLIMIT=${N_TASK:-$TASKLIMIT}
    if ! validate_uint "$TASKLIMIT"; then echo "最大任务队列必须是非负整数。"; exit 1; fi
    read -p "测速限速(B/s) [$SPEEDLIMIT]: " N_SPD; SPEEDLIMIT=${N_SPD:-$SPEEDLIMIT}
    if ! validate_uint "$SPEEDLIMIT"; then echo "测速限速必须是非负整数。"; exit 1; fi
    read -p "任务间隔秒数 [$PAUSESECOND]: " N_PAU; PAUSESECOND=${N_PAU:-$PAUSESECOND}
    if ! validate_uint "$PAUSESECOND"; then echo "任务间隔秒数必须是非负整数。"; exit 1; fi
    read -p "BotID 白名单(仅数字，留空允许所有) [$WHITELIST]: " N_WHI; WHITELIST=${N_WHI:-$WHITELIST}
    if ! validate_botid "$WHITELIST"; then echo "BotID 白名单仅允许数字，或留空。"; exit 1; fi
    
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
CONF
    chmod 600 "$CONF_FILE"
    
    echo "✅ 配置已保存并备份，正在重启服务..."
    [ "$SVC_MODE" -eq 1 ] && systemctl restart miaospeed || /etc/init.d/miaospeed restart
    ;;
  3) bash /opt/miaospeed/update.sh ;;
  4) [ "$SVC_MODE" -eq 1 ] && systemctl restart miaospeed || /etc/init.d/miaospeed restart; echo "✅ 已重启" ;;
  5) [ "$SVC_MODE" -eq 1 ] && systemctl stop miaospeed || /etc/init.d/miaospeed stop; echo "✅ 已停止" ;;
  6) tail -f /opt/miaospeed/log/miaospeed.log ;;
  7)
    if has_restart_cron; then
      crontab -l 2>/dev/null \
        | grep -v -F "/bin/systemctl restart miaospeed" \
        | grep -v -F "/etc/init.d/miaospeed restart" \
        | crontab -
      echo "✅ 定时重启已关闭。"
    else
      [ "$SVC_MODE" -eq 1 ] && CMD="30 4 * * * /bin/systemctl restart miaospeed >/dev/null 2>&1" || CMD="30 4 * * * /etc/init.d/miaospeed restart >/dev/null 2>&1"
      (crontab -l 2>/dev/null; echo "$CMD") | crontab -
      echo "✅ 已开启定时重启：每日 04:30 重启服务。"
    fi
    ;;
  8)
    read -p "确认卸载 MiaoSpeed 并删除相关文件吗? (y/N): " confirm
    if case "${confirm:-}" in y|Y|yes|YES) true ;; *) false ;; esac; then
      bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InMiSp.sh) --uninstall 2>/dev/null || echo "请加 --uninstall 手动运行。"
    fi
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x /usr/bin/miao

# ============================================================
# 9. 部署完成提示
# ============================================================
MMDB_STATUS=$(is_yes "$USE_MMDB" && echo "已启用 (/opt/miaospeed/data)" || echo "未启用")
CRON_UPDATE=$(is_yes "$ENABLE_AUTO_UPDATE" && echo "每天 04:00 自动执行" || echo "未启用，可通过 miao 手动更新")
CRON_RESTART=$(is_yes "$ENABLE_RESTART" && echo "每天 04:30 重启服务" || echo "未启用")

echo -e "\n${C_G}============================================================${C_0}"
echo -e " MiaoSpeed 部署完成"
echo -e "${C_G}============================================================${C_0}"
echo -e " ${C_B}[核心节点对接参数]${C_0}"
echo -e " - 监听端口 (PORT) : ${C_Y}${PORT}${C_0}"
echo -e " - 路径信息 (PATH) : ${C_Y}${PATH_WS}${C_0}"
echo -e " - 连接密钥 (TOKEN): ${C_Y}${TOKEN}${C_0}"
echo -e " - Bot 白名单      : ${WHITELIST:-[允许所有请求]}"
echo ""
echo -e " ${C_B}[运行参数]${C_0}"
echo -e " - 并发下发线程数  : ${CONNTHREAD}"
echo -e " - 任务队列上限    : ${TASKLIMIT}"
echo -e " - 单线程限流 (B/s): ${SPEEDLIMIT:-0 (无限制)}"
echo -e " - 任务缓冲 (秒)   : ${PAUSESECOND}"
echo -e " - GEOIP 数据库    : ${MMDB_STATUS}"
echo ""
echo -e " ${C_B}[管理与维护]${C_0}"
echo -e " - 交互控制台入口  : ${C_G}miao${C_0} (随时键入 miao 唤出主菜单)"
echo -e " - 运行日志流向    : ${LOG_DIR}/miaospeed.log"
echo -e " - 定时重启任务    : ${CRON_RESTART}"
echo -e " - 自动更新任务    : ${CRON_UPDATE}"
echo -e "${C_G}============================================================${C_0}"
echo -e " ${C_R}[!] 请确认云安全组或本机防火墙已放行 TCP 端口 ${PORT}${C_0}"
echo -e "${C_G}============================================================${C_0}"
