
#!/usr/bin/env bash
# =====================================================================
# MiaoSpeed 后端 一键部署 / 卸载 / 自动更新
# - 系统：Linux(systemd)/OpenWrt(procd)/FreeBSD(rc.d)/macOS(launchd)
# - 架构：自动匹配（优先 amd64-v3，其次 amd64；arm64/armv7/386/riscv64/mips/mipsle...）
# - 资产命名：miaospeed-<os>-<arch>-<version>.tar.gz
# - GitHub Releases: https://github.com/AirportR/miaospeed/releases/latest
#
# 作者注：本脚本为全新实现，包含健壮的参数解析、彩色输出、错误处理与跨平台服务集成。
# =====================================================================

set -euo pipefail

# ----------------------------- 配置常量 ------------------------------
APP_NAME="miaospeed"
REPO_OWNER="AirportR"
REPO_NAME="miaospeed"
INSTALL_DIR="/opt/${APP_NAME}"
REAL_BIN="${INSTALL_DIR}/${APP_NAME}-real"
BIN_LINK="${INSTALL_DIR}/${APP_NAME}"
LOG_FILE="${INSTALL_DIR}/${APP_NAME}.log"
ERR_LOG="${INSTALL_DIR}/${APP_NAME}-error.log"
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"
SERVICE_NAME="${APP_NAME}"
GITHUB_API_LATEST="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

# 颜色
C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say()  { echo -e "${C_B}[*]${C_0} $*"; }
ok()   { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*"; }
err()  { echo -e "${C_R}[X]${C_0} $*"; }

cleanup() { :; }
on_error() {
  local ec=$?
  err "脚本执行中断（退出码：$ec）。查看日志或加 -v 手动排查。"
  exit "$ec"
}
trap on_error ERR
trap cleanup EXIT

# ----------------------------- 默认参数 ------------------------------
ARG_YES=false
ARG_UNINSTALL=false
ARG_VERSION=""
ARG_PORT=6699
ARG_PATH="/miaospeed"
ARG_TOKEN=""
ARG_WHITELIST=""
ARG_CONNTHREAD=64
ARG_TASKLIMIT=150
ARG_SPEEDLIMIT=0
ARG_PAUSESECOND=0
ARG_MMDB=false          # true/false
ARG_AUTO_UPDATE=false   # 是否注册无人值守更新

print_help() {
  cat <<'HLP'
用法: InstallMiaoSpeed.sh [选项]

常用选项：
  -y, --yes                 全程默认选择（非交互）
      --uninstall           卸载并清理
  -v, --version VER         指定版本（默认自动取 GitHub 最新 tag）
      --port N              监听端口（默认 6699）
      --path P              WebSocket Path（默认 /miaospeed）
      --token T             连接 Token（默认交互询问；非交互可显式传入）
      --whitelist IDS       BotID 白名单，逗号分隔（为空=不限制）
      --connthread N        最大并发连接（默认 64）
      --tasklimit N         任务队列上限（默认 150）
      --speedlimit N        测速限速（字节/秒，0=不限；默认 0）
      --pausesecond N       任务间隔秒数（默认 0）
      --mmdb true|false     是否启用 mmdb GEOIP（默认 false）
      --auto-update true|false  注册每日 04:00 自动更新（默认 false）
  -h, --help                显示本帮助

示例：
  bash InstallMiaoSpeed.sh
  bash InstallMiaoSpeed.sh --yes --port 6699 --path /ms --token abc --auto-update true
  bash InstallMiaoSpeed.sh --uninstall
HLP
}

# --------------------------- 参数解析 -------------------------------
parse_bool() {
  case "${1,,}" in
    true|1|yes|y) echo true ;;
    false|0|no|n|"") echo false ;;
    *) err "布尔参数取值无效：$1（需 true/false）"; exit 2 ;;
  esac
}

ARGS=("$@")
i=0
while [ $i -lt $# ]; do
  a="${ARGS[$i]}"
  case "$a" in
    -y|--yes) ARG_YES=true ;;
    --uninstall) ARG_UNINSTALL=true ;;
    -v|--version) i=$((i+1)); ARG_VERSION="${ARGS[$i]:-}";;
    --port) i=$((i+1)); ARG_PORT="${ARGS[$i]:-}";;
    --path) i=$((i+1)); ARG_PATH="${ARGS[$i]:-}";;
    --token) i=$((i+1)); ARG_TOKEN="${ARGS[$i]:-}";;
    --whitelist) i=$((i+1)); ARG_WHITELIST="${ARGS[$i]:-}";;
    --connthread) i=$((i+1)); ARG_CONNTHREAD="${ARGS[$i]:-}";;
    --tasklimit) i=$((i+1)); ARG_TASKLIMIT="${ARGS[$i]:-}";;
    --speedlimit) i=$((i+1)); ARG_SPEEDLIMIT="${ARGS[$i]:-}";;
    --pausesecond) i=$((i+1)); ARG_PAUSESECOND="${ARGS[$i]:-}";;
    --mmdb) i=$((i+1)); ARG_MMDB=$(parse_bool "${ARGS[$i]:-}");;
    --auto-update) i=$((i+1)); ARG_AUTO_UPDATE=$(parse_bool "${ARGS[$i]:-}");;
    -h|--help) print_help; exit 0;;
    *)
      err "未知参数：$a"; echo; print_help; exit 2;;
  esac
  i=$((i+1))
done

# --------------------------- 权限与环境 -----------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 运行（sudo -i 或 sudo bash ...）"; exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "缺少依赖：$1"; return 1; }; }

# --------------------------- 卸载流程 -------------------------------
if $ARG_UNINSTALL; then
  say "开始卸载 ${APP_NAME} ..."
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
  if [ -f "/usr/local/etc/rc.d/${SERVICE_NAME}" ]; then
    service "${SERVICE_NAME}" onestop || true
    rm -f "/usr/local/etc/rc.d/${SERVICE_NAME}"
    sysrc -x "${SERVICE_NAME}_enable" || true
    ok "已清理 FreeBSD rc.d 脚本"
  fi
  # macOS launchd
  if [ -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist" ]; then
    launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" || true
    rm -f "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
    ok "已清理 macOS launchd"
  fi
  pkill -f "${BIN_LINK}" >/dev/null 2>&1 || true
  crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}" | crontab - || true
  rm -rf "${INSTALL_DIR}"
  ok "卸载完成"
  exit 0
fi

# --------------------------- 系统与架构 -----------------------------
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

UNAME_M=$(uname -m)
case "${UNAME_M}" in
  x86_64)   CPU_ARCH="amd64" ;;
  aarch64|arm64) CPU_ARCH="arm64" ;;
  armv7l)   CPU_ARCH="armv7" ;;
  i386|i686)CPU_ARCH="386" ;;
  riscv64)  CPU_ARCH="riscv64" ;;
  mips)     CPU_ARCH="mips-softfloat" ;;
  mipsle)   CPU_ARCH="mipsle-softfloat" ;;
  *) err "暂不支持的架构：${UNAME_M}"; exit 1;;
esac
ok "CPU 架构: ${UNAME_M} -> ${CPU_ARCH}"

# --------------------------- 网络与依赖 -----------------------------
say "检测网络连通性 ..."
getent hosts github.com >/dev/null 2>&1 || warn "DNS 解析 github.com 失败，后续下载可能异常"
if ! curl -fsS --connect-timeout 8 https://github.com >/dev/null; then
  warn "无法连通 https://github.com，请检查网络/证书"
fi
if ! curl -fsS --connect-timeout 8 https://api.github.com/rate_limit >/dev/null; then
  warn "GitHub API 不可达，将尝试回退策略"
fi

say "安装/校验依赖 ..."
case "${OS_TYPE}" in
  openwrt)
    opkg update || true
    opkg install curl wget tar unzip ca-bundle ca-certificates || true
    ;;
  linux)
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y curl wget tar unzip ca-certificates cron net-tools || true
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
      warn "未知发行版，请手动确保 curl/wget/tar/unzip 可用"
    fi
    ;;
  freebsd)
    pkg install -y curl wget ca_root_nss gtar unzip || true
    ;;
  macos)
    command -v curl >/dev/null 2>&1 || { err "macOS 请先安装 curl"; exit 1; }
    ;;
  *)
    warn "未知系统，无法自动安装依赖，请手动安装 curl/wget/tar/unzip"
    ;;
esac
need_cmd curl
need_cmd tar || need_cmd gtar
ok "依赖就绪"

# --------------------------- 版本与资产选择 -------------------------
pick_pkg_os() {
  case "$OS_TYPE" in
    openwrt|linux)  echo "linux" ;;
    freebsd)        echo "freebsd" ;;
    macos)          echo "darwin" ;;
    *) err "当前系统不在支持下载列表：${OS_TYPE}"; exit 1 ;;
  esac
}

fetch_latest_tag() {
  local tag
  tag="$(curl -fsSL "$GITHUB_API_LATEST" | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true)"
  if [ -z "$tag" ]; then
    warn "无法获取最新版本，回退为 4.6.1"
    tag="4.6.1"
  fi
  echo "$tag"
}

fetch_assets_json() {
  curl -fsSL "$GITHUB_API_LATEST" || true
}

# 根据 assets 自动匹配优先级：amd64-v3 > amd64；其他架构直接精确匹配
pick_best_asset() {
  local ver="$1" os="$2" arch="$3" assets_json="$4"
  local base="miaospeed-${os}-${arch}-${ver}.tar.gz"
  local v3="miaospeed-${os}-${arch}-v3-${ver}.tar.gz"

  # amd64 特判 v3
  if [ "$arch" = "amd64" ]; then
    if echo "$assets_json" | grep -q "$v3"; then
      echo "$v3"; return 0
    fi
  fi
  # 普通精确
  if echo "$assets_json" | grep -q "$base"; then
    echo "$base"; return 0
  fi
  # 兼容 armv7 旧称（若有）
  if [ "$arch" = "armv7" ]; then
    local alt="miaospeed-${os}-armv7-${ver}.tar.gz"
    if echo "$assets_json" | grep -q "$alt"; then
      echo "$alt"; return 0
    fi
  fi
  return 1
}

PKG_OS="$(pick_pkg_os)"
VERSION="${ARG_VERSION:-$(fetch_latest_tag)}"
ASSETS_JSON="$(fetch_assets_json)"

ASSET_NAME="$(pick_best_asset "$VERSION" "$PKG_OS" "$CPU_ARCH" "$ASSETS_JSON" || true)"
if [ -z "${ASSET_NAME:-}" ]; then
  err "在发行页未找到匹配资产：os=${PKG_OS} arch=${CPU_ARCH} ver=${VERSION}"
  exit 1
fi
DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/${ASSET_NAME}"
say "将下载：${ASSET_NAME}"
ok "下载地址：${DOWNLOAD_URL}"

# --------------------------- 交互参数补全 ---------------------------
prompt_if_empty() {
  local var_name="$1" prompt="$2" default="$3"
  local cur_val
  cur_val="$(eval "echo \${$var_name:-}")"
  if $ARG_YES; then
    if [ -z "$cur_val" ]; then
      eval "$var_name=\"${default}\""
    fi
    return
  fi
  read -r -p "${prompt}（默认：${default}）: " input || true
  input="${input:-$default}"
  eval "$var_name=\"\$input\""
}

prompt_if_empty ARG_TOKEN   "连接 Token"            "defaultToken123"
prompt_if_empty ARG_PATH    "WebSocket Path"        "$ARG_PATH"
prompt_if_empty ARG_PORT    "监听端口"              "$ARG_PORT"
prompt_if_empty ARG_WHITELIST "BotID 白名单(逗号分隔，空=所有)" ""
prompt_if_empty ARG_CONNTHREAD "最大并发连接数"     "$ARG_CONNTHREAD"
prompt_if_empty ARG_TASKLIMIT  "任务队列上限"       "$ARG_TASKLIMIT"
prompt_if_empty ARG_SPEEDLIMIT "测速限速（字节/秒，0=不限）" "$ARG_SPEEDLIMIT"
prompt_if_empty ARG_PAUSESECOND "任务间隔秒数"      "$ARG_PAUSESECOND"

if ! $ARG_YES; then
  read -r -p "是否启用 mmdb GEOIP? (y/N): " _mmdb || true
  [ "${_mmdb,,}" = "y" ] && ARG_MMDB=true || true
  read -r -p "是否启用每日 04:00 无人值守自动更新? (y/N): " _au || true
  [ "${_au,,}" = "y" ] && ARG_AUTO_UPDATE=true || true
fi

# --------------------------- 清理旧安装 -----------------------------
if [ -d "${INSTALL_DIR}" ] && ! $ARG_YES; then
  read -r -p "检测到旧安装目录，是否清理重装？(Y/n): " _c || true
  if [ -z "$_c" ] || [ "${_c,,}" = "y" ]; then
    pkill -f "${BIN_LINK}" >/dev/null 2>&1 || true
    rm -rf "${INSTALL_DIR}"
    ok "已清理 ${INSTALL_DIR}"
  fi
fi
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# --------------------------- 下载并安装 -----------------------------
TAR_BIN="tar"; command -v gtar >/dev/null 2>&1 && [ "$OS_TYPE" = "freebsd" ] && TAR_BIN="gtar"

say "开始下载 ..."
curl -fL --connect-timeout 15 -o "${ASSET_NAME}" "${DOWNLOAD_URL}"

say "解压缩 ..."
${TAR_BIN} -zxf "${ASSET_NAME}"
rm -f "${ASSET_NAME}"

EXTRACTED_BIN="$(ls -1 miaospeed-* 2>/dev/null | head -n1 || true)"
[ -z "$EXTRACTED_BIN" ] && EXTRACTED_BIN="miaospeed-${PKG_OS}-${CPU_ARCH}" # 兜底
chmod +x "${EXTRACTED_BIN}"
mv -f "${EXTRACTED_BIN}" "${REAL_BIN}"
ln -sf "${REAL_BIN}" "${BIN_LINK}"
ok "安装完成：${REAL_BIN} -> ${BIN_LINK}"

# --------------------------- 生成启动命令 ---------------------------
CMD="${BIN_LINK} server -mtls -verbose -bind 0.0.0.0:${ARG_PORT} -allowip 0.0.0.0/0 -path ${ARG_PATH} -token ${ARG_TOKEN} -connthread ${ARG_CONNTHREAD} -tasklimit ${ARG_TASKLIMIT} -speedlimit ${ARG_SPEEDLIMIT} -pausesecond ${ARG_PAUSESECOND}"
[ -n "${ARG_WHITELIST}" ] && CMD="${CMD} -whitelist ${ARG_WHITELIST}"
$ARG_MMDB && CMD="${CMD} -mmdb GeoLite2-ASN.mmdb,GeoLite2-City.mmdb"

# --------------------------- 服务集成 -------------------------------
case "$OS_TYPE" in
  openwrt)
    say "配置 OpenWrt procd 服务 ..."
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
  procd_close_instance
}
EOF
    chmod +x /etc/init.d/${SERVICE_NAME}
    /etc/init.d/${SERVICE_NAME} enable
    /etc/init.d/${SERVICE_NAME} restart
    ;;
  linux)
    if command -v systemctl >/dev/null 2>&1; then
      say "配置 systemd 服务 ..."
      cat >/etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=MiaoSpeed Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CMD}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${ERR_LOG}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable ${SERVICE_NAME}
      systemctl restart ${SERVICE_NAME}
    else
      warn "未检测到 systemd，将前台托管到 nohup（请自行管理进程）"
      nohup ${CMD} >>"${LOG_FILE}" 2>>"${ERR_LOG}" &
    fi
    ;;
  freebsd)
    say "配置 FreeBSD rc.d ..."
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
    say "配置 macOS launchd ..."
    cat >/Library/LaunchDaemons/${SERVICE_NAME}.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${SERVICE_NAME}</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>${CMD}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${ERR_LOG}</string>
</dict></plist>
EOF
    launchctl unload "/Library/LaunchDaemons/${SERVICE_NAME}.plist" >/dev/null 2>&1 || true
    launchctl load  "/Library/LaunchDaemons/${SERVICE_NAME}.plist"
    ;;
  *)
    err "未知 OS_TYPE：${OS_TYPE}"; exit 1 ;;
esac

# --------------------------- 自动更新脚本 ---------------------------
say "生成自动更新脚本 ..."
cat >"${UPDATE_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_NAME="miaospeed"
REPO_OWNER="AirportR"
REPO_NAME="miaospeed"
INSTALL_DIR="/opt/${APP_NAME}"
REAL_BIN="${INSTALL_DIR}/${APP_NAME}-real"
BIN_LINK="${INSTALL_DIR}/${APP_NAME}"
SERVICE_NAME="${APP_NAME}"
GITHUB_API_LATEST="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

say(){ echo "[*] $*"; }

pick_os(){ [ -f /etc/openwrt_release ] && echo linux || case "$(uname -s)" in Linux)echo linux;;FreeBSD)echo freebsd;;Darwin)echo darwin;;*)echo unknown;;esac; }
pick_arch(){
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l) echo armv7 ;;
    i386|i686) echo 386 ;;
    riscv64) echo riscv64 ;;
    mips) echo mips-softfloat ;;
    mipsle) echo mipsle-softfloat ;;
    *) echo unknown ;;
  esac
}
latest_tag(){ curl -fsSL "$GITHUB_API_LATEST" | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true; }
assets_json(){ curl -fsSL "$GITHUB_API_LATEST" || true; }

pick_best_asset(){
  ver="$1"; os="$2"; arch="$3"; js="$4"
  v3="miaospeed-${os}-${arch}-v3-${ver}.tar.gz"
  base="miaospeed-${os}-${arch}-${ver}.tar.gz"
  if [ "$arch" = "amd64" ] && echo "$js" | grep -q "$v3"; then echo "$v3"; return; fi
  if echo "$js" | grep -q "$base"; then echo "$base"; return; fi
  echo ""
}

os="$(pick_os)"; arch="$(pick_arch)"
[ "$os" = "unknown" ] && { echo "Unsupported OS"; exit 0; }
[ "$arch" = "unknown" ] && { echo "Unsupported ARCH"; exit 0; }

ver="$(latest_tag)"; [ -z "$ver" ] && ver="4.6.1"
cur="$(${BIN_LINK} -version 2>/dev/null | awk '/^version:/{print $2}')"
[ "$cur" = "$ver" ] && { echo "Already latest: $ver"; exit 0; }

js="$(assets_json)"
asset="$(pick_best_asset "$ver" "$os" "$arch" "$js")"
[ -z "$asset" ] && { echo "No asset for $os-$arch-$ver"; exit 0; }

url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${ver}/${asset}"
say "更新到 ${ver} ... 下载 ${asset}"
cd "$INSTALL_DIR"
curl -fL -o "$asset" "$url"
tar -zxf "$asset" && rm -f "$asset"
bin_new="$(ls -1 miaospeed-* 2>/dev/null | head -n1 || true)"
[ -z "$bin_new" ] && bin_new="miaospeed-${os}-${arch}"
chmod +x "$bin_new"
mv -f "$bin_new" "${REAL_BIN}"
ln -sf "${REAL_BIN}" "${BIN_LINK}"

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
echo "✅ 已更新到 ${ver}"
EOS
chmod +x "${UPDATE_SCRIPT}"

# --------------------------- 注册自动更新 ---------------------------
if $ARG_AUTO_UPDATE; then
  CRON_LINE="0 4 * * * ${UPDATE_SCRIPT} >> ${INSTALL_DIR}/update.log 2>&1"
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "${UPDATE_SCRIPT}"; echo "${CRON_LINE}") | crontab -
    ok "已注册 cron：每日 04:00 自动更新"
  elif [ "$OS_TYPE" = "macos" ]; then
    warn "macOS 建议改用 launchd 的 StartCalendarInterval 添加定时"
    echo "    ${CRON_LINE}"
  else
    warn "未发现 crontab，请手动配置计划任务"
  fi
fi

# --------------------------- 状态检查与结束 -------------------------
say "检查端口与状态 ..."
if command -v ss >/dev/null 2>&1; 键，然后
  ss -tunlp | grep -E ":${ARG_PORT}\b" || true
elif command -v netstat >/dev/null 2>&1; 键，然后
  netstat -tunlp | grep -E ":${ARG_PORT}\b" || true
fi

ok "部署完成！"
echo "服务管理："
case "$OS_TYPE" 在
  openwrt) echo "  /etc/init.d/${SERVICE_NAME} {start|stop|restart|status}" ;;
  linux)
    if command -v systemctl >/dev/null 2>&1; then
      echo "  systemctl {start|stop|restart|status} ${SERVICE_NAME}"
    else
      echo "  （无 systemd）已用 nohup 前台托管，日志：${LOG_FILE}"
    fi ;;
  freebsd) echo "  service ${SERVICE_NAME} {start|stop|restart|status}" ;;
  macos)   echo "  launchctl unload/load /Library/LaunchDaemons/${SERVICE_NAME}.plist" ;;
esac
echo "日志： tail -f ${LOG_FILE}"
echo "手动更新： ${UPDATE_SCRIPT}"
echo "卸载： bash $(basename "$0") --uninstall"
