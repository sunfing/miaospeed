#!/bin/bash
# ============================================================
# MiaoSpeed 测试后端 一键部署/卸载/自动更新
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# GitHub：https://github.com/sunfing
# Telegram：https://t.me/i_chl
# ============================================================

INSTALL_DIR="/opt/miaospeed"
LOG_FILE="${INSTALL_DIR}/miaospeed.log"
SERVICE_NAME="miaospeed"
BIN_NAME=""

# 彩色输出函数
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

# ============================================================
# 检查 root 权限
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 用户执行此脚本"
  exit 1
fi

# ============================================================
# 卸载流程
# ============================================================
if [ "$1" = "--uninstall" ]; then
  say "卸载 MiaoSpeed"

  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    systemctl stop ${SERVICE_NAME}
    systemctl disable ${SERVICE_NAME}
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    ok "已删除 systemd 服务"
  fi

  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/${SERVICE_NAME} stop
    /etc/init.d/${SERVICE_NAME} disable
    rm -f /etc/init.d/${SERVICE_NAME}
    ok "已删除 procd 启动脚本"
  fi

  OLD_PID=$(pgrep -f "${SERVICE_NAME}")
  if [ -n "$OLD_PID" ]; then
    kill -9 $OLD_PID
    ok "已终止进程 PID: $OLD_PID"
  fi

  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "已删除目录 $INSTALL_DIR"
  fi

  crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/miaospeedupdate.sh" | crontab -
  ok "已清理自动更新定时任务"

  ok "MiaoSpeed 已完全卸载"
  exit 0
fi

# ============================================================
# 检测系统类型、架构
# ============================================================
say "检测系统类型、架构"
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
  x86_64) BIN_NAME="miaospeed-linux-amd64" ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64" ;;
  *) err "当前架构 $ARCH 不受支持"; exit 1 ;;
esac

ok "系统类型: $OS_TYPE"
ok "架构: $ARCH, 使用二进制: $BIN_NAME"

# ============================================================
# 安装依赖
# ============================================================
say "检查并安装依赖"
if [ "$OS_TYPE" = "openwrt" ]; then
  opkg update && opkg install wget curl unzip && ok "依赖已安装"
elif [ "$OS_TYPE" = "debian" ]; then
  apt-get update && apt-get install -y wget curl unzip net-tools cron && ok "依赖已安装"
else
  warn "无法确定系统类型，请手动确认依赖已安装"
fi

# ============================================================
# 获取 GitHub 最新版本
# ============================================================
say "获取 GitHub 最新版本"
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)
if [ -z "$LATEST_VERSION" ]; then
  warn "无法获取最新版本，将使用默认版本 4.6.1"
  LATEST_VERSION="4.6.1"
else
  ok "检测到最新版本: $LATEST_VERSION"
fi

# ============================================================
# 用户输入配置
# ============================================================
say "配置参数"
read -p "请输入 MiaoSpeed 版本号 (默认: ${LATEST_VERSION}): " MIAOSPEED_VERSION
MIAOSPEED_VERSION=${MIAOSPEED_VERSION:-$LATEST_VERSION}
read -p "请输入监听端口 (默认: 6699): " PORT; PORT=${PORT:-6699}
read -p "请输入 WebSocket Path (默认: /miaospeed): " PATH_WS; PATH_WS=${PATH_WS:-/miaospeed}
[[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"
read -p "请输入后端连接 Token (默认: defaulttoken): " TOKEN; TOKEN=${TOKEN:-defaulttoken}
read -p "请输入 BotID 白名单 (为空允许所有): " WHITELIST; WHITELIST=${WHITELIST:-""}
read -p "请输入最大并发连接数 (默认: 64): " CONNTHREAD; CONNTHREAD=${CONNTHREAD:-64}
read -p "请输入最大任务队列 (默认: 150): " TASKLIMIT; TASKLIMIT=${TASKLIMIT:-150}
read -p "请输入测速限速 (字节/秒, 默认: 0): " SPEEDLIMIT; SPEEDLIMIT=${SPEEDLIMIT:-0}
read -p "请输入任务间隔秒数 (默认: 0): " PAUSESECOND; PAUSESECOND=${PAUSESECOND:-0}
read -p "是否启用 mmdb GEOIP 数据库? (y/n 默认: n): " USE_MMDB; USE_MMDB=${USE_MMDB:-n}
ok "参数设置完成"

say "选择启动管理方式"
echo "1) systemd (标准 Linux)"
echo "2) procd (OpenWrt 专用)"
read -p "请选择服务管理方式 (1/2 默认: 1): " SERVICE_MODE; SERVICE_MODE=${SERVICE_MODE:-1}
ok "服务管理方式: $SERVICE_MODE"

# ============================================================
# 清理旧安装文件
# ============================================================
say "清理旧安装文件"
if [ -d "$INSTALL_DIR" ]; then
  read -p "检测到已有旧安装文件，是否清理？(y/n 默认: y): " CLEAN_OLD
  CLEAN_OLD=${CLEAN_OLD:-y}
  if [ "$CLEAN_OLD" = "y" ]; then
    systemctl stop miaospeed 2>/dev/null
    rm -rf "$INSTALL_DIR"
    ok "旧安装文件已清理"
  fi
else
  say "无旧安装文件，继续安装"
fi

# ============================================================
# 下载并安装
# ============================================================
say "下载并安装 MiaoSpeed"
mkdir -p "${INSTALL_DIR}" && cd "${INSTALL_DIR}" || exit 1
DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${MIAOSPEED_VERSION}/${BIN_NAME}-${MIAOSPEED_VERSION}.tar.gz"
say "下载版本 ${MIAOSPEED_VERSION}..."
wget -O "${BIN_NAME}.tar.gz" "${DOWNLOAD_URL}" || { err "下载失败"; exit 1; }
say "解压文件..."
tar -zxvf "${BIN_NAME}.tar.gz"
mv "${BIN_NAME}" "miaospeed"
rm -f "${BIN_NAME}.tar.gz"
chmod +x "miaospeed"
ok "安装完成"

# ============================================================
# 配置启动管理
# ============================================================
say "配置启动管理"
CMD="${INSTALL_DIR}/miaospeed server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"
[ -n "$WHITELIST" ] && CMD="${CMD} -whitelist ${WHITELIST}"
[[ "$USE_MMDB" =~ [yY] ]] && CMD="${CMD} -mmdb GeoLite2-ASN.mmdb,GeoLite2-City.mmdb"

if [ "$SERVICE_MODE" = "1" ]; then
  say "创建 systemd 服务..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=MiaoSpeed Backend Service
After=network.target

[Service]
Type=simple
ExecStart=$CMD
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$INSTALL_DIR/miaospeed-error.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
else
  say "创建 procd 启动脚本..."
  cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PROG=${INSTALL_DIR}/miaospeed
LOG_FILE=${LOG_FILE}
PROG_ARGS="server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG \$PROG_ARGS
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file \$LOG_FILE
    procd_close_instance
}
restart() {
    stop
    start
}
EOF
  chmod +x /etc/init.d/${SERVICE_NAME}
  /etc/init.d/${SERVICE_NAME} enable
  /etc/init.d/${SERVICE_NAME} start
fi

# ============================================================
# 生成自动更新脚本
# ============================================================
say "生成自动更新脚本"
UPDATE_SCRIPT="${INSTALL_DIR}/miaospeedupdate.sh"

cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/sh
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

INSTALL_DIR="/opt/miaospeed"
BIN_FILE="${INSTALL_DIR}/miaospeed"
SERVICE_NAME="miaospeed"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64" ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64" ;;
  *) err "架构 $ARCH 不受支持"; exit 1 ;;
esac

CURRENT_VERSION=$($BIN_FILE -version 2>/dev/null | grep '^version:' | awk '{print $2}')
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)

if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  say "检测到新版本 $LATEST_VERSION，当前版本 $CURRENT_VERSION，开始更新..."
  wget -O "${INSTALL_DIR}/miaospeed-new.tar.gz" \
    "https://github.com/airportr/miaospeed/releases/download/${LATEST_VERSION}/${BIN_NAME}-${LATEST_VERSION}.tar.gz"
  cd $INSTALL_DIR
  tar -zxvf miaospeed-new.tar.gz
  mv ${BIN_NAME} miaospeed
  chmod +x miaospeed
  rm -f miaospeed-new.tar.gz

  if command -v systemctl &>/dev/null; then
    systemctl restart $SERVICE_NAME
  else
    /etc/init.d/$SERVICE_NAME restart
  fi

  ok "MiaoSpeed 已更新至 $LATEST_VERSION 并重启完成"
else
  ok "当前已是最新版本 $CURRENT_VERSION，无需更新"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# ============================================================
# 自动更新配置
# ============================================================
say "配置自动更新"
read -p "是否启用无人值守每日凌晨 4 点自动更新？(y/n 默认: y): " ENABLE_AUTO_UPDATE
ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE:-y}
if [[ "$ENABLE_AUTO_UPDATE" =~ [yY] ]]; then
  CRON_JOB="0 4 * * * ${UPDATE_SCRIPT} >> ${INSTALL_DIR}/miaospeed-update.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT"; echo "$CRON_JOB") | crontab -
  ok "已启用无人值守自动更新"
else
  warn "已跳过自动更新"
fi

# ============================================================
# 检查服务状态
# ============================================================
say "检查服务状态"
if command -v netstat &>/dev/null; then
  netstat -tunlp | grep "${PORT}" && ok "端口 ${PORT} 正在监听"
else
  warn "无法检测端口状态，请手动确认"
fi

# ============================================================
# 完成提示
# ============================================================
say "部署完成"
ok "服务管理命令:"
if [ "$SERVICE_MODE" = "1" ]; then
  echo "  systemctl restart ${SERVICE_NAME} # 重启服务"
  echo "  systemctl stop ${SERVICE_NAME}    # 停止服务"
  echo "  systemctl status ${SERVICE_NAME}  # 查看状态"
else
  echo "  /etc/init.d/${SERVICE_NAME} restart # 重启服务"
  echo "  /etc/init.d/${SERVICE_NAME} stop    # 停止服务"
  echo "  /etc/init.d/${SERVICE_NAME} status  # 查看状态"
fi

ok "日志管理:"
echo "  tail -f ${LOG_FILE}   # 实时查看运行日志"
echo "  echo '' > ${LOG_FILE} # 清空运行日志"

ok "部署参数:"
echo "  监听端口: ${PORT}"
echo "  WebSocket Path: ${PATH_WS}"
echo "  连接 Token: ${TOKEN}"

ok "🎉 MiaoSpeed 已部署完成 🎉"
echo "卸载命令:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeed.sh) --uninstall"
