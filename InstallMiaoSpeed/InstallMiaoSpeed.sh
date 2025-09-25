
#!/bin/sh
# ============================================================
# MiaoSpeed 后端 一键部署脚本 (OpenWrt / Linux 通用)
# 支持架构: x86_64 专用
# Github: https://github.com/airportr/miaospeed
# ============================================================

INSTALL_DIR="/opt/miaospeed"      # 安装目录
LOG_FILE="${INSTALL_DIR}/miaospeed.log"
SERVICE_NAME="miaospeed"

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请使用 root 用户执行此脚本"
  exit 1
fi

# 检查网络连通性
if ! ping -c 1 github.com >/dev/null 2>&1; then
  echo "❌ 无法连接 GitHub，请检查网络或 DNS 设置"
  echo "建议测试命令: ping github.com"
  exit 1
fi

# 检查软件包管理器
if command -v opkg >/dev/null 2>&1; then
  PKG_MANAGER="opkg"
elif command -v apt-get >/dev/null 2>&1; then
  PKG_MANAGER="apt-get"
else
  echo "❌ 未检测到可用的软件包管理器 (opkg 或 apt-get)"
  echo "请手动安装 wget curl unzip 后重试"
  exit 1
fi

# 安装依赖，并处理安装失败情况
echo "[1/9] 检查并安装基础依赖 (wget curl unzip)..."
if [ "$PKG_MANAGER" = "opkg" ]; then
  if ! opkg update; then
    echo "❌ opkg update 失败，请检查 OpenWrt 软件源配置或网络连通性"
    echo "可参考命令: nslookup downloads.openwrt.org"
    exit 1
  fi
  opkg install wget curl unzip || {
    echo "❌ 依赖安装失败，请检查磁盘空间或软件源"
    exit 1
  }
else
  if ! apt-get update; then
    echo "❌ apt-get update 失败，请检查系统网络或 DNS 配置"
    exit 1
  fi
  apt-get install -y wget curl unzip || {
    echo "❌ 依赖安装失败，请检查磁盘空间或软件源"
    exit 1
  }
fi

# 获取 GitHub 最新版本
echo "[2/9] 获取 GitHub 最新版本..."
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep tag_name | cut -d '"' -f4)
if [ -z "$LATEST_VERSION" ]; then
  echo "⚠️ 无法获取最新版本，将使用默认版本 v1.0.0"
  LATEST_VERSION="v1.0.0"
fi

# 用户输入
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
echo "1) 自动放行端口 ${PORT}（外部可直接访问）"
echo "2) 不配置防火墙（后期通过端口转发/NAT/反代实现）"
read -p "请选择防火墙模式 (1/2 默认2): " FIREWALL_MODE
FIREWALL_MODE=${FIREWALL_MODE:-2}

echo ""
echo "====== 启动管理方式选择 ======"
echo "1) procd (OpenWrt 专用)"
echo "2) systemd (标准 Linux)"
read -p "请选择服务管理方式 (1/2 默认1): " SERVICE_MODE
SERVICE_MODE=${SERVICE_MODE:-1}

echo "====== 配置完成，准备安装 ======"

# 创建目录
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" || exit 1

# 检测架构
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "❌ 当前架构为 $ARCH，本脚本仅支持 x86_64"
  exit 1
fi

# 下载 MiaoSpeed 二进制
BIN_NAME="miaospeed-linux-amd64-${MIAOSPEED_VERSION}"
DOWNLOAD_URL="https://github.com/airportr/miaospeed/releases/download/${MIAOSPEED_VERSION}/${BIN_NAME}.tar.gz"

echo "[3/9] 下载 MiaoSpeed ${MIAOSPEED_VERSION}..."
wget -O "${BIN_NAME}.tar.gz" "${DOWNLOAD_URL}" || {
  echo "❌ 下载失败，请检查网络或版本号是否正确"
  exit 1
}

# 解压并赋权
echo "[4/9] 解压文件..."
tar -zxvf "${BIN_NAME}.tar.gz" || {
  echo "❌ 解压失败"
  exit 1
}
chmod +x "${BIN_NAME}"

# 防火墙配置
if [ "$FIREWALL_MODE" = "1" ]; then
  echo "[5/9] 配置防火墙规则，持久化放行端口 ${PORT}..."
  if command -v fw4 >/dev/null 2>&1; then
    echo "检测到 nftables (fw4)"
    uci add firewall rule
    uci set firewall.@rule[-1].name="MiaoSpeed_${PORT}"
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port="${PORT}"
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall restart
  else
    echo "检测到 iptables (fw3)"
    uci add firewall rule
    uci set firewall.@rule[-1].name="MiaoSpeed_${PORT}"
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest_port="${PORT}"
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall restart
  fi
else
  echo "[5/9] 跳过防火墙配置，后续可手动添加端口转发或 NAT"
fi

# 构建启动命令
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

# 配置 procd 或 systemd
if [ "$SERVICE_MODE" = "1" ]; then
  echo "[6/9] 创建 procd 启动脚本..."
  INIT_FILE="/etc/init.d/${SERVICE_NAME}"
  cat > "$INIT_FILE" <<EOF
#!/bin/sh /etc/rc.common
# MiaoSpeed Procd Service
START=95
STOP=10

USE_PROCD=1
PROG="${CMD}"
SERVICE_DAEMONIZE=1
SERVICE_WRITE_PID=1
PID_FILE=/var/run/${SERVICE_NAME}.pid

start_service() {
    procd_open_instance
    procd_set_param command ${CMD}
    procd_set_param respawn
    procd_close_instance
}
EOF
  chmod +x "$INIT_FILE"
  /etc/init.d/${SERVICE_NAME} enable
  /etc/init.d/${SERVICE_NAME} start
else
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
  systemctl start ${SERVICE_NAME}
fi

sleep 2

# 检查运行状态
echo "[7/9] 检查服务状态..."
netstat -tulnp | grep "${PORT}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "✅ MiaoSpeed 启动成功!"
  echo "访问地址: ws://<公网IP或域名>:${PORT}${PATH_WS}"
else
  echo "❌ 启动失败，请检查日志: ${LOG_FILE}"
fi

# 完成提示
echo ""
echo "====== 部署完成 ======"
echo "服务管理:"
if [ "$SERVICE_MODE" = "1" ]; then
  echo "  重启服务: /etc/init.d/${SERVICE_NAME} restart"
  echo "  停止服务: /etc/init.d/${SERVICE_NAME} stop"
  echo "  查看状态: /etc/init.d/${SERVICE_NAME} status"
else
  echo "  重启服务: systemctl restart ${SERVICE_NAME}"
  echo "  停止服务: systemctl stop ${SERVICE_NAME}"
  echo "  查看状态: systemctl status ${SERVICE_NAME}"
fi

echo ""
echo "日志管理:"
echo "  查看日志: tail -f ${LOG_FILE}"
echo "  清理日志: echo '' > ${LOG_FILE}"

echo ""
echo "防火墙/端口转发提示:"
echo "  如果选择了模式 2，可通过以下方式配置端口转发:"
echo "  OpenWrt Web 界面: 网络 -> 防火墙 -> 端口转发"
echo "  或使用 UCI 命令行配置:"
echo "    uci add firewall redirect"
echo "    uci set firewall.@redirect[-1].src='wan'"
echo "    uci set firewall.@redirect[-1].src_dport='6699'"
echo "    uci set firewall.@redirect[-1].dest_ip='192.168.1.100'"
echo "    uci set firewall.@redirect[-1].dest_port='6699'"
echo "    uci set firewall.@redirect[-1].proto='tcp udp'"
echo "    uci commit firewall && /etc/init.d/firewall restart"
