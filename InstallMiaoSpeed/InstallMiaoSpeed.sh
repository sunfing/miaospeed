
#!/bin/bash
# ============================================================
# MiaoSpeed 后端 一键部署 / 卸载脚本
# 支持系统: OpenWrt / Debian / Ubuntu (x86_64)
# Github: https://github.com/airportr/miaospeed
# ============================================================

INSTALL_DIR="/opt/miaospeed"
LOG_FILE="${INSTALL_DIR}/miaospeed.log"
SERVICE_NAME="miaospeed"
BIN_ORIGIN="miaospeed-linux-amd64"  # 官方下载文件
BIN_NAME="miaospeed"                # 运行文件，进程名统一为 miaospeed

# ---------- 检查 root 权限 ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请使用 root 用户执行此脚本"
  exit 1
fi

# ---------- 检查 CPU 架构 ----------
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "❌ 当前架构为 $ARCH，本脚本仅支持 x86_64"
  exit 1
fi

# ---------- 检测系统类型 ----------
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

# ---------- 卸载逻辑 ----------
if [ "$1" = "--uninstall" ]; then
  echo "====== 卸载 MiaoSpeed ======"
  
  # 停止 systemd 服务
  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    systemctl stop ${SERVICE_NAME}
    systemctl disable ${SERVICE_NAME}
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    echo "✔️ 已删除 systemd 服务"
  fi

  # 停止 procd 服务
  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/${SERVICE_NAME} stop
    /etc/init.d/${SERVICE_NAME} disable
    rm -f /etc/init.d/${SERVICE_NAME}
    echo "✔️ 已删除 procd 服务脚本"
  fi

  # 删除程序文件及日志
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "✔️ 已删除程序文件和日志"
  fi

  echo "====== MiaoSpeed 已完全卸载 ======"
  exit 0
fi

# ---------- 检查并安装依赖 ----------
echo "[1/9] 检查并安装基础依赖 (wget curl unzip)..."
if [ "$OS_TYPE" = "openwrt" ]; then
  opkg update
  opkg install wget curl unzip
elif [ "$OS_TYPE" = "debian" ]; then
  apt-get update
  apt-get install -y wget curl unzip
else
  echo "⚠️ 无法确定系统类型，请手动确认 wget curl unzip 是否已安装"
fi

# 检查 netstat 是否存在
if ! command -v netstat &>/dev/null; then
  echo "[1.1] netstat 未安装，正在安装 net-tools..."
  if [ "$OS_TYPE" = "debian" ]; then
    apt-get install -y net-tools
  else
    echo "⚠️ 请手动安装 net-tools 以便检测端口状态"
  fi
fi

# ---------- 获取 GitHub 最新版本 ----------
echo "[2/9] 获取 GitHub 最新版本..."
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)
if [ -z "$LATEST_VERSION" ]; then
  echo "⚠️ 无法获取最新版本，将使用默认版本 1.0.0"
  LATEST_VERSION="1.0.0"
fi

# ---------- 用户输入 ----------
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

read -p "是否启用 mmdb GEOIP 数据库? (y/n, 默认n): " USE_MMDB
USE_MMDB=${USE_MMDB:-n}

echo ""
echo "====== 防火墙策略选择 ======"
echo "1) 不配置防火墙（Debian/Ubuntu 请选择此项）"
echo "2) 自动放行端口 ${PORT}（仅 OpenWrt 可用）"
read -p "请选择防火墙模式 (1/2 默认1): " FIREWALL_MODE
FIREWALL_MODE=${FIREWALL_MODE:-1}

if [ "$OS_TYPE" != "openwrt" ] && [ "$FIREWALL_MODE" = "2" ]; then
  echo "⚠️ 当前系统不支持自动配置防火墙，已自动切换为模式 1"
  FIREWALL_MODE=1
fi

echo ""
echo "====== 启动管理方式选择 ======"
echo "1) procd (OpenWrt 专用)"
echo "2) systemd (标准 Linux)"
read -p "请选择服务管理方式 (1/2 默认1): " SERVICE_MODE
SERVICE_MODE=${SERVICE_MODE:-1}

echo "====== 配置完成，准备安装 ======"

# ---------- 清理旧文件 ----------
if [ -d "$INSTALL_DIR" ]; then
  echo "⚠️ 检测到已有旧安装文件，是否清理？(y/n 默认 y): "
  read CLEAN_OLD
  CLEAN_OLD=${CLEAN_OLD:-y}
  if [ "$CLEAN_OLD" = "y" ]; then
    systemctl stop ${SERVICE_NAME} 2>/dev/null
    rm -rf "$INSTALL_DIR"
    echo "旧安装文件已清理"
  fi
fi

# ---------- 创建目录 ----------
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" || exit 1

# ---------- 下载并重命名 ----------
DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${MIAOSPEED_VERSION}/${BIN_ORIGIN}-${MIAOSPEED_VERSION}.tar.gz"
echo "[3/9] 下载 MiaoSpeed ${MIAOSPEED_VERSION}..."
wget -O "${BIN_ORIGIN}.tar.gz" "${DOWNLOAD_URL}" || {
  echo "❌ 下载失败，请检查网络或版本号是否正确"
  exit 1
}

# ---------- 解压并将文件重命名为 miaospeed ----------
echo "[4/9] 解压文件..."
tar -zxvf "${BIN_ORIGIN}.tar.gz" || {
  echo "❌ 解压失败"
  exit 1
}
mv "${BIN_ORIGIN}" "${BIN_NAME}"
chmod +x "${BIN_NAME}"

# ---------- 配置防火墙 ----------
if [ "$FIREWALL_MODE" = "1" ]; then
  if [ "$OS_TYPE" = "openwrt" ]; then
    echo "[5/9] OpenWrt 自动配置防火墙规则..."
    uci add firewall rule
    uci set firewall.@rule[-1].name="MiaoSpeed_${PORT}"
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port="${PORT}"
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall restart
  else
    echo "[5/9] Debian/Ubuntu 系统无法使用 uci，请手动放行端口"
    echo "    示例命令:"
    echo "      iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT"
    echo "      iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT"
  fi
else
  echo "[5/9] 跳过自动防火墙配置，请确保端口 ${PORT} 可访问"
fi

# ---------- 构建启动命令 ----------
CMD="${INSTALL_DIR}/${BIN_NAME} server \
  -mtls \
  -verbose \
  -bind 0.0.0.0:${PORT} \
  -allowip 0.0.0.0/0 \
  -path ${PATH_WS} \
  -token ${TOKEN} \
  -connthread ${CONNTHREAD} \
  -tasklimit ${TASKLIMIT} \
  -speedlimit ${SPEEDLIMIT} \
  -pausesecond ${PAUSESECOND}"

if [ -n "$WHITELIST" ]; then
  CMD="${CMD} -whitelist ${WHITELIST}"
fi

if [ "$USE_MMDB" = "y" ] || [ "$USE_MMDB" = "Y" ]; then
  CMD="${CMD} -mmdb GeoLite2-ASN.mmdb,GeoLite2-City.mmdb"
fi

# ---------- 配置启动方式 ----------
if [ "$SERVICE_MODE" = "2" ]; then
  echo "[6/9] 创建 systemd 服务..."
  SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
  cat > "$SERVICE_FILE" <<EOF
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

elif [ "$OS_TYPE" = "openwrt" ] && [ "$SERVICE_MODE" = "1" ]; then
  echo "[6/9] 创建 procd 启动脚本..."
  cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/bin/sh /etc/rc.common
# MiaoSpeed 后端 Procd 启动脚本

START=95
STOP=10

USE_PROCD=1
PROG=${INSTALL_DIR}/${BIN_NAME}
LOG_FILE=${LOG_FILE}
PROG_ARGS="server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT}"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG \$PROG_ARGS
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file \$LOG_FILE
    procd_close_instance
}

stop_service() {
    echo "Stopping MiaoSpeed..."
}
EOF

  chmod +x /etc/init.d/${SERVICE_NAME}
  /etc/init.d/${SERVICE_NAME} enable
  /etc/init.d/${SERVICE_NAME} start
  echo "✅ 已生成 procd 启动脚本，并启用开机自启"
else
  echo "[6/9] 未选择有效启动方式，请检查配置"
fi

# ---------- 检查运行状态 ----------
echo "[7/9] 检查服务状态..."
if command -v netstat &>/dev/null; then
  netstat -tunlp | grep "${PORT}" && echo "✅ MiaoSpeed 端口 ${PORT} 正在监听"
else
  echo "⚠️ 无法检测端口状态，请手动确认 ${PORT} 是否监听中"
fi

# ---------- 完成提示 ----------
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
echo "  tail -f ${LOG_FILE}                 # 实时查看日志"
echo "  echo '' > ${LOG_FILE}               # 清空日志"

if [ "$OS_TYPE" = "debian" ]; then
  echo ""
  echo "Debian/Ubuntu 系统需手动放行端口示例:"
  echo "  iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT"
  echo "  iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT"
fi

echo ""
echo "MiaoSpeed 已部署完成 🎉"
echo ""
echo "如需卸载，请执行:"
echo "  bash <(curl -fsSL https://github.com/xxx/InstallMiaoSpeed.sh) --uninstall"
