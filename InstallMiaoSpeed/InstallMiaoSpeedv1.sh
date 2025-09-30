#!/usr/bin/env bash
#================================================================
# MiaoSpeed 一键安装 / 卸载 / 更新脚本 (最小依赖版，无 cat/head/md5sum/cut)
# 支持平台: Linux(systemd), OpenWrt(procd), FreeBSD(rc.d), macOS(launchd)
# 默认安装目录: /opt/miaospeed
#================================================================

set -euo pipefail

# ------------------------
# 彩色输出
# ------------------------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; PLAIN="\033[0m"
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*"; exit 1; }
title() { echo -e "\n${BLUE}== $* ==${PLAIN}\n"; }

# ------------------------
# 全局变量
# ------------------------
INSTALL_DIR="/opt/miaospeed"
BIN_DIR="$INSTALL_DIR/bin"
LINK_BIN="$INSTALL_DIR/miaospeed"
CONFIG_FILE="$INSTALL_DIR/config.env"
UPDATE_SCRIPT="$INSTALL_DIR/miaospeed-update.sh"
SERVICE_NAME="miaospeed"
LOG_FILE="$INSTALL_DIR/miaospeed.log"
ERR_LOG_FILE="$INSTALL_DIR/miaospeed-error.log"

# ------------------------
# 检查 root
# ------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  error "请使用 root 运行该脚本！"
fi

# ------------------------
# 卸载逻辑（彻底清理：服务 + 安装目录 + 自动更新任务）
# ------------------------
uninstall() {
  title "卸载 MiaoSpeed"

  # 停止并清理服务
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
  fi

  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    "/etc/init.d/${SERVICE_NAME}" stop 2>/dev/null || true
    "/etc/init.d/${SERVICE_NAME}" disable 2>/dev/null || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi

  if [ -f "/usr/local/etc/rc.d/${SERVICE_NAME}" ]; then
    service "$SERVICE_NAME" onestop 2>/dev/null || true
    rm -f "/usr/local/etc/rc.d/${SERVICE_NAME}"
    command -v sysrc >/dev/null 2>&1 && sysrc -x "${SERVICE_NAME}_enable" 2>/dev/null || true
  fi

  if [ -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist" ]; then
    launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" 2>/dev/null || true
    rm -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
  fi

  # 删除安装目录
  rm -rf "$INSTALL_DIR"

  # 删除自动更新 crontab
  crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | crontab - 2>/dev/null || true

  info "卸载完成（服务文件、安装目录、自动更新任务均已清理）。"
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

# ------------------------
# 检测系统 & 架构
# ------------------------
title "检测系统信息"
OS_KERNEL="$(uname -s)"
OS="$(printf '%s' "$OS_KERNEL" | tr '[:upper:]' '[:lower:]')"
ARCH_UNAME="$(uname -m)"
case "$ARCH_UNAME" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  *) error "暂不支持的架构: $ARCH_UNAME" ;;
esac
info "操作系统: $OS_KERNEL"
info "CPU 架构: $ARCH_UNAME -> $ARCH"

# ------------------------
# 检测网络
# ------------------------
title "检测网络连通性"
if ! curl -sSf --connect-timeout 8 https://github.com >/dev/null; then
  error "无法连通 https://github.com，请检查网络或代理！"
fi

# ------------------------
# 安装依赖（多分支：OpenWrt/apt/yum/pkg/brew）
# ------------------------
title "安装必要依赖"
if [ -f /etc/openwrt_release ]; then
  info "检测到 OpenWrt，使用 opkg 安装依赖"
  opkg update
  opkg install curl wget tar unzip coreutils-nohup 2>/dev/null || true
elif command -v apt-get >/dev/null 2>&1; then
  info "检测到 Debian/Ubuntu，使用 apt-get 安装依赖"
  apt-get update -y
  apt-get install -y curl wget tar unzip cron
elif command -v yum >/dev/null 2>&1; then
  info "检测到 CentOS/AlmaLinux，使用 yum 安装依赖"
  yum install -y curl wget tar unzip cronie
elif [ "$OS" = "freebsd" ]; then
  info "检测到 FreeBSD，使用 pkg 安装依赖"
  pkg install -y curl wget bash
elif [ "$OS" = "darwin" ]; then
  info "检测到 macOS，请确保安装 curl（可用 Homebrew：brew install curl）"
  command -v curl >/dev/null || error "未检测到 curl"
else
  warn "未知系统，请自行确保 curl/wget/tar/unzip/cron 可用。"
fi

# ------------------------
# 获取 GitHub 最新版本
# ------------------------
title "获取最新版本"
LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/AirportR/miaospeed/releases/latest)"
LATEST_TAG="${LATEST_URL##*/}"
[ -z "$LATEST_TAG" ] && error "无法解析最新版本号"
info "最新版本: $LATEST_TAG"

FILENAME="miaospeed-${OS}-${ARCH}-${LATEST_TAG}.tar.gz"
DOWNLOAD_URL="https://github.com/AirportR/miaospeed/releases/download/${LATEST_TAG}/${FILENAME}"
info "下载地址: $DOWNLOAD_URL"

# ------------------------
# 下载与安装
# ------------------------
title "安装 MiaoSpeed"
rm -rf "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

curl -fL "$DOWNLOAD_URL" -o /tmp/miaospeed.tar.gz
tar -xzf /tmp/miaospeed.tar.gz -C "$BIN_DIR"
rm -f /tmp/miaospeed.tar.gz

# 通过通配符选择第一个匹配的二进制（避免使用 head/find）
REAL_BIN=""
for f in "$BIN_DIR"/miaospeed-*-"$ARCH"; do
  [ -f "$f" ] || continue
  REAL_BIN="$f"
  break
done
[ -n "$REAL_BIN" ] || error "未找到解压后的二进制（期望: miaospeed-*-$ARCH）"

ln -sf "$REAL_BIN" "$LINK_BIN"
chmod +x "$REAL_BIN" "$LINK_BIN"

info "安装目录: $INSTALL_DIR"
info "二进制文件: $REAL_BIN"
info "统一入口: $LINK_BIN"

# ------------------------
# 用户输入配置（默认：/miaospeed & defaulttoken）
# ------------------------
title "配置参数"
read -rp "请输入监听地址 [默认: 0.0.0.0:6699]: " BIND
BIND="${BIND:-0.0.0.0:6699}"

read -rp "请输入 WebSocket 路径 [默认: /miaospeed]: " PATH_WS
PATH_WS="${PATH_WS:-/miaospeed}"

read -rp "请输入连接 Token [默认: defaulttoken]: " TOKEN
TOKEN="${TOKEN:-defaulttoken}"

# 写配置文件（仅用 echo + 重定向）
{
  echo "BIND=$BIND"
  echo "PATH=$PATH_WS"
  echo "TOKEN=$TOKEN"
} > "$CONFIG_FILE"
info "配置已写入 $CONFIG_FILE"

# 组装最终启动命令（供部分平台使用）
CMD="$LINK_BIN server -mtls -verbose -bind $BIND -path $PATH_WS -token $TOKEN"

# ------------------------
# 配置服务（systemd / procd / rc.d / launchd）
# ------------------------
title "配置服务"

if command -v systemctl >/dev/null 2>&1; then
  # systemd
  {
    echo "[Unit]"
    echo "Description=MiaoSpeed Service"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo ""
    echo "[Service]"
    echo "Type=simple"
    echo "ExecStart=$LINK_BIN server -mtls -bind \$BIND -path \$PATH -token \$TOKEN -verbose"
    echo "EnvironmentFile=$CONFIG_FILE"
    echo "WorkingDirectory=$INSTALL_DIR"
    echo "Restart=always"
    echo "RestartSec=5"
    echo "StandardOutput=append:$LOG_FILE"
    echo "StandardError=append:$ERR_LOG_FILE"
    echo "LimitNOFILE=1048576"
    echo ""
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } > "/etc/systemd/system/${SERVICE_NAME}.service"

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"

elif [ -d /etc/init.d ]; then
  # OpenWrt procd（使用单引号保留 \$ 以便运行时展开）
  {
    echo '#!/bin/sh /etc/rc.common'
    echo 'START=99'
    echo 'USE_PROCD=1'
    echo 'SERVICE_NAME="miaospeed"'
    echo ''
    echo 'start_service() {'
    echo '  procd_open_instance'
    echo '  procd_set_param command /opt/miaospeed/miaospeed server -mtls -bind $(. /opt/miaospeed/config.env; echo $BIND) -path $(. /opt/miaospeed/config.env; echo $PATH) -token $(. /opt/miaospeed/config.env; echo $TOKEN) -verbose'
    echo '  procd_set_param respawn'
    echo '  procd_set_param stdout 1'
    echo '  procd_set_param stderr 1'
    echo '  procd_close_instance'
    echo '}'
  } > "/etc/init.d/${SERVICE_NAME}"
  chmod +x "/etc/init.d/${SERVICE_NAME}"
  "/etc/init.d/${SERVICE_NAME}" enable
  "/etc/init.d/${SERVICE_NAME}" restart

elif [ "$OS" = "freebsd" ]; then
  # FreeBSD rc.d（直接写入展开后的 $CMD）
  {
    echo '#!/bin/sh'
    echo '# PROVIDE: miaospeed'
    echo '# REQUIRE: NETWORKING'
    echo '# KEYWORD: shutdown'
    echo ''
    echo '. /etc/rc.subr'
    echo 'name="miaospeed"'
    echo 'rcvar=miaospeed_enable'
    echo 'load_rc_config $name'
    echo ': ${miaospeed_enable:="YES"}'
    echo ': ${miaospeed_user:="root"}'
    echo "pidfile=\"/var/run/\${name}.pid\""
    echo 'command="/usr/sbin/daemon"'
    echo "command_args=\"-p \${pidfile} -f $CMD\""
    echo ''
    echo 'run_rc_command "$1"'
  } > "/usr/local/etc/rc.d/${SERVICE_NAME}"
  chmod +x "/usr/local/etc/rc.d/${SERVICE_NAME}"
  command -v sysrc >/dev/null 2>&1 && sysrc "${SERVICE_NAME}_enable=YES" || true
  service "$SERVICE_NAME" restart

elif [ "$OS" = "darwin" ]; then
  # macOS launchd（运行时从 config.env 取值）
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "  <key>Label</key><string>${SERVICE_NAME}</string>"
    echo '  <key>ProgramArguments</key>'
    echo '  <array>'
    echo "    <string>$LINK_BIN</string>"
    echo '    <string>server</string>'
    echo '    <string>-mtls</string>'
    echo '    <string>-bind</string><string>$(/bin/sh -c ". '"$CONFIG_FILE"' ; echo $BIND")</string>'
    echo '    <string>-path</string><string>$(/bin/sh -c ". '"$CONFIG_FILE"' ; echo $PATH")</string>'
    echo '    <string>-token</string><string>$(/bin/sh -c ". '"$CONFIG_FILE"' ; echo $TOKEN")</string>'
    echo '    <string>-verbose</string>'
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo "  <key>StandardOutPath</key><string>$LOG_FILE</string>"
    echo "  <key>StandardErrorPath</key><string>$ERR_LOG_FILE</string>"
    echo '</dict>'
    echo '</plist>'
  } > "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
  launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" 2>/dev/null || true
  launchctl load  "/Library/LaunchDaemons/${SERVICE_NAME}.plist"

else
  warn "未知的服务管理器：未创建守护进程服务，已跳过此步骤。"
  # 无服务管理器时，前台启动（作为兜底，不建议长期使用）
  nohup $CMD >>"$LOG_FILE" 2>>"$ERR_LOG_FILE" &
fi

# ------------------------
# 生成自动更新脚本（同样不使用 cat/head/cut 等）
# ------------------------
title "配置自动更新"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'INSTALL_DIR="/opt/miaospeed"'
  echo 'BIN_DIR="$INSTALL_DIR/bin"'
  echo 'LINK_BIN="$INSTALL_DIR/miaospeed"'
  echo 'SERVICE_NAME="miaospeed"'
  echo ''
  echo 'LATEST_URL="$(curl -fsSLI -o /dev/null -w "%{url_effective}" https://github.com/AirportR/miaospeed/releases/latest)"'
  echo 'LATEST_TAG="${LATEST_URL##*/}"'
  echo 'OS="$(uname -s | tr "[:upper:]" "[:lower:]")"'
  echo 'ARCH_UNAME="$(uname -m)"'
  echo 'case "$ARCH_UNAME" in'
  echo '  x86_64|amd64) ARCH="amd64" ;;'
  echo '  aarch64|arm64) ARCH="arm64" ;;'
  echo '  armv7l) ARCH="armv7" ;;'
  echo '  *) echo "Unsupported arch: $ARCH_UNAME"; exit 0 ;;'
  echo 'esac'
  echo ''
  echo 'TARBALL="miaospeed-${OS}-${ARCH}-${LATEST_TAG}.tar.gz"'
  echo 'URL="https://github.com/AirportR/miaospeed/releases/download/${LATEST_TAG}/${TARBALL}"'
  echo 'curl -fL "$URL" -o /tmp/miaospeed.tar.gz || exit 0'
  echo 'tar -xzf /tmp/miaospeed.tar.gz -C "$BIN_DIR"'
  echo 'rm -f /tmp/miaospeed.tar.gz'
  echo ''
  echo 'REAL_BIN=""'
  echo 'for f in "$BIN_DIR"/miaospeed-*-"$ARCH"; do'
  echo '  [ -f "$f" ] || continue'
  echo '  REAL_BIN="$f"; break'
  echo 'done'
  echo '[ -n "$REAL_BIN" ] || exit 0'
  echo 'ln -sf "$REAL_BIN" "$LINK_BIN"'
  echo 'chmod +x "$REAL_BIN" "$LINK_BIN"'
  echo ''
  echo 'if command -v systemctl >/dev/null 2>&1; then'
  echo '  systemctl restart miaospeed || true'
  echo 'elif [ -f "/etc/init.d/miaospeed" ]; then'
  echo '  /etc/init.d/miaospeed restart || true'
  echo 'elif [ -f "/usr/local/etc/rc.d/miaospeed" ]; then'
  echo '  service miaospeed restart || true'
  echo 'elif [ -f "/Library/LaunchDaemons/miaospeed.plist" ]; then'
  echo '  launchctl unload /Library/LaunchDaemons/miaospeed.plist || true'
  echo '  launchctl load  /Library/LaunchDaemons/miaospeed.plist || true'
  echo 'fi'
} > "$UPDATE_SCRIPT"
chmod +x "$UPDATE_SCRIPT"

# 注册每天 4:00 自动更新
(crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" ; echo "0 4 * * * $UPDATE_SCRIPT >/dev/null 2>&1") | crontab -

# ------------------------
# 完成提示（不再使用 cat 展示）
# ------------------------
title "安装完成"
info "服务已启动，当前配置："
if [ -f "$CONFIG_FILE" ]; then
  while IFS= read -r line; do
    echo "$line"
  done < "$CONFIG_FILE"
fi

# 常用管理指令提示
if command -v systemctl >/dev/null 2>&1; then
  info "服务管理：systemctl {start|stop|restart|status} ${SERVICE_NAME}"
elif [ -f /etc/init.d/"$SERVICE_NAME" ]; then
  info "服务管理：/etc/init.d/${SERVICE_NAME} {start|stop|restart|status}"
elif [ -f /usr/local/etc/rc.d/"$SERVICE_NAME" ]; then
  info "服务管理：service ${SERVICE_NAME} {start|stop|restart|status}"
elif [ -f /Library/LaunchDaemons/"$SERVICE_NAME".plist ]; then
  info "服务管理：launchctl unload/load /Library/LaunchDaemons/${SERVICE_NAME}.plist"
fi

info "卸载命令: bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeedv1.sh) --uninstall"
