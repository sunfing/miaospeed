
#!/usr/bin/env bash
# ============================================================
# MiaoSpeed 后端 一键部署/卸载/自动更新
# 支持系统：
#   - Linux（systemd）/ OpenWrt（procd）
#   - FreeBSD（rc.d）
#   - macOS（launchd）
# 自动识别架构（amd64/arm64/armv7/386/riscv64/mips/mipsle ...）
# GitHub：https://github.com/sunfing
# Telegram：https://t.me/i_chl
# ============================================================

set -euo pipefail

INSTALL_DIR="/opt/miaospeed"
BIN_LINK="${INSTALL_DIR}/miaospeed"      # 统一软链接名（进程名将显示为 "miaospeed"）
REAL_BIN="${INSTALL_DIR}/miaospeed-real" # 实际二进制文件
LOG_FILE="${INSTALL_DIR}/miaospeed.log"
SERVICE_NAME="miaospeed"
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"

# 颜色
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say() { echo -e "${C_B}[*]${C_0} $*"; }
ok()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn(){ echo -e "${C_Y}[!]${C_0} $*"; }
err() { echo -e "${C_R}[X]${C_0} $*"; }

# ============================================================
# 0. 检查 root 权限
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 运行脚本（sudo -i 或 sudo bash ...）"; exit 1
fi

# ============================================================
# 1. 检查是否执行卸载
# ============================================================
if [[ "${1:-}" == "--uninstall" ]]; then
  say "卸载 MiaoSpeed ..."
  # systemd
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    systemctl stop "${SERVICE_NAME}" || true
    systemctl disable "${SERVICE_NAME}" || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload || true
    ok "已清理 systemd 服务"
  fi
  # OpenWrt procd
  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    "/etc/init.d/${SERVICE_NAME}" stop || true
    "/etc/init.d/${SERVICE_NAME}" disable || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
    ok "已清理 procd 启动脚本"
  fi
  # FreeBSD rc.d
  if [ -d "/usr/local/etc/rc.d" ] && [ -f "/usr/local/etc/rc.d/${SERVICE_NAME}" ]; then
    service "${SERVICE_NAME}" onestop || true
    rm -f "/usr/local/etc/rc.d/${SERVICE_NAME}"
    sysrc -x "${SERVICE_NAME}_enable" || true
    ok "已清理 FreeBSD rc.d 脚本"
  fi
  # macOS launchd
  if [ -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist" ]; then
    launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" || true
    rm -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
    ok "已清理 macOS launchd 服务"
  fi
  # 进程/目录/定时任务
  pkill -f "${BIN_LINK}" >/dev/null 2>&1 || true
  crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}" | crontab - || true
  rm -rf "${INSTALL_DIR}"
  ok "卸载完成"
  exit 0
fi

# ============================================================
# 2. 检查 CPU 架构（映射到发行页命名）
# ============================================================
UNAME_M=$(uname -m)
case "${UNAME_M}" in
  x86_64)   CPU_ARCH="amd64"   ;;
  aarch64)  CPU_ARCH="arm64"   ;;
  arm64)    CPU_ARCH="arm64"   ;;
  armv7l)   CPU_ARCH="armv7"   ;;
  i386|i686)CPU_ARCH="386"     ;;
  riscv64)  CPU_ARCH="riscv64" ;;
  mips)     CPU_ARCH="mips-softfloat"   ;;
  mipsle)   CPU_ARCH="mipsle-softfloat" ;;
  *)        err "不支持的架构: ${UNAME_M}"; exit 1 ;;
esac
ok "CPU 架构: ${UNAME_M} -> ${CPU_ARCH}"

# ============================================================
# 3. 检测系统类型（影响服务管理与依赖）
# ============================================================
OS_UNAME=$(uname -s)
if [ -f /etc/openwrt_release ]; then
  OS_TYPE="openwrt"
elif [ "${OS_UNAME}" = "Linux" ]; then
  OS_TYPE="linux"
elif [ "${OS_UNAME}" = "FreeBSD" ]; then
  OS_TYPE="freebsd"
elif [ "${OS_UNAME}" = "Darwin" ]; then
  OS_TYPE="macos"
else
  OS_TYPE="other"
fi
ok "操作系统: ${OS_UNAME} -> ${OS_TYPE}"

# ============================================================
# 4. 检测网络可用性（DNS/TCP/GitHub API）
# ============================================================
say "检测网络连通性 ..."
# DNS
if ! getent hosts github.com >/dev/null 2>&1; then
  warn "无法解析 github.com，尝试继续，但可能会下载失败。"
fi
# TCP 443（curl 自测）
if ! curl -sSf --connect-timeout 5 https://github.com >/dev/null; then
  warn "无法连通 https://github.com，可能是网络或证书问题。"
fi
# GitHub API
if ! curl -sSf --connect-timeout 5 https://api.github.com/rate_limit >/dev/null; then
  warn "GitHub API 不可达，后续获取最新版本可能失败。"
fi

# ============================================================
# 5. 安装依赖
# ============================================================
say "安装依赖（curl/wget/tar/unzip/cron 或等价） ..."
case "${OS_TYPE}" in
  openwrt)
    opkg update
    opkg install curl wget tar unzip ca-bundle ca-certificates || true
    ;;
  linux)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y curl wget tar unzip ca-certificates net-tools cron || true
      update-ca-certificates || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl wget tar unzip ca-certificates cronie net-tools || true
      systemctl enable crond --now || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl wget tar unzip ca-certificates cronie net-tools || true
      systemctl enable crond --now || true
    elif command -v zypper >/dev/null 2>&1; then
      zypper install -y curl wget tar unzip ca-certificates cron net-tools || true
    else
      warn "未识别的 Linux 发行版，请确保 curl/wget/tar/unzip 已安装。"
    fi
    ;;
  freebsd)
    pkg install -y curl wget ca_root_nss gtar unzip || true
    ;;
  macos)
    command -v curl >/dev/null 2>&1 || err "macOS 请先确保已安装 curl"
    ;;
  *)
    warn "未知系统：请手动确保 curl/wget/tar/unzip 可用。"
    ;;
esac
ok "依赖检查完成"

# ============================================================
# 6. 获取 GitHub 最新版本
# ============================================================
say "获取 GitHub 最新版本 ..."
LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true)
if [ -z "${LATEST_VERSION}" ]; then
  warn "无法获取最新版本，回退为固定版本 4.6.1"
  LATEST_VERSION="4.6.1"
fi
ok "最新版本：${LATEST_VERSION}"

# ============================================================
# 7. 用户输入配置
# ============================================================
echo -e "\n====== MiaoSpeed 部署配置 ======"
read -r -p "版本号 (默认: ${LATEST_VERSION}): " MIAOSPEED_VERSION
MIAOSPEED_VERSION=${MIAOSPEED_VERSION:-${LATEST_VERSION}}

read -r -p "监听端口 (默认: 6699): " PORT
PORT=${PORT:-6699}

read -r -p "WebSocket Path (示例: /abc123xyz): " PATH_WS
PATH_WS=${PATH_WS:-/miaospeed}

read -r -p "连接 Token: " TOKEN
TOKEN=${TOKEN:-defaultToken123}

read -r -p "BotID 白名单(逗号分隔, 空=所有): " WHITELIST
WHITELIST=${WHITELIST:-""}

read -r -p "最大并发连接数 (默认: 64): " CONNTHREAD
CONNTHREAD=${CONNTHREAD:-64}

read -r -p "任务队列上限 (默认: 150): " TASKLIMIT
TASKLIMIT=${TASKLIMIT:-150}

read -r -p "测速限速（字节/秒，0=不限，默认0）: " SPEEDLIMIT
SPEEDLIMIT=${SPEEDLIMIT:-0}

read -r -p "任务间隔秒数（默认0）: " PAUSESECOND
PAUSESECOND=${PAUSESECOND:-0}

read -r -p "是否启用 mmdb GEOIP (y/n，默认 n): " USE_MMDB
USE_MMDB=${USE_MMDB:-n}

echo -e "\n将为 OS=${OS_TYPE}, ARCH=${CPU_ARCH} 下载对应构建：miaospeed-<os>-<arch>-<ver>.tar.gz"
ok "下载前提示：os=${OS_TYPE} arch=${CPU_ARCH} version=${MIAOSPEED_VERSION}"

# ============================================================
# 8. 清理旧安装文件
# ============================================================
if [ -d "${INSTALL_DIR}" ]; then
  read -r -p "检测到旧安装目录，是否清理？(y/n 默认 y): " CLEAN_OLD
  CLEAN_OLD=${CLEAN_OLD:-y}
  if [[ "${CLEAN_OLD}" =~ ^[Yy]$ ]]; then
    pkill -f "${BIN_LINK}" >/dev/null 2>&1 || true
    rm -rf "${INSTALL_DIR}"
    ok "已清理 ${INSTALL_DIR}"
  fi
fi

# ============================================================
# 9. 下载并安装 MiaoSpeed
# ============================================================
say "下载并安装 ..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# 发行页命名：<os> 取值：linux/freebsd/darwin；OpenWrt 也用 linux 包
case "${OS_TYPE}" in
  openwrt|linux)  PKG_OS="linux"   ;;
  freebsd)        PKG_OS="freebsd" ;;
  macos)          PKG_OS="darwin"  ;;
  *)              err "当前系统不在可下载列表：${OS_TYPE}"; exit 1 ;;
esac

TARBALL="miaospeed-${PKG_OS}-${CPU_ARCH}-${MIAOSPEED_VERSION}.tar.gz"
URL="https://github.com/airportr/miaospeed/releases/download/${MIAOSPEED_VERSION}/${TARBALL}"

say "下载地址：${URL}"
if ! curl -fL --connect-timeout 10 -o "${TARBALL}" "${URL}"; then
  err "下载失败，请检查版本/网络或发行页是否存在该组合：${PKG_OS}-${CPU_ARCH}-${MIAOSPEED_VERSION}"
  exit 1
fi

# FreeBSD 上使用 gtar，其他使用 tar
TAR_BIN="tar"
if [ "${OS_TYPE}" = "freebsd" ] && command -v gtar >/dev/null 2>&1; then
  TAR_BIN="gtar"
fi

say "解压文件 ..."
${TAR_BIN} -zxvf "${TARBALL}"
rm -f "${TARBALL}"

# 解压后的二进制名字统一是：miaospeed-<os>-<arch> 或 miaospeed-linux-amd64（项目规范）
EXTRACTED_BIN="$(ls -1 miaospeed-* 2>/dev/null | head -n1 || true)"
if [ -z "${EXTRACTED_BIN}" ]; then
  # 兼容旧命名
  EXTRACTED_BIN="miaospeed-linux-amd64"
fi

chmod +x "${EXTRACTED_BIN}"
mv -f "${EXTRACTED_BIN}" "${REAL_BIN}"

# 统一软链接，确保进程名/规则匹配用 "miaospeed"
ln -sf "${REAL_BIN}" "${BIN_LINK}"
ok "安装完成：${REAL_BIN} -> ${BIN_LINK}"

# ============================================================
# 10. 配置启动管理（systemd / procd / FreeBSD rc.d / macOS launchd）
# ============================================================
CMD="${BIN_LINK} server -mtls -verbose -bind 0.0.0.0:${PORT} -allowip 0.0.0.0/0 -path ${PATH_WS} -token ${TOKEN} -connthread ${CONNTHREAD} -tasklimit ${TASKLIMIT} -speedlimit ${SPEEDLIMIT} -pausesecond ${PAUSESECOND}"
if [ -n "${WHITELIST}" ]; then CMD="${CMD} -whitelist ${WHITELIST}"; fi
if [[ "${USE_MMDB}" =~ ^[Yy]$ ]]; then CMD="${CMD} -mmdb GeoLite2-ASN.mmdb,GeoLite2-City.mmdb"; fi

case "${OS_TYPE}" in
  openwrt)
    say "创建 OpenWrt procd 脚本 ..."
    cat >/etc/init.d/${SERVICE_NAME} <<EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10
PROG="${BIN_LINK}"
PROG_ARGS="$(echo "${CMD}" | sed "s|^${BIN_LINK} ||")"

start_service() {
  procd_open_instance
  procd_set_param command \$PROG \$PROG_ARGS
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_set_param file ${LOG_FILE}
  procd_close_instance
}
EOF
    chmod +x /etc/init.d/${SERVICE_NAME}
    /etc/init.d/${SERVICE_NAME} enable
    /etc/init.d/${SERVICE_NAME} restart
    ;;

  linux)
    if command -v systemctl >/dev/null 2>&1; then
      say "创建 systemd 服务 ..."
      cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MiaoSpeed Backend Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CMD}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${INSTALL_DIR}/miaospeed-error.log
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable ${SERVICE_NAME}
      systemctl restart ${SERVICE_NAME}
    else
      warn "未检测到 systemd。将直接前台运行：${CMD}"
      nohup ${CMD} >> "${LOG_FILE}" 2>&1 &
    fi
    ;;

  freebsd)
    say "创建 FreeBSD rc.d 脚本 ..."
    cat >/usr/local/etc/rc.d/${SERVICE_NAME} <<'EOF'
#!/bin/sh
# PROVIDE: miaospeed
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr
name="miaospeed"
rcvar=miaospeed_enable
load_rc_config $name

: ${miaospeed_enable:="YES"}
: ${miaospeed_user:="root"}
: ${miaospeed_cmd:="__CMD__"}
pidfile="/var/run/${name}.pid"
command="/usr/sbin/daemon"
command_args="-p ${pidfile} -f ${miaospeed_cmd}"

run_rc_command "$1"
EOF
    sed -i '' "s|__CMD__|${CMD}|g" /usr/local/etc/rc.d/${SERVICE_NAME}
    chmod +x /usr/local/etc/rc.d/${SERVICE_NAME}
    sysrc ${SERVICE_NAME}_enable=YES
    service ${SERVICE_NAME} restart
    ;;

  macos)
    say "创建 macOS launchd 服务 ..."
    cat >/Library/LaunchDaemons/${SERVICE_NAME}.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string><string>${CMD}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${INSTALL_DIR}/miaospeed-error.log</string>
</dict>
</plist>
EOF
    launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" >/dev/null 2>&1 || true
    launchctl load  "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
    ;;

  *)
    err "未知 OS_TYPE：${OS_TYPE}"; exit 1 ;;
esac

# ============================================================
# 11. 生成自动更新脚本（跨架构/跨系统）
# ============================================================
say "生成自动更新脚本 ..."
cat >"${UPDATE_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="/opt/miaospeed"
BIN_LINK="${INSTALL_DIR}/miaospeed"
REAL_BIN="${INSTALL_DIR}/miaospeed-real"
SERVICE_NAME="miaospeed"

# OS & ARCH 映射
uname_s=$(uname -s); uname_m=$(uname -m)
case "$uname_s" in
  Linux)   os_type="linux" ;;
  FreeBSD) os_type="freebsd" ;;
  Darwin)  os_type="darwin" ;;
  *) echo "Unsupported OS: $uname_s"; exit 0 ;;
esac
case "$uname_m" in
  x86_64)   cpu_arch="amd64" ;;
  aarch64|arm64) cpu_arch="arm64" ;;
  armv7l)   cpu_arch="armv7" ;;
  i386|i686)cpu_arch="386" ;;
  riscv64)  cpu_arch="riscv64" ;;
  mips)     cpu_arch="mips-softfloat" ;;
  mipsle)   cpu_arch="mipsle-softfloat" ;;
  *) echo "Unsupported ARCH: $uname_m"; exit 0 ;;
esac

latest=$(curl -fsSL https://api.github.com/repos/airportr/miaospeed/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true)
[ -z "$latest" ] && latest="4.6.1"

current=$(${BIN_LINK} -version 2>/dev/null | awk '/^version:/{print $2}')
if [ "$current" = "$latest" ] && [ -n "$current" ]; then
  echo "当前已是最新版本 $current，无需更新"; exit 0
fi

tarball="miaospeed-${os_type}-${cpu_arch}-${latest}.tar.gz"
url="https://github.com/airportr/miaospeed/releases/download/${latest}/${tarball}"
echo "检测到新版本 ${latest}（当前 ${current:-unknown}），开始更新：${url}"

cd "$INSTALL_DIR"
curl -fL -o "${tarball}" "${url}"
tar -zxvf "${tarball}"
rm -f "${tarball}"

bin_new="$(ls -1 miaospeed-* 2>/dev/null | head -n1 || true)"
[ -z "$bin_new" ] && bin_new="miaospeed-linux-amd64"
chmod +x "$bin_new"
mv -f "$bin_new" "${REAL_BIN}"
ln -sf "${REAL_BIN}" "${BIN_LINK}"

# 重启
if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
  systemctl restart "${SERVICE_NAME}"
elif [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
  /etc/init.d/${SERVICE_NAME} restart
elif [ -f "/usr/local/etc/rc.d/${SERVICE_NAME}" ]; then
  service "${SERVICE_NAME}" restart
elif [ -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist" ]; then
  launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" || true
  launchctl load  "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
fi

echo "✅ 已更新至 ${latest} 并重启完成"
EOS
chmod +x "${UPDATE_SCRIPT}"

# ============================================================
# 12. 询问是否启用无人值守自动更新（每天 4:00）
# ============================================================
echo -e "\n====== 自动更新配置 ======"
read -r -p "是否启用无人值守每日 4 点自动更新？(y/n 默认 n): " ENABLE_AUTO
ENABLE_AUTO=${ENABLE_AUTO:-n}
if [[ "${ENABLE_AUTO}" =~ ^[Yy]$ ]]; then
  CRON_LINE="0 4 * * * ${UPDATE_SCRIPT} >> ${INSTALL_DIR}/update.log 2>&1"
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}"; echo "${CRON_LINE}") | crontab -
    ok "已注册 cron 任务（每天 4 点自动更新）"
  elif [ "${OS_TYPE}" = "macos" ]; then
    # 简单提示，macOS 可用 launchd 的 StartCalendarInterval
    warn "macOS 建议改用 launchd 定时；当前请手动使用 crontab -e 添加："
    echo "    ${CRON_LINE}"
  else
    warn "未发现 crontab，需手动配置计划任务。"
  fi
  echo "更新日志：${INSTALL_DIR}/update.log"
else
  warn "已跳过自动更新。以后可手动运行：${UPDATE_SCRIPT}"
fi

# ============================================================
# 13. 检查服务状态
# ============================================================
say "检查服务状态 ..."
if command -v ss >/dev/null 2>&1; then
  ss -tunlp | grep -E ":${PORT}\b" || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -tunlp | grep -E ":${PORT}\b" || true
fi
ok "若上面未显示，可执行：tail -f ${LOG_FILE} 查看运行日志"

# ============================================================
# 14. 完成提示
# ============================================================
echo -e "\n====== 部署完成 ======"
case "${OS_TYPE}" in
  openwrt)
    echo "服务管理：/etc/init.d/${SERVICE_NAME} {start|stop|restart|status}"
    ;;
  linux)
    if command -v systemctl >/dev/null 2>&1; then
      echo "服务管理：systemctl {start|stop|restart|status} ${SERVICE_NAME}"
    else
      echo "前台运行已启动（无 systemd），日志：${LOG_FILE}"
    fi
    ;;
  freebsd)
    echo "服务管理：service ${SERVICE_NAME} {start|stop|restart|status}"
    ;;
  macos)
    echo "服务管理：launchctl unload/load /Library/LaunchDaemons/${SERVICE_NAME}.plist"
    ;;
esac
echo "日志：tail -f ${LOG_FILE}"
echo "更新：${UPDATE_SCRIPT}    （无人值守启用后，每天 04:00 自动执行）"
echo "卸载：bash <(curl -fsSL https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/InstallMiaoSpeedv1.sh) --uninstall"
