
#!/bin/bash
# ============================================================
# MiaoSpeed 后端 一键部署/卸载/自动更新
# 支持系统: OpenWrt / Debian / Ubuntu (x86_64)
# GitHub：https://github.com/sunfing
# Telegram：https://t.me/i_chl
# ============================================================

INSTALL_DIR="/opt/miaospeed"
LOG_FILE="${INSTALL_DIR}/miaospeed.log"
SERVICE_NAME="miaospeed"
BIN_NAME="miaospeed-linux-amd64" # 下载后会重命名为 miaospeed

# ============================================================
# 0. 检查 root 权限
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请使用 root 用户执行此脚本"
  exit 1
fi

# ============================================================
# 1. 检查是否执行卸载
# ============================================================
if [ "$1" = "--uninstall" ]; then
  echo "====== 卸载 MiaoSpeed ======"

  # 停止并删除 systemd 服务
  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    systemctl stop ${SERVICE_NAME}
    systemctl disable ${SERVICE_NAME}
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    echo "✔️ 已删除 systemd 服务"
  fi

  # 停止并删除 OpenWrt procd 服务
  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/${SERVICE_NAME} stop
    /etc/init.d/${SERVICE_NAME} disable
    rm -f /etc/init.d/${SERVICE_NAME}
    echo "✔️ 已删除 procd 启动脚本"
  fi

  # 杀掉残留进程
  OLD_PID=$(pgrep -f "${SERVICE_NAME}")
  if [ -n "$OLD_PID" ]; then
    kill -9 $OLD_PID
    echo "✔️ 已终止进程 PID: $OLD_PID"
  fi

  # 删除程序目录
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "✔️ 已删除目录 $INSTALL_DIR"
  fi

  # 删除自动更新任务
  crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab -
  echo "✔️ 已清理自动更新定时任务"

  echo "====== MiaoSpeed 已完全卸载 ======"
  exit 0
fi

# ============================================================
# 2. 检查 CPU 架构
# ============================================================
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "❌ 当前架构为 $ARCH，本脚本仅支持 x86_64"
  exit 1
fi

# ============================================================
# 3. 检测系统类型
# ============================================================
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
echo "检测到系统类型: $OS_TYPE"

# ============================================================
# 4. 安装依赖
# ============================================================
echo "[1/9] 检查并安装基础依赖 (wget curl unzip)..."
if [ "$OS_TYPE" = "openwrt" ]; then
  opkg update
  opkg install wget curl unzip
elif [ "$OS_TYPE" = "debian" ]; then
  apt-get update
  apt-get install -y wget curl unzip net-tools cron
else
  echo "⚠️ 无法确定系统类型，请手动确认依赖已安装"
fi

# ============================================================
# 5. 获取 GitHub 最新版本
# ============================================================
echo "[2/9] 获取 GitHub 最新版本..."
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)
if [ -z "$LATEST_VERSION" ]; then
  echo "⚠️ 无法获取最新版本，将使用默认版本 1.0.0"
  LATEST_VERSION="1.0.0"
fi

# ============================================================
# 6. 用户输入配置
# ============================================================
echo "====== MiaoSpeed 后端部署 ======"
read -p "请输入 MiaoSpeed 版本号 (默认: ${LATEST_VERSION}): " MIAOSPEED_VERSION
MIAOSPEED_VERSION=${MIAOSPEED_VERSION:-$LATEST_VERSION}

read -p "请输入监听端口 (默认: 6699): " PORT
PORT=${PORT:-6699}

read -p "请输入 WebSocket Path (示例: /abc123xyz): " PATH_WS
PATH_WS=${PATH_WS:-/miaospeed}

read -p "请输入后端连接 Token: " TOKEN
TOKEN=${TOKEN:-defaultToken123}

read -p "请输入 BotID 白名单(逗号分隔, 为空允许所有): " WHITELIST
WHITELIST=${WHITELIST:-""}

read -p "请输入最大并发连接数 (默认: 64): " CONNTHREAD
CONNTHREAD=${CONNTHREAD:-64}

read -p "请输入最大任务队列 (默认: 150): " TASKLIMIT
TASKLIMIT=${TASKLIMIT:-150}

read -p "请输入测速限速，单位字节/秒 (默认: 0 表示无限制): " SPEEDLIMIT
SPEEDLIMIT=${SPEEDLIMIT:-0}

read -p "请输入任务间隔秒数 (默认: 0 表示无间隔): " PAUSESECOND
PAUSESECOND=${PAUSESECOND:-0}

read -p "是否启用 mmdb GEOIP 数据库? (y/n 默认: n): " USE_MMDB
USE_MMDB=${USE_MMDB:-n}

echo ""
echo "====== 启动管理方式选择 ======"
echo "1) procd (OpenWrt 专用)"
echo "2) systemd (标准 Linux)"
read -p "请选择服务管理方式 (1/2 默认: 1): " SERVICE_MODE
SERVICE_MODE=${SERVICE_MODE:-1}

# ============================================================
# 7. 清理旧安装文件
# ============================================================
if [ -d "$INSTALL_DIR" ]; then
  echo "⚠️ 检测到已有旧安装文件，是否清理？(y/n 默认: y): "
  read CLEAN_OLD
  CLEAN_OLD=${CLEAN_OLD:-y}
  if [ "$CLEAN_OLD" = "y" ]; then
    systemctl stop miaospeed 2>/dev/null
    rm -rf "$INSTALL_DIR"
    echo "✔️ 旧安装文件已清理"
  fi
fi

# ============================================================
# 8. 下载并安装 MiaoSpeed
# ============================================================
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" || exit 1

DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${MIAOSPEED_VERSION}/${BIN_NAME}-${MIAOSPEED_VERSION}.tar.gz"
echo "[3/9] 下载 MiaoSpeed ${MIAOSPEED_VERSION}..."
wget -O "${BIN_NAME}.tar.gz" "${DOWNLOAD_URL}" || {
  echo "❌ 下载失败，请检查网络或版本号是否正确"
  exit 1
}

echo "[4/9] 解压文件..."
tar -zxvf "${BIN_NAME}.tar.gz"
mv "${BIN_NAME}" "miaospeed"
chmod +x "miaospeed"

# ============================================================
# 9. 配置启动管理
# ============================================================
CMD="${INSTALL_DIR}/miaospeed server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"
if [ -n "$WHITELIST" ]; then
  CMD="${CMD} -whitelist ${WHITELIST}"
fi
if [ "$USE_MMDB" = "y" ] || [ "$USE_MMDB" = "Y" ]; then
  CMD="${CMD} -mmdb GeoLite2-ASN.mmdb,GeoLite2-City.mmdb"
fi

# ---------- systemd ----------
if [ "$SERVICE_MODE" = "2" ]; then
  echo "[5/9] 创建 systemd 服务..."
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

# ---------- OpenWrt procd ----------
else
  echo "[5/9] 创建 procd 启动脚本..."
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
EOF
  chmod +x /etc/init.d/${SERVICE_NAME}
  /etc/init.d/${SERVICE_NAME} enable
  /etc/init.d/${SERVICE_NAME} start
fi

# ============================================================
# 10. 生成自动更新脚本
# ============================================================
echo "[6/9] 生成自动更新脚本..."
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"

cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/sh
INSTALL_DIR="/opt/miaospeed"
BIN_FILE="${INSTALL_DIR}/miaospeed"
SERVICE_NAME="miaospeed"

CURRENT_VERSION=$($BIN_FILE -v | grep "MiaoSpeed version" | awk '{print $3}')
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)

if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
  echo "检测到新版本 $LATEST_VERSION，当前版本 $CURRENT_VERSION，开始更新..."

  wget -O "${INSTALL_DIR}/miaospeed-new.tar.gz" \
    "https://github.com/airportr/miaospeed/releases/download/${LATEST_VERSION}/miaospeed-linux-amd64-${LATEST_VERSION}.tar.gz"

  cd $INSTALL_DIR
  tar -zxvf miaospeed-new.tar.gz
  mv miaospeed-linux-amd64 miaospeed
  chmod +x miaospeed
  rm -f miaospeed-new.tar.gz

  if command -v systemctl &>/dev/null; then
    systemctl restart $SERVICE_NAME
  else
    /etc/init.d/$SERVICE_NAME restart
  fi

  echo "✅ MiaoSpeed 已更新至 $LATEST_VERSION 并重启完成"
else
  echo "当前已是最新版本 $CURRENT_VERSION，无需更新"
fi
EOF
chmod +x "$UPDATE_SCRIPT"

# ============================================================
# 11. 询问是否启用无人值守自动更新
# ============================================================
echo ""
echo "====== 自动更新配置 ======"
read -p "是否启用无人值守每日凌晨 4 点自动更新 MiaoSpeed？(y/n 默认: n): " ENABLE_AUTO_UPDATE
ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE:-n}

if [ "$ENABLE_AUTO_UPDATE" = "y" ] || [ "$ENABLE_AUTO_UPDATE" = "Y" ]; then
  CRON_JOB="0 4 * * * ${UPDATE_SCRIPT} >> ${INSTALL_DIR}/update.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT"; echo "$CRON_JOB") | crontab -
  echo "✅ 已启用无人值守自动更新任务"
  echo "每天凌晨 4 点会自动检测并更新 MiaoSpeed"
  echo "日志文件: ${INSTALL_DIR}/update.log"
else
  echo "ℹ️ 已跳过无人值守自动更新，如需手动启用，可运行 crontab -e 添加："
  echo "    0 4 * * * ${UPDATE_SCRIPT} >> ${INSTALL_DIR}/update.log 2>&1"
fi

# ============================================================
# 12. 检查服务状态
# ============================================================
echo "[7/9] 检查服务状态..."
if command -v netstat &>/dev/null; 键，然后
  netstat -tunlp | grep "${PORT}" && echo "✅ MiaoSpeed 端口 ${PORT} 正在监听"
else
  echo "⚠️ 无法检测端口状态，请手动确认 ${PORT} 是否监听中"
fi

# ============================================================
# 13. 完成提示
# ============================================================
echo ""
echo "====== 部署完成 ======"
echo "服务管理命令:"
if [ "$SERVICE_MODE" = "2" ]; then
  echo "  systemctl restart ${SERVICE_NAME}   # 重启服务"
  echo "  systemctl stop ${SERVICE_NAME}      # 停止服务"
  echo "  systemctl status ${SERVICE_NAME}    # 查看状态"
else
  echo "  /etc/init.d/${SERVICE_NAME} restart # 重启服务 (OpenWrt)"
  echo "  /etc/init.d/${SERVICE_NAME} stop    # 停止服务 (OpenWrt)"
fi

echo ""
echo "日志管理:"
echo "  tail -f ${LOG_FILE}                 # 实时查看运行日志"
echo "  echo '' > ${LOG_FILE}               # 清空运行日志"
echo ""
echo "更新日志:"
echo "  tail -f ${INSTALL_DIR}/update.log   # 实时查看更新日志"
echo ""
echo "MiaoSpeed 已部署完成 🎉"
echo ""
echo "如需卸载，请执行:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeed.sh) --uninstall"
