#!/bin/bash
# ============================================================
# 喵速测试后端安装与管理脚本
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# 特性: 本地留存 / 喵速更新 / 脚本自更新 / 交互式管理
# Telegram: https://t.me/i_chl
# ============================================================

set -uo pipefail

SCRIPT_VERSION="20260522.2"
SCRIPT_NAME="miaospeed.sh"
LOCAL_SCRIPT="/root/${SCRIPT_NAME}"
LOCAL_SCRIPT_BAK="/root/${SCRIPT_NAME}.bak"
LAUNCHER="/usr/bin/miao"
SCRIPT_REMOTE_URL="${SCRIPT_REMOTE_URL:-https://raw.githubusercontent.com/sunfing/miaospeed/main/InstallMiaoSpeed/miaospeed.sh}"

INSTALL_DIR="/opt/miaospeed"
LOG_DIR="${INSTALL_DIR}/log"
DATA_DIR="${INSTALL_DIR}/data"
TMP_DIR="${INSTALL_DIR}/tmp"
BACKUP_DIR="${INSTALL_DIR}/backup"

CONF_FILE="${INSTALL_DIR}/miaospeed.conf"
RUN_SCRIPT="${INSTALL_DIR}/run.sh"
UPDATE_SCRIPT="${INSTALL_DIR}/update.sh"
SERVICE_NAME="miaospeed"
CORE_REPO="airportr/miaospeed"
CORE_API="https://api.github.com/repos/${CORE_REPO}/releases/latest"

BIN_NAME=""
ARCH_KEY=""
DEFAULT_CONN=64
OS_TYPE="linux"
SERVICE_MODE=1 # 1=systemd, 2=procd
LAST_BACKUP_FILE=""
INSTALL_INTERRUPTED=0

C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
say()  { echo -e "${C_B}[*]${C_0} $*"; }
ok()   { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*"; }
err()  { echo -e "${C_R}[X]${C_0} $*"; }

pause_menu() {
  echo
  read -r -p "按回车返回..." _
}

install_interrupt_handler() {
  local confirm
  INSTALL_INTERRUPTED=1
  trap - INT TERM
  echo
  warn "安装流程已中断。"
  echo "当前可能已创建本地脚本、快捷入口或临时目录。"
  read -r -p "是否清理本次安装产生的文件? (y/N): " confirm
  if is_yes "$confirm"; then
    cleanup_interrupted_install
    ok "已清理本次安装产生的文件。"
  else
    warn "已保留现有文件；可稍后运行 bash ${LOCAL_SCRIPT} --uninstall 清理。"
  fi
  exit 130
}

cleanup_interrupted_install() {
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/"$SERVICE_NAME" stop >/dev/null 2>&1 || true
    /etc/init.d/"$SERVICE_NAME" disable >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi

  disable_core_auto_update >/dev/null 2>&1 || true
  disable_script_auto_update >/dev/null 2>&1 || true
  disable_restart_cron >/dev/null 2>&1 || true

  pkill -9 -f "^${INSTALL_DIR}/miaospeed" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR"
  rm -f "$LAUNCHER" /usr/local/bin/miao /etc/logrotate.d/miaospeed
  rm -f "$LOCAL_SCRIPT" "$LOCAL_SCRIPT_BAK"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "必须以 root 身份执行此脚本。"
    exit 1
  fi
}

is_yes() {
  case "${1:-}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$DATA_DIR" "$TMP_DIR" "$BACKUP_DIR"
}

random_alnum() {
  local len="${1:-32}"
  ( set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" )
}

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

validate_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_positive_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 > 0 ))
}

validate_gbps() {
  [[ "${1:-}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]]
}

validate_path() {
  [[ "${1:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

validate_token() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._/-]+$ ]]
}

validate_botid() {
  [[ -z "${1:-}" || "${1:-}" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

gbps_to_bytes() {
  awk -v gbps="${1:-0}" 'BEGIN { printf "%.0f", gbps * 125000000 }'
}

bytes_to_gbps() {
  awk -v bytes="${1:-0}" 'BEGIN {
    if (bytes == 0) {
      printf "0"
    } else {
      gbps = bytes / 125000000
      if (gbps == int(gbps)) printf "%d", gbps; else printf "%.2f", gbps
    }
  }'
}

format_speed_text() {
  local speed="${1:-0}" gbps
  if [ "$speed" = "0" ]; then
    printf "不限速"
  else
    gbps=$(bytes_to_gbps "$speed")
    printf "%s Gbps (%s B/s)" "$gbps" "$speed"
  fi
}

is_port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${port}$"
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\\.)${port}$"
  else
    return 1
  fi
}

random_port() {
  local port
  while true; do
    port=$((10000 + RANDOM % 50000))
    if ! is_port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
}

fetch_file() {
  local url="$1" output="$2"
  if command_exists curl; then
    curl -fL --connect-timeout 15 --max-time 180 -o "$output" "$url"
  elif command_exists wget; then
    wget -q --timeout=180 -O "$output" "$url"
  else
    return 1
  fi
}

fetch_text() {
  local url="$1"
  if command_exists curl; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  elif command_exists wget; then
    wget -q --timeout=30 -O - "$url"
  else
    return 1
  fi
}

detect_environment() {
  local quiet="${1:-0}"
  if [ -f "/etc/openwrt_release" ]; then
    OS_TYPE="openwrt"
    SERVICE_MODE=2
  else
    OS_TYPE="linux"
    SERVICE_MODE=1
  fi

  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)
      BIN_NAME="miaospeed-linux-amd64"
      ARCH_KEY="amd64"
      DEFAULT_CONN=64
      ;;
    aarch64|arm64)
      BIN_NAME="miaospeed-linux-arm64"
      ARCH_KEY="arm64"
      DEFAULT_CONN=32
      ;;
    *)
      err "当前架构 ${arch} 不受支持。"
      exit 1
      ;;
  esac

  if [ "$quiet" != "1" ]; then
    ok "系统: ${OS_TYPE} | 架构: ${arch} | 服务管理: $([ "$SERVICE_MODE" -eq 1 ] && echo systemd || echo procd)"
  fi
}

install_dependencies() {
  say "检查并安装核心依赖..."
  if [ "$OS_TYPE" = "openwrt" ]; then
    if command_exists opkg; then
      opkg update >/dev/null 2>&1 || true
      opkg install bash wget curl tar gzip grep sed coreutils-sha256sum procps-ng-pgrep ca-bundle >/dev/null 2>&1 || {
        warn "部分 OpenWrt 依赖安装失败，请确认 bash、wget/curl、tar、sha256sum 可用。"
      }
    fi
  elif command_exists apt-get; then
    apt-get update >/dev/null 2>&1
    apt-get install -y bash wget curl tar gzip ca-certificates cron logrotate iproute2 procps coreutils >/dev/null 2>&1
  elif command_exists dnf; then
    dnf install -y bash wget curl tar gzip ca-certificates cronie logrotate iproute procps-ng coreutils >/dev/null 2>&1
  elif command_exists yum; then
    yum install -y bash wget curl tar gzip ca-certificates cronie logrotate iproute procps-ng coreutils >/dev/null 2>&1
  else
    warn "未识别包管理器，请手动确认 bash、curl/wget、tar、sha256sum、crontab 可用。"
  fi
}

get_latest_core_version() {
  fetch_text "$CORE_API" 2>/dev/null | awk -F '"' '/tag_name/ {print $4; exit}'
}

find_extracted_binary() {
  local work_dir="$1" candidate
  for candidate in \
    "${work_dir}/${BIN_NAME}" \
    "${work_dir}/miaospeed" \
    "${work_dir}/miaospeed-linux-${ARCH_KEY}/miaospeed"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  find "$work_dir" -type f \( -name "$BIN_NAME" -o -name "miaospeed" \) 2>/dev/null | head -n 1
}

download_core_to_workdir() {
  local version="$1" work_dir="$2" file url local_sha remote_sha binary_path
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  file="${BIN_NAME}-${version}.tar.gz"
  url="https://github.com/${CORE_REPO}/releases/download/${version}/${file}"

  say "下载喵速核心: ${version}" >&2
  fetch_file "$url" "${work_dir}/${file}" || return 1

  if fetch_file "${url}.sha256" "${work_dir}/${file}.sha256" >/dev/null 2>&1; then
    local_sha=$(sha256sum "${work_dir}/${file}" | awk '{print $1}')
    remote_sha=$(awk '{print $1}' "${work_dir}/${file}.sha256")
    if [ "$local_sha" != "$remote_sha" ]; then
      err "SHA256 校验失败，已中止。" >&2
      return 1
    fi
    ok "核心程序 SHA256 校验通过。" >&2
  else
    warn "未获取到 SHA256 文件，继续使用下载包。" >&2
  fi

  tar -zxf "${work_dir}/${file}" -C "$work_dir" || return 1
  binary_path=$(find_extracted_binary "$work_dir")
  if [ -z "$binary_path" ] || [ ! -f "$binary_path" ]; then
    err "安装包中未找到喵速可执行文件。" >&2
    return 1
  fi
  chmod +x "$binary_path"
  printf '%s' "$binary_path"
}

download_mmdb() {
  local city_tmp asn_tmp
  city_tmp="${TMP_DIR}/GeoLite2-City.mmdb.tmp"
  asn_tmp="${TMP_DIR}/GeoLite2-ASN.mmdb.tmp"

  say "下载 GEOIP 数据库..."
  if fetch_file "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb" "$city_tmp" \
    && fetch_file "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb" "$asn_tmp"; then
    mv -f "$city_tmp" "${DATA_DIR}/GeoLite2-City.mmdb"
    mv -f "$asn_tmp" "${DATA_DIR}/GeoLite2-ASN.mmdb"
    ok "GEOIP 数据库已下载。"
    return 0
  fi

  rm -f "$city_tmp" "$asn_tmp"
  return 1
}

create_launcher() {
  cat > "$LAUNCHER" <<EOF
#!/bin/sh
SCRIPT="${LOCAL_SCRIPT}"
if [ ! -f "\$SCRIPT" ]; then
  echo "未找到本地管理脚本: \$SCRIPT"
  exit 1
fi
if [ "\$#" -eq 0 ]; then
  exec bash "\$SCRIPT" menu
else
  exec bash "\$SCRIPT" "\$@"
fi
EOF
  chmod +x "$LAUNCHER"
}

validate_script_file() {
  local file="$1"
  [ -s "$file" ] || return 1
  head -n 1 "$file" | grep -q '^#!/bin/bash' || return 1
  grep -q '^SCRIPT_VERSION=' "$file" || return 1
  if command_exists bash; then
    bash -n "$file" >/dev/null 2>&1 || return 1
  fi
}

install_local_script() {
  local quiet="${1:-0}" source_path source_real local_real tmp copied=1
  mkdir -p /root

  source_path="${BASH_SOURCE[0]:-}"
  source_real=$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")
  local_real=$(readlink -f "$LOCAL_SCRIPT" 2>/dev/null || printf '%s' "$LOCAL_SCRIPT")

  if [ -n "$source_path" ] && [ -r "$source_path" ]; then
    if [ "$source_real" != "$local_real" ]; then
      if cp -f "$source_path" "$LOCAL_SCRIPT" && validate_script_file "$LOCAL_SCRIPT"; then
        copied=0
      else
        rm -f "$LOCAL_SCRIPT"
      fi
    else
      validate_script_file "$LOCAL_SCRIPT" && copied=0
    fi
  fi

  if [ "$copied" -ne 0 ]; then
    [ "$quiet" = "1" ] || warn "无法从当前运行入口复制脚本，尝试从远端保存本地脚本。"
    tmp=$(mktemp /root/miaospeed.sh.XXXXXX)
    if fetch_file "$SCRIPT_REMOTE_URL" "$tmp" && validate_script_file "$tmp"; then
      mv -f "$tmp" "$LOCAL_SCRIPT"
      copied=0
    else
      rm -f "$tmp"
      [ "$quiet" = "1" ] || warn "本地脚本保存失败；后续可手动保存到 ${LOCAL_SCRIPT}。"
    fi
  fi

  if [ "$copied" -eq 0 ]; then
    chmod 700 "$LOCAL_SCRIPT"
    [ "$quiet" = "1" ] || ok "本地管理脚本: ${LOCAL_SCRIPT}"
  fi
  create_launcher
  [ "$quiet" = "1" ] || ok "快捷入口: ${LAUNCHER}，可直接输入 miao。"
}

get_conf() {
  local key="$1"
  awk -v key="$key" 'BEGIN { FS="=" } $1 == key {
    sub(/^[^=]*=/, "")
    gsub(/^"/, "")
    gsub(/"$/, "")
    print
    exit
  }' "$CONF_FILE" 2>/dev/null
}

load_config() {
  PORT=$(get_conf PORT)
  PATH_WS=$(get_conf PATH_WS)
  TOKEN=$(get_conf TOKEN)
  WHITELIST=$(get_conf WHITELIST)
  CONNTHREAD=$(get_conf CONNTHREAD)
  TASKLIMIT=$(get_conf TASKLIMIT)
  SPEEDLIMIT=$(get_conf SPEEDLIMIT)
  PAUSESECOND=$(get_conf PAUSESECOND)
  USE_MMDB=$(get_conf USE_MMDB)

  PORT="${PORT:-}"
  PATH_WS="${PATH_WS:-}"
  TOKEN="${TOKEN:-}"
  WHITELIST="${WHITELIST:-}"
  CONNTHREAD="${CONNTHREAD:-$DEFAULT_CONN}"
  TASKLIMIT="${TASKLIMIT:-150}"
  SPEEDLIMIT="${SPEEDLIMIT:-0}"
  PAUSESECOND="${PAUSESECOND:-0}"
  USE_MMDB="${USE_MMDB:-n}"
}

write_config() {
  cat > "$CONF_FILE" <<EOF
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
  chmod 600 "$CONF_FILE"
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  LAST_BACKUP_FILE="${BACKUP_DIR}/miaospeed.conf_$(date +%Y%m%d_%H%M%S)_$$_bak"
  cp "$CONF_FILE" "$LAST_BACKUP_FILE"
}

latest_config_backup() {
  ls -t "${BACKUP_DIR}"/miaospeed.conf_*_bak 2>/dev/null | head -n 1
}

restore_latest_config_backup() {
  local latest="$1"
  if [ -z "$latest" ] || [ ! -f "$latest" ]; then
    err "未找到可恢复的配置备份。"
    return 1
  fi

  if [ -f "$CONF_FILE" ]; then
    backup_config || {
      err "恢复前备份当前配置失败，已取消恢复。"
      return 1
    }
  fi

  cp "$latest" "$CONF_FILE" || {
    err "恢复配置失败。"
    return 1
  }
  chmod 600 "$CONF_FILE"

  say "配置已恢复，正在重启服务..."
  if restart_service; then
    ok "配置已恢复并重启服务。"
  else
    err "配置已恢复，但服务重启失败，请查看日志。"
    return 1
  fi
}

current_service_mode() {
  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && command_exists systemctl; then
    echo 1
  elif [ -x "/etc/init.d/${SERVICE_NAME}" ]; then
    echo 2
  else
    echo "$SERVICE_MODE"
  fi
}

stop_service() {
  local mode
  mode=$(current_service_mode)
  if [ "$mode" -eq 1 ]; then
    systemctl stop "$SERVICE_NAME"
  else
    /etc/init.d/"$SERVICE_NAME" stop
  fi
}

start_service() {
  local mode
  mode=$(current_service_mode)
  if [ "$mode" -eq 1 ]; then
    systemctl start "$SERVICE_NAME"
  else
    /etc/init.d/"$SERVICE_NAME" start
  fi
}

restart_service() {
  local mode
  mode=$(current_service_mode)
  if [ "$mode" -eq 1 ]; then
    systemctl restart "$SERVICE_NAME"
  else
    /etc/init.d/"$SERVICE_NAME" restart
  fi
}

is_service_alive() {
  local mode
  mode=$(current_service_mode)
  if [ "$mode" -eq 1 ]; then
    systemctl is-active --quiet "$SERVICE_NAME"
  else
    { command_exists pgrep && pgrep -f "${INSTALL_DIR}/miaospeed" >/dev/null 2>&1; } \
      || { command_exists pidof && pidof miaospeed >/dev/null 2>&1; }
  fi
}

apply_config_and_restart() {
  if ! backup_config; then
    err "配置备份失败，已取消保存。"
    return 1
  fi

  write_config
  say "配置已保存，正在重启服务..."
  if restart_service; then
    ok "服务已重启。"
    return 0
  fi

  warn "服务重启失败，正在恢复上一份配置。"
  cp "$LAST_BACKUP_FILE" "$CONF_FILE" 2>/dev/null || true
  restart_service >/dev/null 2>&1 || true
  return 1
}

create_run_script() {
  cat > "$RUN_SCRIPT" <<'EOF'
#!/bin/sh
ulimit -n 65535 2>/dev/null
CONF="/opt/miaospeed/miaospeed.conf"

[ -f "$CONF" ] || exit 1

_get() {
  sed -n "s/^$1=//p" "$CONF" | head -n 1 | sed -e 's/^"//' -e 's/"$//'
}

PORT=$(_get PORT)
PATH_WS=$(_get PATH_WS)
TOKEN=$(_get TOKEN)
WHITELIST=$(_get WHITELIST)
CONNTHREAD=$(_get CONNTHREAD)
TASKLIMIT=$(_get TASKLIMIT)
SPEEDLIMIT=$(_get SPEEDLIMIT)
PAUSESECOND=$(_get PAUSESECOND)
USE_MMDB=$(_get USE_MMDB)

set -- server -mtls -verbose \
  -bind "0.0.0.0:${PORT}" \
  -allowip "0.0.0.0/0" \
  -path "$PATH_WS" \
  -token "$TOKEN" \
  -connthread "$CONNTHREAD" \
  -tasklimit "$TASKLIMIT" \
  -speedlimit "$SPEEDLIMIT" \
  -pausesecond "$PAUSESECOND"

[ -n "$WHITELIST" ] && set -- "$@" -whitelist "$WHITELIST"

case "$USE_MMDB" in
  y|Y|yes|YES)
    set -- "$@" -mmdb "/opt/miaospeed/data/GeoLite2-ASN.mmdb,/opt/miaospeed/data/GeoLite2-City.mmdb"
    ;;
esac

exec /opt/miaospeed/miaospeed "$@"
EOF
  chmod +x "$RUN_SCRIPT"
}

create_service_files() {
  if [ "$SERVICE_MODE" -eq 1 ]; then
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
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  else
    cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
PROG="${RUN_SCRIPT}"
LOG_FILE="${LOG_DIR}/miaospeed.log"
ERR_FILE="${LOG_DIR}/miaospeed-error.log"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "\$PROG >> \$LOG_FILE 2>> \$ERR_FILE"
    procd_set_param limits core="unlimited" nofile="65535"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    /etc/init.d/"$SERVICE_NAME" enable
  fi

  if command_exists logrotate; then
    cat > /etc/logrotate.d/miaospeed <<EOF
${LOG_DIR}/*.log {
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
}

create_update_script() {
  cat > "$UPDATE_SCRIPT" <<'EOF'
#!/bin/bash
set -euo pipefail

DIR="/opt/miaospeed"
BIN="${DIR}/miaospeed"
CONF="${DIR}/miaospeed.conf"
TMP="${DIR}/tmp"
BACKUP="${DIR}/backup"
LOG="${DIR}/log/update.log"
LOCK_DIR="${TMP}/update.lock"
WORK_DIR="${TMP}/update-work"
CORE_REPO="airportr/miaospeed"
CORE_API="https://api.github.com/repos/${CORE_REPO}/releases/latest"

mkdir -p "$TMP" "$BACKUP" "${DIR}/log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

fetch_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 --max-time 180 -o "$output" "$url"
  else
    wget -q --timeout=180 -O "$output" "$url"
  fi
}

fetch_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url"
  else
    wget -q --timeout=30 -O - "$url"
  fi
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "[Warn] 检测到更新任务正在运行，本次退出。"
  exit 1
fi

cleanup() {
  rm -rf "$WORK_DIR" "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[ -f "$CONF" ] || { log "[Error] 未找到配置文件。"; exit 1; }
[ -x "$BIN" ] || { log "[Error] 未找到喵速主程序。"; exit 1; }

SVC_MODE=$( [ -f "/etc/systemd/system/miaospeed.service" ] && command -v systemctl >/dev/null 2>&1 && echo 1 || echo 2 )
stop_service() {
  if [ "$SVC_MODE" -eq 1 ]; then systemctl stop miaospeed; else /etc/init.d/miaospeed stop; fi
}
start_service() {
  if [ "$SVC_MODE" -eq 1 ]; then systemctl start miaospeed; else /etc/init.d/miaospeed start; fi
}
is_alive() {
  if [ "$SVC_MODE" -eq 1 ]; then
    systemctl is-active --quiet miaospeed
  else
    { command -v pgrep >/dev/null 2>&1 && pgrep -f "${DIR}/miaospeed" >/dev/null 2>&1; } \
      || { command -v pidof >/dev/null 2>&1 && pidof miaospeed >/dev/null 2>&1; }
  fi
}

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) BIN_NAME="miaospeed-linux-amd64"; ARCH_KEY="amd64" ;;
  aarch64|arm64) BIN_NAME="miaospeed-linux-arm64"; ARCH_KEY="arm64" ;;
  *) log "[Error] 不支持的架构: ${ARCH}"; exit 1 ;;
esac

find_extracted_binary() {
  local work_dir="$1" candidate
  for candidate in \
    "${work_dir}/${BIN_NAME}" \
    "${work_dir}/miaospeed" \
    "${work_dir}/miaospeed-linux-${ARCH_KEY}/miaospeed"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  find "$work_dir" -type f \( -name "$BIN_NAME" -o -name "miaospeed" \) 2>/dev/null | head -n 1
}

CUR_VER=$("$BIN" -version 2>/dev/null | awk '/^version:/ {print $2; exit}' || true)
CUR_VER="${CUR_VER:-unknown}"
LAT_VER=$(fetch_text "$CORE_API" 2>/dev/null | awk -F '"' '/tag_name/ {print $4; exit}' || true)
[ -n "$LAT_VER" ] || { log "[Warn] 获取最新版本失败。"; exit 1; }

if [ "$CUR_VER" = "$LAT_VER" ]; then
  log "[OK] 当前已是最新版: ${CUR_VER}"
  exit 0
fi

log "发现新版本: ${CUR_VER} -> ${LAT_VER}"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

FILE="${BIN_NAME}-${LAT_VER}.tar.gz"
URL="https://github.com/${CORE_REPO}/releases/download/${LAT_VER}/${FILE}"

log "下载更新包..."
fetch_file "$URL" "${WORK_DIR}/${FILE}" || { log "[Error] 下载失败，业务未中断。"; exit 1; }

if fetch_file "${URL}.sha256" "${WORK_DIR}/${FILE}.sha256" >/dev/null 2>&1; then
  L_SHA=$(sha256sum "${WORK_DIR}/${FILE}" | awk '{print $1}')
  R_SHA=$(awk '{print $1}' "${WORK_DIR}/${FILE}.sha256")
  [ "$L_SHA" = "$R_SHA" ] || { log "[Error] SHA256 校验失败，业务未中断。"; exit 1; }
  log "SHA256 校验通过。"
else
  log "[Warn] 未获取到 SHA256 文件，继续使用下载包。"
fi

tar -zxf "${WORK_DIR}/${FILE}" -C "$WORK_DIR"
NEW_BIN=$(find_extracted_binary "$WORK_DIR")
[ -n "$NEW_BIN" ] && [ -f "$NEW_BIN" ] || { log "[Error] 更新包中未找到可执行文件，业务未中断。"; exit 1; }
chmod +x "$NEW_BIN"

TS=$(date +%Y%m%d_%H%M%S)
BIN_BAK="${BACKUP}/miaospeed_${TS}_bak"
CONF_BAK="${BACKUP}/miaospeed.conf_${TS}_bak"
cp -p "$BIN" "$BIN_BAK" || { log "[Error] 主程序备份失败，业务未中断。"; exit 1; }
cp -p "$CONF" "$CONF_BAK" || { log "[Error] 配置备份失败，业务未中断。"; exit 1; }

log "校验完成，短暂停止服务并替换程序..."
stop_service || true
cp "$NEW_BIN" "${BIN}.new" || { log "[Error] 写入新程序失败，尝试恢复服务。"; start_service || true; exit 1; }
chmod +x "${BIN}.new"
mv -f "${BIN}.new" "$BIN"
start_service || true

log "服务已重启，5 秒后进行健康检查..."
sleep 5

if is_alive; then
  log "[OK] 核心已升级至: ${LAT_VER}"
  find "$BACKUP" -type f -name "*_bak" -mtime +30 -exec rm -f {} \; 2>/dev/null || true
  exit 0
fi

log "[Error] 新版本启动失败，开始回滚。"
stop_service || true
cp -p "$BIN_BAK" "$BIN" || { log "[Fatal] 回滚主程序失败，请手动检查: ${BIN_BAK}"; exit 1; }
cp -p "$CONF_BAK" "$CONF" || true
chmod +x "$BIN"
start_service || true
sleep 3
if is_alive; then
  log "[OK] 回滚完成，已恢复旧版本。"
else
  log "[Fatal] 回滚后服务仍未运行，请手动检查日志。"
  exit 1
fi
EOF
  chmod +x "$UPDATE_SCRIPT"
}

list_cron() {
  crontab -l 2>/dev/null || true
}

install_cron_line() {
  local pattern="$1" line="$2"
  if ! command_exists crontab; then
    warn "未找到 crontab，无法写入定时任务。"
    return 1
  fi
  (list_cron | grep -v -F "$pattern"; echo "$line") | crontab -
}

remove_cron_line() {
  local pattern="$1"
  command_exists crontab || return 0
  list_cron | grep -v -F "$pattern" | crontab -
}

has_cron_line() {
  local pattern="$1"
  command_exists crontab || return 1
  list_cron | grep -F -q "$pattern"
}

enable_core_auto_update() {
  install_cron_line "$UPDATE_SCRIPT" "0 4 * * * /bin/bash ${UPDATE_SCRIPT} >> ${LOG_DIR}/update.log 2>&1"
}

disable_core_auto_update() {
  remove_cron_line "$UPDATE_SCRIPT"
}

enable_script_auto_update() {
  install_cron_line "${LOCAL_SCRIPT} --self-update" "30 3 * * * /bin/bash ${LOCAL_SCRIPT} --self-update >> ${LOG_DIR}/script-update.log 2>&1"
}

disable_script_auto_update() {
  remove_cron_line "${LOCAL_SCRIPT} --self-update"
}

enable_restart_cron() {
  local line
  if [ "$(current_service_mode)" -eq 1 ]; then
    line="30 4 * * * /bin/systemctl restart ${SERVICE_NAME} >/dev/null 2>&1"
  else
    line="30 4 * * * /etc/init.d/${SERVICE_NAME} restart >/dev/null 2>&1"
  fi
  remove_cron_line "/etc/init.d/${SERVICE_NAME} restart"
  install_cron_line "/bin/systemctl restart ${SERVICE_NAME}" "$line"
}

disable_restart_cron() {
  remove_cron_line "/bin/systemctl restart ${SERVICE_NAME}"
  remove_cron_line "/etc/init.d/${SERVICE_NAME} restart"
}

core_auto_update_status() {
  has_cron_line "$UPDATE_SCRIPT" && echo "已开启，每日 04:00" || echo "未开启"
}

script_auto_update_status() {
  has_cron_line "${LOCAL_SCRIPT} --self-update" && echo "已开启，每日 03:30" || echo "未开启"
}

restart_cron_status() {
  if has_cron_line "/bin/systemctl restart ${SERVICE_NAME}" || has_cron_line "/etc/init.d/${SERVICE_NAME} restart"; then
    echo "已开启，每日 04:30"
  else
    echo "未开启"
  fi
}

print_kv() {
  local label="$1" value="$2"
  case "$label" in
    "GEOIP 数据库")   echo "  GEOIP 数据库       : ${value}" ;;
    "喵速自动更新")   echo "  喵速自动更新       : ${value}" ;;
    "脚本自动更新")   echo "  脚本自动更新       : ${value}" ;;
    "喵速定时重启")   echo "  喵速定时重启       : ${value}" ;;
    "运行状态")       echo -e "  运行状态           : ${value}" ;;
    "状态时间")       echo "  状态时间           : ${value}" ;;
    "脚本版本")       echo "  脚本版本           : ${value}" ;;
    "本地脚本")       echo "  本地脚本           : ${value}" ;;
    "快捷入口")       echo "  快捷入口           : ${value}" ;;
    "运行日志")       echo "  运行日志           : ${value}" ;;
    "监听端口")       echo "  监听端口           : ${value}" ;;
    "WebSocket 路径") echo "  WebSocket 路径     : ${value}" ;;
    "连接 Token")     echo "  连接 Token         : ${value}" ;;
    "BotID 白名单")   echo "  BotID 白名单       : ${value}" ;;
    "最大并发数")     echo "  最大并发数         : ${value}" ;;
    "任务队列上限")   echo "  任务队列上限       : ${value}" ;;
    "测速限速")       echo "  测速限速           : ${value}" ;;
    "任务间隔")       echo "  任务间隔           : ${value}" ;;
    *)                echo "  ${label}: ${value}" ;;
  esac
}

print_menu_item() {
  local number="$1" label="$2" value="$3"
  case "$label" in
    "GEOIP 数据库")   echo "  ${number}  GEOIP 数据库       ${value}" ;;
    "喵速自动更新")   echo "  ${number}  喵速自动更新       ${value}" ;;
    "脚本自动更新")   echo "  ${number}  脚本自动更新       ${value}" ;;
    "喵速定时重启")   echo "  ${number}  喵速定时重启       ${value}" ;;
    *)                echo "  ${number}  ${label} ${value}" ;;
  esac
}

service_status_text() {
  local mode state since
  mode=$(current_service_mode)
  if [ "$mode" -eq 1 ] && command_exists systemctl; then
    state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
    since=$(systemctl show "$SERVICE_NAME" -p ActiveEnterTimestamp --value 2>/dev/null || true)
    case "$state" in
      active) print_kv "运行状态" "${C_G}运行中${C_0}" ;;
      inactive) print_kv "运行状态" "${C_Y}已停止${C_0}" ;;
      failed) print_kv "运行状态" "${C_R}启动失败${C_0}" ;;
      activating) print_kv "运行状态" "${C_B}启动中${C_0}" ;;
      *) print_kv "运行状态" "${C_Y}未知${C_0}" ;;
    esac
    [ -n "$since" ] && print_kv "状态时间" "$since"
  elif [ -x "/etc/init.d/${SERVICE_NAME}" ]; then
    if { command_exists pgrep && pgrep -f "${INSTALL_DIR}/miaospeed" >/dev/null 2>&1; } \
      || { command_exists pidof && pidof miaospeed >/dev/null 2>&1; }; then
      print_kv "运行状态" "${C_G}运行中${C_0}"
    else
      print_kv "运行状态" "${C_Y}已停止${C_0}"
    fi
  else
    print_kv "运行状态" "${C_Y}未找到服务${C_0}"
  fi
}

show_status_config() {
  local mmdb_text speed_text whitelist_text
  load_config
  mmdb_text="未启用"
  is_yes "$USE_MMDB" && mmdb_text="已启用"
  speed_text=$(format_speed_text "$SPEEDLIMIT")
  whitelist_text="${WHITELIST:-允许所有}"

  echo
  echo "---------------- 连接参数 ----------------"
  print_kv "监听端口" "$PORT"
  print_kv "WebSocket 路径" "$PATH_WS"
  print_kv "连接 Token" "$TOKEN"

  echo
  echo "---------------- 访问控制 ----------------"
  print_kv "BotID 白名单" "$whitelist_text"

  echo
  echo "---------------- 运行参数 ----------------"
  print_kv "最大并发数" "$CONNTHREAD"
  print_kv "任务队列上限" "$TASKLIMIT"
  print_kv "测速限速" "$speed_text"
  print_kv "任务间隔" "${PAUSESECOND} 秒"

  echo
  echo "---------------- 自动维护 ----------------"
  print_kv "GEOIP 数据库" "$mmdb_text"
  print_kv "喵速自动更新" "$(core_auto_update_status)"
  print_kv "脚本自动更新" "$(script_auto_update_status)"
  print_kv "喵速定时重启" "$(restart_cron_status)"

  echo
  echo "---------------- 服务与文件 ----------------"
  service_status_text
  print_kv "脚本版本" "$SCRIPT_VERSION"
  print_kv "本地脚本" "$LOCAL_SCRIPT"
  print_kv "快捷入口" "$LAUNCHER"
  print_kv "运行日志" "${LOG_DIR}/miaospeed.log"
}

view_logs() {
  local log_pid
  echo "按 Ctrl+C 结束日志查看。"
  if [ -f "${LOG_DIR}/miaospeed.log" ]; then
    tail -f "${LOG_DIR}/miaospeed.log" &
  elif command_exists journalctl && [ "$(current_service_mode)" -eq 1 ]; then
    journalctl -u "$SERVICE_NAME" -f &
  elif command_exists logread; then
    sh -c "logread -f 2>/dev/null | grep '${SERVICE_NAME}'" &
  else
    warn "未找到可用日志源。"
    return
  fi
  log_pid=$!
  trap 'kill "$log_pid" 2>/dev/null; wait "$log_pid" 2>/dev/null; trap - INT' INT
  wait "$log_pid" 2>/dev/null
  trap - INT
}

edit_connection_params() {
  local old_port old_path old_token input
  load_config
  old_port="$PORT"; old_path="$PATH_WS"; old_token="$TOKEN"

  echo
  echo "---------------- 修改连接参数 ----------------"
  read -r -p "监听端口 [当前 ${PORT}]: " input
  if [ -n "$input" ]; then
    validate_port "$input" || { err "端口必须是 1-65535 之间的数字。"; pause_menu; return; }
    if [ "$input" != "$old_port" ] && is_port_in_use "$input"; then
      err "端口 ${input} 已被占用。"
      pause_menu
      return
    fi
    PORT="$input"
  fi

  read -r -p "WebSocket 路径 [当前 ${PATH_WS}]: " input
  if [ -n "$input" ]; then
    PATH_WS="$input"
    [[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"
    validate_path "$PATH_WS" || { err "WebSocket 路径包含非法字符。"; pause_menu; return; }
  fi

  read -r -p "连接 Token [当前 ${TOKEN}]: " input
  if [ -n "$input" ]; then
    validate_token "$input" || { err "Token 包含非法字符。"; pause_menu; return; }
    TOKEN="$input"
  fi

  if [ "$PORT" = "$old_port" ] && [ "$PATH_WS" = "$old_path" ] && [ "$TOKEN" = "$old_token" ]; then
    echo "连接参数未变化。"
  else
    apply_config_and_restart
  fi
  pause_menu
}

edit_access_control() {
  local old_whitelist input
  load_config
  old_whitelist="$WHITELIST"

  echo
  echo "---------------- 修改访问控制 ----------------"
  echo "多个 BotID 使用英文逗号分隔；直接回车保持不变，输入 all 清空白名单。"
  read -r -p "BotID 白名单 [当前 ${WHITELIST:-允许所有}]: " input
  if [ -n "$input" ]; then
    if [ "$input" = "all" ] || [ "$input" = "ALL" ]; then
      WHITELIST=""
    else
      WHITELIST="$input"
    fi
  fi
  validate_botid "$WHITELIST" || { err "BotID 白名单仅允许数字和英文逗号，或留空。"; pause_menu; return; }

  if [ "$WHITELIST" = "$old_whitelist" ]; then
    echo "访问控制未变化。"
  else
    apply_config_and_restart
  fi
  pause_menu
}

edit_runtime_params() {
  local old_conn old_task old_speed old_pause input speed_gbps
  load_config
  old_conn="$CONNTHREAD"; old_task="$TASKLIMIT"; old_speed="$SPEEDLIMIT"; old_pause="$PAUSESECOND"
  speed_gbps=$(bytes_to_gbps "$SPEEDLIMIT")

  echo
  echo "---------------- 修改运行参数 ----------------"
  read -r -p "最大并发数 [当前 ${CONNTHREAD}]: " input
  if [ -n "$input" ]; then
    validate_positive_uint "$input" || { err "最大并发数必须是大于 0 的整数。"; pause_menu; return; }
    CONNTHREAD="$input"
  fi

  read -r -p "任务队列上限 [当前 ${TASKLIMIT}]: " input
  if [ -n "$input" ]; then
    validate_positive_uint "$input" || { err "任务队列上限必须是大于 0 的整数。"; pause_menu; return; }
    TASKLIMIT="$input"
  fi

  read -r -p "测速限速 Gbps，0 不限速 [当前 ${speed_gbps}]: " input
  if [ -n "$input" ]; then
    validate_gbps "$input" || { err "测速限速必须是数字，例如 0、1、1.5。"; pause_menu; return; }
    SPEEDLIMIT=$(gbps_to_bytes "$input")
  fi

  read -r -p "任务间隔秒数 [当前 ${PAUSESECOND}]: " input
  if [ -n "$input" ]; then
    validate_uint "$input" || { err "任务间隔必须是非负整数。"; pause_menu; return; }
    PAUSESECOND="$input"
  fi

  if [ "$CONNTHREAD" = "$old_conn" ] \
    && [ "$TASKLIMIT" = "$old_task" ] \
    && [ "$SPEEDLIMIT" = "$old_speed" ] \
    && [ "$PAUSESECOND" = "$old_pause" ]; then
    echo "运行参数未变化。"
  else
    apply_config_and_restart
  fi
  pause_menu
}

check_core_update() {
  if [ ! -x "$UPDATE_SCRIPT" ]; then
    warn "更新脚本不存在，正在重新生成。"
    create_update_script
  fi
  bash "$UPDATE_SCRIPT"
  pause_menu
}

fetch_remote_script_version() {
  local content
  content=$(fetch_text "$SCRIPT_REMOTE_URL" 2>/dev/null || true)
  printf '%s\n' "$content" | awk -F '"' '/^SCRIPT_VERSION=/ {print $2; exit}'
}

self_update() {
  local remote_version tmp
  tmp=$(mktemp /root/miaospeed.sh.XXXXXX)

  if ! fetch_file "$SCRIPT_REMOTE_URL" "$tmp"; then
    rm -f "$tmp"
    err "无法下载远端脚本，请检查网络或 SCRIPT_REMOTE_URL。"
    return 1
  fi

  remote_version=$(awk -F '"' '/^SCRIPT_VERSION=/ {print $2; exit}' "$tmp")
  if [ -z "$remote_version" ]; then
    rm -f "$tmp"
    err "无法识别远端脚本版本，已取消更新。"
    return 1
  fi

  if [ "$remote_version" = "$SCRIPT_VERSION" ]; then
    rm -f "$tmp"
    ok "管理脚本已是最新版: ${SCRIPT_VERSION}"
    return 0
  fi

  say "发现管理脚本新版本: ${SCRIPT_VERSION} -> ${remote_version}"
  if validate_script_file "$tmp"; then
    [ -f "$LOCAL_SCRIPT" ] && cp -f "$LOCAL_SCRIPT" "$LOCAL_SCRIPT_BAK"
    mv -f "$tmp" "$LOCAL_SCRIPT"
    chmod 700 "$LOCAL_SCRIPT"
    create_launcher
    ok "管理脚本已更新到 ${remote_version}。"
    return 0
  fi

  rm -f "$tmp"
  err "脚本更新失败，已保留当前版本。"
  return 1
}

script_update_menu() {
  local remote_version confirm
  echo
  echo "---------------- 更新管理脚本 ----------------"
  echo "当前版本: ${SCRIPT_VERSION}"
  remote_version=$(fetch_remote_script_version)
  if [ -n "$remote_version" ]; then
    echo "远端版本: ${remote_version}"
  else
    echo "远端版本: 获取失败"
  fi
  echo "远端地址: ${SCRIPT_REMOTE_URL}"
  echo
  read -r -p "是否现在更新管理脚本? (y/N): " confirm
  if is_yes "$confirm"; then
    self_update
  else
    echo "已取消。"
  fi
  pause_menu
}

toggle_geoip() {
  load_config
  if is_yes "$USE_MMDB"; then
    read -r -p "当前已启用 GEOIP，是否关闭? (y/N): " confirm
    if is_yes "$confirm"; then
      USE_MMDB="n"
      apply_config_and_restart
    fi
  else
    read -r -p "当前未启用 GEOIP，是否下载并启用? (y/N): " confirm
    if is_yes "$confirm"; then
      if download_mmdb; then
        USE_MMDB="y"
        apply_config_and_restart
      else
        err "GEOIP 数据库下载失败，未启用。"
      fi
    fi
  fi
}

auto_maintenance_menu() {
  local choice
  while true; do
    clear
    echo "=================================================="
    echo "                自动维护设置"
    echo "=================================================="
    load_config
    print_menu_item "1." "GEOIP 数据库" "$(is_yes "$USE_MMDB" && echo 已启用 || echo 未启用)"
    print_menu_item "2." "喵速自动更新" "$(core_auto_update_status)"
    print_menu_item "3." "脚本自动更新" "$(script_auto_update_status)"
    print_menu_item "4." "喵速定时重启" "$(restart_cron_status)"
    echo "--------------------------------------------------"
    echo "  0.  返回主菜单"
    echo "=================================================="
    read -r -p "请输入序号: " choice

    case "$choice" in
      1)
        toggle_geoip
        pause_menu
        ;;
      2)
        if has_cron_line "$UPDATE_SCRIPT"; then
          disable_core_auto_update && ok "喵速自动更新已关闭。"
        else
          enable_core_auto_update && ok "喵速自动更新已开启，每日 04:00。"
        fi
        pause_menu
        ;;
      3)
        if has_cron_line "${LOCAL_SCRIPT} --self-update"; then
          disable_script_auto_update && ok "脚本自动更新已关闭。"
        else
          enable_script_auto_update && ok "脚本自动更新已开启，每日 03:30。"
        fi
        pause_menu
        ;;
      4)
        if has_cron_line "/bin/systemctl restart ${SERVICE_NAME}" || has_cron_line "/etc/init.d/${SERVICE_NAME} restart"; then
          disable_restart_cron && ok "喵速定时重启已关闭。"
        else
          enable_restart_cron && ok "喵速定时重启已开启，每日 04:30。"
        fi
        pause_menu
        ;;
      0) return ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

backup_cleanup_menu() {
  local choice confirm count latest
  while true; do
    clear
    count=$(find "$BACKUP_DIR" -type f -name "miaospeed.conf_*_bak" 2>/dev/null | wc -l | awk '{print $1}')
    latest=$(latest_config_backup)

    echo "=================================================="
    echo "              配置备份与清理"
    echo "=================================================="
    echo "配置备份数量: ${count}"
    [ -n "${latest:-}" ] && echo "最近配置备份: ${latest}"
    echo "--------------------------------------------------"
    echo "  1.  立即备份配置"
    echo "  2.  恢复最近配置备份"
    echo "  3.  清理 30 天前配置备份"
    echo "  4.  清理所有配置备份"
    echo "  0.  返回主菜单"
    echo "=================================================="
    read -r -p "请输入序号: " choice

    case "$choice" in
      1)
        if backup_config; then
          ok "配置已备份: ${LAST_BACKUP_FILE}"
        else
          err "配置备份失败。"
        fi
        pause_menu
        ;;
      2)
        if [ -z "${latest:-}" ]; then
          err "未找到可恢复的配置备份。"
        else
          echo "将恢复最近配置备份:"
          echo "$latest"
          read -r -p "确认恢复并重启服务吗? (y/N): " confirm
          if is_yes "$confirm"; then
            restore_latest_config_backup "$latest"
          else
            echo "已取消。"
          fi
        fi
        pause_menu
        ;;
      3)
        find "$BACKUP_DIR" -type f -name "miaospeed.conf_*_bak" -mtime +30 -exec rm -f {} \; 2>/dev/null
        ok "已清理 30 天前配置备份。"
        pause_menu
        ;;
      4)
        read -r -p "确认清理所有配置备份文件吗? (y/N): " confirm
        if is_yes "$confirm"; then
          find "$BACKUP_DIR" -type f -name "miaospeed.conf_*_bak" -exec rm -f {} \; 2>/dev/null
          ok "所有配置备份文件已清理。"
        else
          echo "已取消。"
        fi
        pause_menu
        ;;
      0) return ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

show_menu() {
  clear
  echo "=================================================="
  echo "              喵速管理控制台"
  echo "=================================================="
  printf "  %-3s %s\n" "1." "查看状态配置"
  printf "  %-3s %s\n" "2." "查看实时日志"
  printf "  %-3s %s\n" "3." "修改连接参数"
  printf "  %-3s %s\n" "4." "修改访问控制"
  printf "  %-3s %s\n" "5." "修改运行参数"
  printf "  %-3s %s\n" "6." "检查喵速更新"
  printf "  %-3s %s\n" "7." "更新管理脚本"
  printf "  %-3s %s\n" "8." "自动维护设置"
  printf "  %-3s %s\n" "9." "配置备份与清理"
  printf "  %-3s %s\n" "10." "卸载"
  printf "  %-3s %s\n" "0." "退出"
  echo "--------------------------------------------------"
  echo "  喵速自动更新 : $(core_auto_update_status)"
  echo "  脚本自动更新 : $(script_auto_update_status)"
  echo "  喵速定时重启 : $(restart_cron_status)"
  echo "=================================================="
}

main_menu() {
  local choice confirm
  detect_environment 1
  ensure_dirs
  while true; do
    show_menu
    read -r -p "请输入序号: " choice
    case "$choice" in
      1) show_status_config; pause_menu ;;
      2) view_logs; pause_menu ;;
      3) edit_connection_params ;;
      4) edit_access_control ;;
      5) edit_runtime_params ;;
      6) check_core_update ;;
      7) script_update_menu ;;
      8) auto_maintenance_menu ;;
      9) backup_cleanup_menu ;;
      10)
        read -r -p "确认卸载喵速并删除相关文件吗? (y/N): " confirm
        if is_yes "$confirm"; then
          uninstall_flow "full"
          exit 0
        fi
        pause_menu
        ;;
      0) exit 0 ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

prompt_initial_config() {
  local input speed_gbps

  echo -e "\n${C_G}=== 阶段一: 连接参数 ===${C_0}"
  read -r -p "监听端口 (直接回车随机分配 10000-59999): " input
  if [ -z "$input" ]; then
    PORT=$(random_port)
    ok "已自动分配端口: ${PORT}"
  else
    validate_port "$input" || { err "端口必须是 1-65535 之间的数字。"; exit 1; }
    if is_port_in_use "$input"; then
      err "端口 ${input} 已被占用。"
      exit 1
    fi
    PORT="$input"
  fi

  read -r -p "WebSocket 路径 (直接回车生成 32 位随机路径): " input
  if [ -z "$input" ]; then
    PATH_WS="/$(random_alnum 32)"
    ok "已自动生成路径: ${PATH_WS}"
  else
    PATH_WS="$input"
    [[ "$PATH_WS" != /* ]] && PATH_WS="/$PATH_WS"
    validate_path "$PATH_WS" || { err "WebSocket 路径包含非法字符。"; exit 1; }
  fi

  read -r -p "连接 Token (直接回车生成 32 位随机 Token): " input
  if [ -z "$input" ] || [ "$input" = "defaulttoken" ]; then
    TOKEN=$(random_alnum 32)
    ok "已自动生成 Token: ${TOKEN}"
  else
    validate_token "$input" || { err "Token 包含非法字符。"; exit 1; }
    TOKEN="$input"
  fi

  echo -e "\n${C_Y}=== 阶段二: 访问控制 ===${C_0}"
  read -r -p "BotID 白名单 (留空允许所有，多个 ID 用英文逗号分隔): " input
  WHITELIST="${input:-}"
  validate_botid "$WHITELIST" || { err "BotID 白名单仅允许数字和英文逗号，或留空。"; exit 1; }

  echo -e "\n${C_Y}=== 阶段三: 运行参数 ===${C_0}"
  read -r -p "是否手工配置运行参数? (y/N 默认: N): " input
  CONNTHREAD="$DEFAULT_CONN"
  TASKLIMIT=150
  SPEEDLIMIT=0
  PAUSESECOND=0

  if is_yes "$input"; then
    read -r -p "最大并发数 [默认 ${DEFAULT_CONN}]: " input
    CONNTHREAD="${input:-$DEFAULT_CONN}"
    validate_positive_uint "$CONNTHREAD" || { err "最大并发数必须是大于 0 的整数。"; exit 1; }

    read -r -p "任务队列上限 [默认 150]: " input
    TASKLIMIT="${input:-150}"
    validate_positive_uint "$TASKLIMIT" || { err "任务队列上限必须是大于 0 的整数。"; exit 1; }

    read -r -p "测速限速 Gbps，0 不限速 [默认 0]: " input
    speed_gbps="${input:-0}"
    validate_gbps "$speed_gbps" || { err "测速限速必须是数字，例如 0、1、1.5。"; exit 1; }
    SPEEDLIMIT=$(gbps_to_bytes "$speed_gbps")

    read -r -p "任务间隔秒数 [默认 0]: " input
    PAUSESECOND="${input:-0}"
    validate_uint "$PAUSESECOND" || { err "任务间隔必须是非负整数。"; exit 1; }
  fi

  echo -e "\n${C_B}=== 阶段四: 自动维护 ===${C_0}"
  read -r -p "是否下载并启用 GEOIP 数据库? (y/N 默认: N): " input
  USE_MMDB="${input:-n}"

  read -r -p "是否启用每日 04:00 喵速自动更新? (y/N 默认: N): " input
  ENABLE_CORE_AUTO_UPDATE="${input:-n}"

  read -r -p "是否启用每日 03:30 管理脚本自动更新? (y/N 默认: N): " input
  ENABLE_SCRIPT_AUTO_UPDATE="${input:-n}"

  read -r -p "是否启用每日 04:30 喵速定时重启? (Y/n 默认: Y): " input
  ENABLE_RESTART="${input:-y}"
}

install_flow() {
  local latest_version work_dir binary_path
  require_root
  trap install_interrupt_handler INT TERM
  ensure_dirs
  detect_environment
  install_local_script
  install_dependencies
  install_local_script 1

  say "获取喵速最新版本..."
  latest_version=$(get_latest_core_version || true)
  if [ -z "$latest_version" ]; then
    warn "获取最新版本失败，回退至默认版本 4.6.1。"
    latest_version="4.6.1"
  else
    ok "最新版本: ${latest_version}"
  fi

  prompt_initial_config

  work_dir="${TMP_DIR}/install-work"
  binary_path=$(download_core_to_workdir "$latest_version" "$work_dir") || {
    err "核心程序下载或校验失败。"
    trap - INT TERM
    exit 1
  }

  if is_yes "$USE_MMDB"; then
    if ! download_mmdb; then
      warn "GEOIP 数据库下载失败，已自动关闭 GEOIP。"
      USE_MMDB="n"
    fi
  fi

  say "写入配置与服务文件..."
  write_config
  create_run_script
  create_update_script
  create_service_files

  stop_service >/dev/null 2>&1 || true
  if ! cp "$binary_path" "${INSTALL_DIR}/miaospeed"; then
    err "写入核心程序失败，请检查 ${INSTALL_DIR} 权限或磁盘空间。"
    trap - INT TERM
    exit 1
  fi
  chmod +x "${INSTALL_DIR}/miaospeed"
  rm -rf "$work_dir"

  say "启动喵速服务..."
  if start_service; then
    sleep 3
    if is_service_alive; then
      ok "喵速服务已启动。"
    else
      err "服务启动命令已执行，但健康检查未通过，请查看日志。"
      trap - INT TERM
      exit 1
    fi
  else
    err "服务启动失败，请查看日志。"
    trap - INT TERM
    exit 1
  fi

  if is_yes "$ENABLE_CORE_AUTO_UPDATE"; then
    enable_core_auto_update >/dev/null 2>&1 || true
  fi
  if is_yes "$ENABLE_SCRIPT_AUTO_UPDATE"; then
    enable_script_auto_update >/dev/null 2>&1 || true
  fi
  if is_yes "$ENABLE_RESTART"; then
    enable_restart_cron >/dev/null 2>&1 || true
  fi

  show_install_summary
  trap - INT TERM
}

show_install_summary() {
  local mmdb_text speed_text whitelist_text
  mmdb_text="未启用"
  is_yes "$USE_MMDB" && mmdb_text="已启用 (${DATA_DIR})"
  speed_text=$(format_speed_text "$SPEEDLIMIT")
  whitelist_text="${WHITELIST:-允许所有}"

  echo -e "\n${C_G}============================================================${C_0}"
  echo -e " 喵速部署完成"
  echo -e "${C_G}============================================================${C_0}"

  echo -e " ${C_B}[连接参数]${C_0}"
  echo -e " - 监听端口        : ${C_Y}${PORT}${C_0}"
  echo -e " - WebSocket 路径  : ${C_Y}${PATH_WS}${C_0}"
  echo -e " - 连接 Token      : ${C_Y}${TOKEN}${C_0}"

  echo
  echo -e " ${C_B}[访问控制]${C_0}"
  echo -e " - BotID 白名单    : ${whitelist_text}"

  echo
  echo -e " ${C_B}[运行参数]${C_0}"
  echo -e " - 最大并发数      : ${CONNTHREAD}"
  echo -e " - 任务队列上限    : ${TASKLIMIT}"
  echo -e " - 测速限速        : ${speed_text}"
  echo -e " - 任务间隔        : ${PAUSESECOND} 秒"

  echo
  echo -e " ${C_B}[自动维护]${C_0}"
  echo -e " - GEOIP 数据库    : ${mmdb_text}"
  echo -e " - 喵速自动更新    : $(core_auto_update_status)"
  echo -e " - 脚本自动更新    : $(script_auto_update_status)"
  echo -e " - 喵速定时重启    : $(restart_cron_status)"

  echo
  echo -e " ${C_B}[管理入口]${C_0}"
  echo -e " - 快捷菜单        : ${C_G}miao${C_0}"
  echo -e " - 本地脚本        : ${LOCAL_SCRIPT}"
  echo -e " - 手动卸载        : bash ${LOCAL_SCRIPT} --uninstall"
  echo -e " - 运行日志        : ${LOG_DIR}/miaospeed.log"
  echo -e "${C_G}============================================================${C_0}"
  echo -e " ${C_R}[!] 请确认云安全组或本机防火墙已放行 TCP 端口 ${PORT}${C_0}"
  echo -e "${C_G}============================================================${C_0}"
}

uninstall_flow() {
  local mode="${1:-full}"
  require_root
  say "开始卸载喵速..."

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
    /etc/init.d/"$SERVICE_NAME" stop >/dev/null 2>&1 || true
    /etc/init.d/"$SERVICE_NAME" disable >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi

  pkill -9 -f "^${INSTALL_DIR}/miaospeed" >/dev/null 2>&1 || true

  disable_core_auto_update >/dev/null 2>&1 || true
  disable_script_auto_update >/dev/null 2>&1 || true
  disable_restart_cron >/dev/null 2>&1 || true

  rm -rf "$INSTALL_DIR"
  rm -f "$LAUNCHER" /usr/local/bin/miao /etc/logrotate.d/miaospeed

  if [ "$mode" = "full" ]; then
    rm -f "$LOCAL_SCRIPT" "$LOCAL_SCRIPT_BAK"
  fi

  ok "喵速已卸载。"
}

ensure_installed_or_offer() {
  local confirm
  if [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ]; then
    return 0
  fi
  warn "未检测到完整安装。"
  read -r -p "是否现在开始安装? (y/N): " confirm
  if is_yes "$confirm"; then
    install_flow
    exit 0
  fi
  exit 1
}

usage() {
  cat <<EOF
用法:
  bash $0                 首次安装；已安装时进入菜单
  bash $0 menu            打开管理菜单
  bash $0 --self-update   更新本地管理脚本
  bash $0 --uninstall     卸载喵速

安装后可直接输入:
  miao
EOF
}

main() {
  require_root
  case "${1:-}" in
    "")
      if [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ]; then
        main_menu
      else
        install_flow
      fi
      ;;
    menu)
      ensure_installed_or_offer
      main_menu
      ;;
    --self-update)
      ensure_dirs
      self_update
      ;;
    --uninstall)
      uninstall_flow "full"
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
