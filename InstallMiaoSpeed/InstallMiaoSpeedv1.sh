#!/usr/bin/env bash
#================================================================
# MiaoSpeed 一键安装 / 卸载 / 更新脚本 (最小依赖版)
# 支持平台: Linux(systemd), OpenWrt(procd), FreeBSD(rc.d), macOS(launchd)
# 默认安装目录: /opt/miaospeed
# GitHub：https://github.com/sunfing
# Telegram：https://t.me/i_chl
#================================================================

set -euo pipefail

#-------------------------
# 彩色输出
#-------------------------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; PLAIN="\033[0m"
info()    { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error()   { echo -e "${RED}[ERROR]${PLAIN} $*"; exit 1; }
title()   { echo -e "\n${BLUE}== $* ==${PLAIN}\n"; }

#-------------------------
# 全局变量
#-------------------------
INSTALL_DIR="/opt/miaospeed"
BIN_DIR="$INSTALL_DIR/bin"
LINK_BIN="$INSTALL_DIR/miaospeed"
CONFIG_FILE="$INSTALL_DIR/config.env"
UPDATE_SCRIPT="$INSTALL_DIR/miaospeed-update.sh"
SERVICE_NAME="miaospeed"

#-------------------------
# 检查 root 权限
#-------------------------
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行该脚本！"

#-------------------------
# 卸载逻辑
#-------------------------
uninstall() {
    title "卸载 MiaoSpeed"

    # 停止并清理服务
    if command -v systemctl &>/dev/null; then
        systemctl stop $SERVICE_NAME || true
        systemctl disable $SERVICE_NAME || true
        rm -f /etc/systemd/system/$SERVICE_NAME.service
        systemctl daemon-reload
    elif [[ -f /etc/init.d/$SERVICE_NAME ]]; then
        /etc/init.d/$SERVICE_NAME stop || true
        rm -f /etc/init.d/$SERVICE_NAME
    elif [[ "$(uname)" == "FreeBSD" ]]; then
        service $SERVICE_NAME stop || true
        rm -f /usr/local/etc/rc.d/$SERVICE_NAME
    elif [[ "$(uname)" == "Darwin" ]]; then
        launchctl unload ~/Library/LaunchAgents/com.$SERVICE_NAME.plist || true
        rm -f ~/Library/LaunchAgents/com.$SERVICE_NAME.plist
    fi

    # 删除文件
    rm -rf "$INSTALL_DIR"

    # 删除 cron 自动更新
    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | crontab - || true

    info "MiaoSpeed 已卸载完成！"
    exit 0
}
[[ "${1:-}" == "--uninstall" ]] && uninstall

#-------------------------
# 检测系统和架构
#-------------------------
title "检测系统信息"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) error "暂不支持的架构: $ARCH" ;;
esac
info "操作系统: $OS"
info "CPU 架构: $ARCH"

#-------------------------
# 检测网络
#-------------------------
title "检测网络连通性"
ping -c1 github.com &>/dev/null || error "无法访问 GitHub，请检查网络或代理！"

#-------------------------
# 安装依赖 (多分支)
#-------------------------
title "安装必要依赖"
if [[ -f /etc/openwrt_release ]]; then
    info "检测到 OpenWrt，使用 opkg 安装依赖"
    opkg update
    opkg install curl wget tar unzip coreutils-nohup
elif command -v apt-get &>/dev/null; then
    info "检测到 Debian/Ubuntu，使用 apt-get 安装依赖"
    apt-get update -y
    apt-get install -y curl wget tar unzip cron
elif command -v yum &>/dev/null; then
    info "检测到 CentOS/AlmaLinux，使用 yum 安装依赖"
    yum install -y curl wget tar unzip cronie
elif [[ "$OS" == "freebsd" ]]; then
    info "检测到 FreeBSD，使用 pkg 安装依赖"
    pkg install -y curl wget bash
elif [[ "$OS" == "darwin" ]]; then
    info "检测到 macOS，请手动确保安装 curl (brew install curl)"
    command -v curl >/dev/null || error "请安装 curl"
fi

#-------------------------
# 获取最新版本
#-------------------------
title "获取最新版本"
LATEST_URL=$(curl -fsSLI -o /dev/null -w %{url_effective} https://github.com/AirportR/miaospeed/releases/latest)
LATEST_TAG="${LATEST_URL##*/}"
info "最新版本: $LATEST_TAG"

FILENAME="miaospeed-${OS}-${ARCH}-${LATEST_TAG}.tar.gz"
DOWNLOAD_URL="https://github.com/AirportR/miaospeed/releases/download/${LATEST_TAG}/${FILENAME}"
info "下载地址: $DOWNLOAD_URL"

#-------------------------
# 下载与安装
#-------------------------
title "安装 MiaoSpeed"
rm -rf "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

curl -L "$DOWNLOAD_URL" -o /tmp/miaospeed.tar.gz
tar -xzf /tmp/miaospeed.tar.gz -C "$BIN_DIR"
rm -f /tmp/miaospeed.tar.gz

REAL_BIN=$(find "$BIN_DIR" -type f -name "miaospeed-*-$ARCH")
ln -sf "$REAL_BIN" "$LINK_BIN"
chmod +x "$REAL_BIN" "$LINK_BIN"

info "安装目录: $INSTALL_DIR"
info "二进制文件: $REAL_BIN"
info "统一入口: $LINK_BIN"

#-------------------------
# 用户输入配置
#-------------------------
title "配置参数"
read -rp "请输入监听地址 [默认: 0.0.0.0:6699]: " BIND
BIND=${BIND:-0.0.0.0:6699}

read -rp "请输入 WebSocket 路径 [默认: /miaospeed]: " PATH
PATH=${PATH:-/miaospeed}

read -rp "请输入连接 Token [默认: defaulttoken]: " TOKEN
TOKEN=${TOKEN:-defaulttoken}

{
  echo "BIND=$BIND"
  echo "PATH=$PATH"
  echo "TOKEN=$TOKEN"
} > "$CONFIG_FILE"

info "配置已写入 $CONFIG_FILE"

#-------------------------
# 配置服务
#-------------------------
title "配置服务"
if command -v systemctl &>/dev/null; then
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=MiaoSpeed Service
After=network.target

[Service]
ExecStart=$LINK_BIN server -mtls -bind \$BIND -path \$PATH -token \$TOKEN -verbose
EnvironmentFile=$CONFIG_FILE
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
elif [[ -d /etc/init.d ]]; then
cat > /etc/init.d/$SERVICE_NAME <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
SERVICE_NAME="miaospeed"

start_service() {
    procd_open_instance
    procd_set_param command /opt/miaospeed/miaospeed server -mtls -bind $(. /opt/miaospeed/config.env; echo $BIND) -path $(. /opt/miaospeed/config.env; echo $PATH) -token $(. /opt/miaospeed/config.env; echo $TOKEN) -verbose
    procd_set_param respawn
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/$SERVICE_NAME
    /etc/init.d/$SERVICE_NAME enable
    /etc/init.d/$SERVICE_NAME start
elif [[ "$OS" == "freebsd" ]]; then
cat > /usr/local/etc/rc.d/$SERVICE_NAME <<EOF
#!/bin/sh
# PROVIDE: $SERVICE_NAME
# REQUIRE: DAEMON
# KEYWORD: shutdown

. /etc/rc.subr

name="$SERVICE_NAME"
rcvar=$name
command="$LINK_BIN"
command_args="server -mtls -bind \$(. $CONFIG_FILE; echo \$BIND) -path \$(. $CONFIG_FILE; echo \$PATH) -token \$(. $CONFIG_FILE; echo \$TOKEN) -verbose"

load_rc_config \$name
: \${miaospeed_enable:="YES"}

run_rc_command "\$1"
EOF
    chmod +x /usr/local/etc/rc.d/$SERVICE_NAME
    sysrc miaospeed_enable=YES
    service $SERVICE_NAME start
elif [[ "$OS" == "darwin" ]]; then
cat > ~/Library/LaunchAgents/com.$SERVICE_NAME.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LINK_BIN</string>
        <string>server</string>
        <string>-mtls</string>
        <string>-bind</string><string>\$(/bin/sh -c '. $CONFIG_FILE; echo \$BIND')</string>
        <string>-path</string><string>\$(/bin/sh -c '. $CONFIG_FILE; echo \$PATH')</string>
        <string>-token</string><string>\$(/bin/sh -c '. $CONFIG_FILE; echo \$TOKEN')</string>
        <string>-verbose</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    launchctl load ~/Library/LaunchAgents/com.$SERVICE_NAME.plist
fi

#-------------------------
# 自动更新脚本
#-------------------------
title "配置自动更新"
{
echo '#!/usr/bin/env bash'
echo 'set -euo pipefail'
echo 'INSTALL_DIR="/opt/miaospeed"'
echo 'BIN_DIR="$INSTALL_DIR/bin"'
echo 'LINK_BIN="$INSTALL_DIR/miaospeed"'
echo 'CONFIG_FILE="$INSTALL_DIR/config.env"'
echo 'LATEST_URL=$(curl -fsSLI -o /dev/null -w %{url_effective} https://github.com/AirportR/miaospeed/releases/latest)'
echo 'LATEST_TAG="${LATEST_URL##*/}"'
echo 'OS=$(uname -s | tr "[:upper:]" "[:lower:]")'
echo 'ARCH=$(uname -m)'
echo 'case $ARCH in'
echo '    x86_64|amd64) ARCH="amd64" ;;'
echo '    aarch64|arm64) ARCH="arm64" ;;'
echo '    armv7l) ARCH="armv7" ;;'
echo '    *) echo "Unsupported arch"; exit 1 ;;'
echo 'esac'
echo 'FILENAME="miaospeed-${OS}-${ARCH}-${LATEST_TAG}.tar.gz"'
echo 'DOWNLOAD_URL="https://github.com/AirportR/miaospeed/releases/download/${LATEST_TAG}/${FILENAME}"'
echo 'curl -L "$DOWNLOAD_URL" -o /tmp/miaospeed.tar.gz'
echo 'tar -xzf /tmp/miaospeed.tar.gz -C "$BIN_DIR"'
echo 'rm -f /tmp/miaospeed.tar.gz'
echo 'REAL_BIN=$(find "$BIN_DIR" -type f -name "miaospeed-*-$ARCH" | tail -n1)'
echo 'ln -sf "$REAL_BIN" "$LINK_BIN"'
echo 'chmod +x "$REAL_BIN" "$LINK_BIN"'
echo 'systemctl restart miaospeed 2>/dev/null || true'
echo '/etc/init.d/miaospeed restart 2>/dev/null || true'
echo 'service miaospeed restart 2>/dev/null || true'
echo 'launchctl unload ~/Library/LaunchAgents/com.miaospeed.plist 2>/dev/null || true'
echo 'launchctl load ~/Library/LaunchAgents/com.miaospeed.plist 2>/dev/null || true'
} > "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

(crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" ; echo "0 4 * * * $UPDATE_SCRIPT >/dev/null 2>&1") | crontab -

#-------------------------
# 完成提示
#-------------------------
title "安装完成"
info "服务已启动，当前配置："
cat "$CONFIG_FILE"
info "卸载命令: bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeed.sh) --uninstall"
