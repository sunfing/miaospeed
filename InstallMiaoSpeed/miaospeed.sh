#!/bin/bash
# ============================================================
# 喵速测试后端安装与管理脚本
# 支持系统: Linux AMD64 / ARM64 (含 OpenWrt)
# 特性: 本地留存 / 喵速更新 / 脚本自更新 / 交互式管理
# Telegram: https://t.me/i_chl
# ============================================================

set -uo pipefail

SCRIPT_VERSION="20260903.1"
RUNTIME_TEMPLATE_VERSION="20260902.1"
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
DEFAULT_BOTID_NOTES_FILE="${INSTALL_DIR}/botid_notes.tsv"
BOTID_NOTES_FILE="$DEFAULT_BOTID_NOTES_FILE"
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
INSTALL_COMPLETED=0
INSTALL_CLEANUP_DONE=0
INSTALL_SKIP_AUTO_CLEANUP=0
INSTALL_ROLLBACK_CONFIG=""
CORE_VERSION=""
CORE_UPDATE_POLICY="latest"
ENABLE_IPV6="n"
ENABLE_UPLOAD="n"
ENABLE_DOWNLOAD_SPEED="y"
OUTBOUND_INTERFACE=""
VERBOSE_LOG="y"
BIND_ADDRESS=""
ALLOW_IPS="0.0.0.0/0"
CLIENT_CA_FILE=""
SERVER_PUBLIC_KEY_FILE=""
SERVER_PRIVATE_KEY_FILE=""
PPROF_ADDRESS=""
HAD_CONFIG_BEFORE_INSTALL=0
LATEST_VERSION_FALLBACK=0
PENDING_BOTID_NOTES_FILE=""

if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
  C_G="\033[1;32m"; C_Y="\033[1;33m"; C_R="\033[1;31m"; C_B="\033[1;34m"; C_0="\033[0m"
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi
say()  { echo -e "${C_B}[*]${C_0} $*"; }
ok()   { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*"; }
err()  { echo -e "${C_R}[X]${C_0} $*"; }

clear_screen() {
  if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && command_exists clear; then
    clear
  fi
}

pause_menu() {
  echo
  read -r -p "按回车返回..." _
}

menu_child_interrupt_handler() {
  trap - INT TERM
  echo
  warn "操作已取消，返回主菜单。"
  exit 130
}

run_menu_action() {
  local action="$1"
  shift || true
  trap ':' INT TERM
  (
    trap menu_child_interrupt_handler INT TERM
    "$action" "$@"
  )
  local status=$?
  trap - INT TERM
  case "$status" in
    0) return 0 ;;
    130)
      trap ':' INT TERM
      pause_menu
      trap - INT TERM
      return 0
      ;;
    111|112) return "$status" ;;
    *) return "$status" ;;
  esac
}

show_status_config_menu() {
  local show_sensitive="y" input redraw=0
  while true; do
    [ "$redraw" -eq 0 ] || clear_screen
    show_status_config "$show_sensitive"
    redraw=1

    echo
    input=""
    if is_yes "$show_sensitive"; then
      read -r -p "输入 H 隐藏路径与 Token（便于截图），直接回车返回: " input || return 0
    else
      read -r -p "输入 S 显示完整参数，直接回车返回: " input || return 0
    fi

    case "$input" in
      "") return 0 ;;
      h|H) show_sensitive="n" ;;
      s|S) show_sensitive="y" ;;
      *)
        warn "请输入 H、S，或直接回车返回。"
        read -r -p "按回车继续..." _ || return 0
        ;;
    esac
  done
}

view_logs_menu() {
  view_logs
  trap menu_child_interrupt_handler INT TERM
  pause_menu
}

confirm_purge() {
  local confirm=""
  warn "彻底清除将删除程序、配置、BotID 备注、备份、日志和本地管理脚本。"
  read -r -p "继续彻底清除 (y/N): " confirm
  is_yes "$confirm" || return 1
  confirm=""
  read -r -p "请输入 DELETE 进行二次确认: " confirm
  [ "$confirm" = "DELETE" ]
}

uninstall_menu_action() {
  local mode="${1:-keep-config}" confirm=""
  if [ "$mode" = "purge" ]; then
    confirm_purge && return 113
  else
    read -r -p "卸载喵速程序并保留配置、备注和备份 (y/N): " confirm
    is_yes "$confirm" && return 112
  fi
  echo "已取消。"
  pause_menu
}

main_menu_interrupt_handler() {
  trap - INT TERM
  echo
  warn "已退出喵速管理控制台。"
  exit 130
}

install_interrupt_handler() {
  local confirm
  INSTALL_INTERRUPTED=1
  trap - INT TERM
  echo
  warn "安装流程已中断。"
  echo "当前可能已创建本地脚本、快捷入口或临时目录。"
  read -r -p "清理本次安装产生的文件 (y/N): " confirm
  if is_yes "$confirm"; then
    if cleanup_interrupted_install; then
      ok "已清理本次安装产生的文件。"
    else
      err "本次安装文件已清理，但原配置恢复失败，请检查备份: ${INSTALL_ROLLBACK_CONFIG:-无}"
    fi
  else
    INSTALL_SKIP_AUTO_CLEANUP=1
    warn "已保留现有文件；可稍后运行 bash ${LOCAL_SCRIPT} --uninstall 清理。"
  fi
  exit 130
}

cleanup_interrupted_install() {
  local restore_failed=0
  [ "$INSTALL_CLEANUP_DONE" -eq 0 ] || return 0
  discard_pending_botid_notes
  if [ "$HAD_CONFIG_BEFORE_INSTALL" -eq 1 ]; then
    uninstall_flow "keep-config" quiet
    if [ -n "$INSTALL_ROLLBACK_CONFIG" ] && [ -f "$INSTALL_ROLLBACK_CONFIG" ]; then
      cp "$INSTALL_ROLLBACK_CONFIG" "$CONF_FILE" 2>/dev/null || restore_failed=1
      chmod 600 "$CONF_FILE" 2>/dev/null || restore_failed=1
      if [ -f "${INSTALL_ROLLBACK_CONFIG}.botid_notes" ]; then
        cp "${INSTALL_ROLLBACK_CONFIG}.botid_notes" "$DEFAULT_BOTID_NOTES_FILE" 2>/dev/null || restore_failed=1
        chmod 600 "$DEFAULT_BOTID_NOTES_FILE" 2>/dev/null || restore_failed=1
      else
        rm -f "$DEFAULT_BOTID_NOTES_FILE" || restore_failed=1
      fi
    fi
  else
    uninstall_flow "purge" quiet
  fi
  INSTALL_CLEANUP_DONE=1
  return "$restore_failed"
}

install_exit_handler() {
  local status=$?
  if [ "$INSTALL_COMPLETED" -eq 0 ] \
    && [ "$INSTALL_CLEANUP_DONE" -eq 0 ] \
    && [ "$INSTALL_SKIP_AUTO_CLEANUP" -eq 0 ]; then
    if cleanup_interrupted_install; then
      [ "$status" -eq 0 ] || warn "安装未完成，已清理本次变更并恢复安装前状态。"
    else
      err "安装未完成且原配置恢复失败，请检查备份: ${INSTALL_ROLLBACK_CONFIG:-无}"
    fi
  fi
  return "$status"
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

is_no() {
  case "${1:-}" in
    n|N|no|NO) return 0 ;;
    *) return 1 ;;
  esac
}

yes_no_text() {
  is_yes "${1:-}" && printf '已开启' || printf '已关闭'
}

normalize_yes_no() {
  local value="${1:-}" default_value="${2:-n}"
  if is_yes "$value"; then
    printf 'y'
  elif is_no "$value"; then
    printf 'n'
  else
    printf '%s' "$default_value"
  fi
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

validate_yes_no() {
  is_yes "${1:-}" || is_no "${1:-}"
}

validate_interface_name() {
  [[ -z "${1:-}" || "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]
}

interface_exists() {
  local name="${1:-}"
  [ -z "$name" ] && return 0
  [ -d "/sys/class/net/${name}" ] && return 0
  command_exists ip && ip link show dev "$name" >/dev/null 2>&1
}

validate_bind_address() {
  local value="${1:-}" port
  [ -z "$value" ] && return 0
  if [[ "$value" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    return 0
  fi
  if [[ "$value" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[2]}"
  elif [[ "$value" =~ ^([A-Za-z0-9._-]+):([0-9]+)$ ]]; then
    port="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  validate_port "$port"
}

validate_allow_ips() {
  [[ "${1:-}" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?(,[0-9A-Fa-f:.]+(/[0-9]{1,3})?)*$ ]]
}

validate_absolute_file_path() {
  local value="${1:-}"
  [ -z "$value" ] && return 0
  [[ "$value" == /* && "$value" != *\"* && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_pprof_address() {
  local value="${1:-}" port
  [ -z "$value" ] && return 0
  if [[ "$value" =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "$value" =~ ^\[::1\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  validate_port "$port"
}

validate_core_version() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_botid() {
  [[ -z "${1:-}" || "${1:-}" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

validate_single_botid() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

normalize_botid_list() {
  local raw="${1:-}"
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  raw=$(printf '%s' "$raw" | sed -e 's/，/,/g' -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')
  printf '%s' "$raw"
}

botid_exists() {
  local id="$1"
  case ",${WHITELIST:-}," in
    *,"$id",*) return 0 ;;
    *) return 1 ;;
  esac
}

add_botids_to_whitelist() {
  local ids="$1" id result _botid_items
  result="${WHITELIST:-}"
  IFS=',' read -r -a _botid_items <<< "$ids"
  for id in "${_botid_items[@]}"; do
    [ -n "$id" ] || continue
    case ",${result}," in
      *,"$id",*) ;;
      *) result="${result:+$result,}$id" ;;
    esac
  done
  WHITELIST="$result"
}

remove_botids_from_whitelist() {
  local ids="$1" item result _whitelist_items
  result=""
  IFS=',' read -r -a _whitelist_items <<< "${WHITELIST:-}"
  for item in "${_whitelist_items[@]}"; do
    [ -n "$item" ] || continue
    case ",${ids}," in
      *,"$item",*) ;;
      *) result="${result:+$result,}$item" ;;
    esac
  done
  WHITELIST="$result"
}

ensure_botid_notes_file() {
  mkdir -p "$INSTALL_DIR"
  [ -f "$BOTID_NOTES_FILE" ] || : > "$BOTID_NOTES_FILE"
  chmod 600 "$BOTID_NOTES_FILE" 2>/dev/null || true
}

discard_pending_botid_notes() {
  if [ -n "$PENDING_BOTID_NOTES_FILE" ]; then
    rm -f "$PENDING_BOTID_NOTES_FILE"
    PENDING_BOTID_NOTES_FILE=""
    BOTID_NOTES_FILE="$DEFAULT_BOTID_NOTES_FILE"
  fi
}

commit_pending_botid_notes() {
  [ -n "$PENDING_BOTID_NOTES_FILE" ] || return 0
  if [ -f "$PENDING_BOTID_NOTES_FILE" ]; then
    mv -f "$PENDING_BOTID_NOTES_FILE" "$DEFAULT_BOTID_NOTES_FILE" || return 1
    chmod 600 "$DEFAULT_BOTID_NOTES_FILE" 2>/dev/null || true
  else
    rm -f "$DEFAULT_BOTID_NOTES_FILE" || return 1
  fi
  PENDING_BOTID_NOTES_FILE=""
  BOTID_NOTES_FILE="$DEFAULT_BOTID_NOTES_FILE"
}

get_botid_note() {
  local id="$1"
  [ -f "$BOTID_NOTES_FILE" ] || return 0
  awk -F '\t' -v id="$id" '$1 == id {print $2; exit}' "$BOTID_NOTES_FILE" 2>/dev/null
}

set_botid_note() {
  local id="$1" note="${2:-}" tmp
  validate_single_botid "$id" || return 1
  ensure_botid_notes_file
  tmp="${BOTID_NOTES_FILE}.tmp.$$"
  awk -F '\t' -v id="$id" '$1 != id {print $0}' "$BOTID_NOTES_FILE" > "$tmp" 2>/dev/null || true
  if [ -n "$note" ]; then
    note=$(printf '%s' "$note" | tr '\t\r\n' '   ')
    printf '%s\t%s\n' "$id" "$note" >> "$tmp"
  fi
  mv -f "$tmp" "$BOTID_NOTES_FILE"
  chmod 600 "$BOTID_NOTES_FILE" 2>/dev/null || true
}

remove_botid_notes() {
  local ids="$1" tmp
  [ -f "$BOTID_NOTES_FILE" ] || return 0
  tmp="${BOTID_NOTES_FILE}.tmp.$$"
  awk -F '\t' -v ids=",${ids}," 'index(ids, "," $1 ",") == 0 {print $0}' "$BOTID_NOTES_FILE" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$BOTID_NOTES_FILE"
  chmod 600 "$BOTID_NOTES_FILE" 2>/dev/null || true
}

clear_botid_notes() {
  ensure_botid_notes_file
  : > "$BOTID_NOTES_FILE"
}

backup_botid_notes_snapshot() {
  local __had_var="$1" __file_var="$2" tmp_notes
  printf -v "$__had_var" 0
  printf -v "$__file_var" ''
  if [ -f "$BOTID_NOTES_FILE" ]; then
    printf -v "$__had_var" 1
    mkdir -p "$TMP_DIR"
    tmp_notes=$(mktemp "${TMP_DIR}/botid-notes.XXXXXX" 2>/dev/null || mktemp /tmp/botid-notes.XXXXXX)
    cp "$BOTID_NOTES_FILE" "$tmp_notes" 2>/dev/null || true
    printf -v "$__file_var" '%s' "$tmp_notes"
  fi
}

restore_botid_notes_snapshot() {
  local had_notes="$1" old_notes="$2"
  if [ "$had_notes" -eq 1 ]; then
    [ -n "$old_notes" ] && cp "$old_notes" "$BOTID_NOTES_FILE" 2>/dev/null || true
  else
    rm -f "$BOTID_NOTES_FILE"
  fi
}

cleanup_botid_notes_snapshot() {
  local old_notes="$1"
  [ -n "$old_notes" ] && rm -f "$old_notes"
}

print_botid_whitelist_table() {
  local id note index=1 _whitelist_items
  if [ -z "${WHITELIST:-}" ]; then
    echo "  BotID 白名单       : 允许所有"
    return 0
  fi

  echo "  BotID 白名单:"
  IFS=',' read -r -a _whitelist_items <<< "$WHITELIST"
  for id in "${_whitelist_items[@]}"; do
    [ -n "$id" ] || continue
    note=$(get_botid_note "$id")
    [ -n "$note" ] || note="未备注"
    printf "  %-3s %-16s %s\n" "${index}." "$id" "$note"
    index=$((index + 1))
  done
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
    curl -fsSL --connect-timeout 15 --max-time 180 -o "$output" "$url"
  elif command_exists wget; then
    wget -q --timeout=180 -O "$output" "$url"
  else
    return 1
  fi
}

fetch_file_progress() {
  local url="$1" output="$2"
  if command_exists curl; then
    curl -fL --connect-timeout 15 --max-time 180 -o "$output" "$url"
  elif command_exists wget; then
    wget --timeout=180 -O "$output" "$url"
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

normalize_core_version() {
  local version="${1:-}"
  version="${version#v}"
  version="${version#V}"
  printf '%s' "$version"
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
  version=$(normalize_core_version "$version")
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  file="${BIN_NAME}-${version}.tar.gz"
  url="https://github.com/${CORE_REPO}/releases/download/${version}/${file}"

  say "下载喵速核心: ${version}" >&2
  fetch_file_progress "$url" "${work_dir}/${file}" || return 1

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
    [ "$quiet" = "1" ] || say "当前为远程执行模式，正在保存本地管理脚本..."
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
  CORE_VERSION=$(get_conf CORE_VERSION)
  CORE_UPDATE_POLICY=$(get_conf CORE_UPDATE_POLICY)
  ENABLE_IPV6=$(get_conf ENABLE_IPV6)
  ENABLE_UPLOAD=$(get_conf ENABLE_UPLOAD)
  ENABLE_DOWNLOAD_SPEED=$(get_conf ENABLE_DOWNLOAD_SPEED)
  OUTBOUND_INTERFACE=$(get_conf OUTBOUND_INTERFACE)
  VERBOSE_LOG=$(get_conf VERBOSE_LOG)
  BIND_ADDRESS=$(get_conf BIND_ADDRESS)
  ALLOW_IPS=$(get_conf ALLOW_IPS)
  CLIENT_CA_FILE=$(get_conf CLIENT_CA_FILE)
  SERVER_PUBLIC_KEY_FILE=$(get_conf SERVER_PUBLIC_KEY_FILE)
  SERVER_PRIVATE_KEY_FILE=$(get_conf SERVER_PRIVATE_KEY_FILE)
  PPROF_ADDRESS=$(get_conf PPROF_ADDRESS)

  PORT="${PORT:-}"
  PATH_WS="${PATH_WS:-}"
  TOKEN="${TOKEN:-}"
  WHITELIST="${WHITELIST:-}"
  CONNTHREAD="${CONNTHREAD:-$DEFAULT_CONN}"
  TASKLIMIT="${TASKLIMIT:-150}"
  SPEEDLIMIT="${SPEEDLIMIT:-0}"
  PAUSESECOND="${PAUSESECOND:-0}"
  USE_MMDB="${USE_MMDB:-n}"
  CORE_VERSION="$(normalize_core_version "${CORE_VERSION:-}")"
  ENABLE_IPV6=$(normalize_yes_no "$ENABLE_IPV6" n)
  ENABLE_UPLOAD=$(normalize_yes_no "$ENABLE_UPLOAD" n)
  ENABLE_DOWNLOAD_SPEED=$(normalize_yes_no "$ENABLE_DOWNLOAD_SPEED" y)
  OUTBOUND_INTERFACE="${OUTBOUND_INTERFACE:-}"
  VERBOSE_LOG=$(normalize_yes_no "$VERBOSE_LOG" y)
  BIND_ADDRESS="${BIND_ADDRESS:-}"
  ALLOW_IPS="${ALLOW_IPS:-0.0.0.0/0}"
  CLIENT_CA_FILE="${CLIENT_CA_FILE:-}"
  SERVER_PUBLIC_KEY_FILE="${SERVER_PUBLIC_KEY_FILE:-}"
  SERVER_PRIVATE_KEY_FILE="${SERVER_PRIVATE_KEY_FILE:-}"
  PPROF_ADDRESS="${PPROF_ADDRESS:-}"
  case "${CORE_UPDATE_POLICY:-latest}" in
    pinned) CORE_UPDATE_POLICY="pinned" ;;
    *) CORE_UPDATE_POLICY="latest" ;;
  esac
}

write_config() {
  local tmp_conf="${CONF_FILE}.tmp.$$"
  if ! cat > "$tmp_conf" <<EOF
PORT="${PORT}"
PATH_WS="${PATH_WS}"
TOKEN="${TOKEN}"
WHITELIST="${WHITELIST}"
CONNTHREAD="${CONNTHREAD}"
TASKLIMIT="${TASKLIMIT}"
SPEEDLIMIT="${SPEEDLIMIT}"
PAUSESECOND="${PAUSESECOND}"
USE_MMDB="${USE_MMDB}"
CORE_VERSION="${CORE_VERSION}"
CORE_UPDATE_POLICY="${CORE_UPDATE_POLICY}"
ENABLE_IPV6="${ENABLE_IPV6}"
ENABLE_UPLOAD="${ENABLE_UPLOAD}"
ENABLE_DOWNLOAD_SPEED="${ENABLE_DOWNLOAD_SPEED}"
OUTBOUND_INTERFACE="${OUTBOUND_INTERFACE}"
VERBOSE_LOG="${VERBOSE_LOG}"
BIND_ADDRESS="${BIND_ADDRESS}"
ALLOW_IPS="${ALLOW_IPS}"
CLIENT_CA_FILE="${CLIENT_CA_FILE}"
SERVER_PUBLIC_KEY_FILE="${SERVER_PUBLIC_KEY_FILE}"
SERVER_PRIVATE_KEY_FILE="${SERVER_PRIVATE_KEY_FILE}"
PPROF_ADDRESS="${PPROF_ADDRESS}"
EOF
  then
    rm -f "$tmp_conf"
    return 1
  fi
  if chmod 600 "$tmp_conf" && mv -f "$tmp_conf" "$CONF_FILE"; then
    return 0
  fi
  rm -f "$tmp_conf"
  return 1
}

validate_runtime_configuration() {
  validate_port "$PORT" || { err "监听端口必须是 1-65535 之间的数字。"; return 1; }
  validate_path "$PATH_WS" || { err "WebSocket 路径包含非法字符。"; return 1; }
  validate_token "$TOKEN" || { err "连接 Token 包含非法字符。"; return 1; }
  validate_botid "$WHITELIST" || { err "BotID 白名单格式无效。"; return 1; }
  validate_positive_uint "$CONNTHREAD" || { err "最大并发数必须是大于 0 的整数。"; return 1; }
  validate_positive_uint "$TASKLIMIT" || { err "任务队列上限必须是大于 0 的整数。"; return 1; }
  validate_uint "$SPEEDLIMIT" || { err "测速限速必须是非负整数。"; return 1; }
  validate_uint "$PAUSESECOND" || { err "任务间隔必须是非负整数。"; return 1; }
  validate_yes_no "$ENABLE_IPV6" || { err "IPv6 节点测试开关无效。"; return 1; }
  validate_yes_no "$ENABLE_UPLOAD" || { err "上传测速开关无效。"; return 1; }
  validate_yes_no "$ENABLE_DOWNLOAD_SPEED" || { err "下载测速开关无效。"; return 1; }
  validate_yes_no "$VERBOSE_LOG" || { err "详细日志开关无效。"; return 1; }
  validate_interface_name "$OUTBOUND_INTERFACE" || { err "出站接口名称包含非法字符。"; return 1; }
  interface_exists "$OUTBOUND_INTERFACE" || { err "未找到出站接口 ${OUTBOUND_INTERFACE}。"; return 1; }
  validate_bind_address "$BIND_ADDRESS" || { err "监听地址格式无效，请使用 IP:端口、[IPv6]:端口或 Unix Socket 路径。"; return 1; }
  validate_allow_ips "$ALLOW_IPS" || { err "入站 IP/CIDR 白名单格式无效。"; return 1; }
  validate_absolute_file_path "$CLIENT_CA_FILE" || { err "客户端 CA 必须使用不含双引号或换行的绝对路径。"; return 1; }
  validate_absolute_file_path "$SERVER_PUBLIC_KEY_FILE" || { err "服务端证书必须使用不含双引号或换行的绝对路径。"; return 1; }
  validate_absolute_file_path "$SERVER_PRIVATE_KEY_FILE" || { err "服务端私钥必须使用不含双引号或换行的绝对路径。"; return 1; }
  validate_pprof_address "$PPROF_ADDRESS" || { err "pprof 仅允许监听 127.0.0.1:端口或 [::1]:端口。"; return 1; }

  if { [ -n "$SERVER_PUBLIC_KEY_FILE" ] && [ -z "$SERVER_PRIVATE_KEY_FILE" ]; } \
    || { [ -z "$SERVER_PUBLIC_KEY_FILE" ] && [ -n "$SERVER_PRIVATE_KEY_FILE" ]; }; then
    err "自定义服务端证书和私钥必须同时配置。"
    return 1
  fi

  local file label
  for label in "客户端 CA" "服务端证书" "服务端私钥"; do
    case "$label" in
      "客户端 CA") file="$CLIENT_CA_FILE" ;;
      "服务端证书") file="$SERVER_PUBLIC_KEY_FILE" ;;
      *) file="$SERVER_PRIVATE_KEY_FILE" ;;
    esac
    if [ -n "$file" ] && [ ! -r "$file" ]; then
      err "${label}文件不存在或不可读: ${file}"
      return 1
    fi
  done
}

core_supports_flag() {
  local binary="$1" flag="$2" help_text
  help_text=$("$binary" server -help 2>&1 || true)
  printf '%s\n' "$help_text" | grep -Eq -- "(^|[[:space:]])${flag}([[:space:]]|$)"
}

validate_core_flag_support() {
  local binary="$1" flag label
  [ -x "$binary" ] || return 0

  while IFS='|' read -r flag label; do
    [ -n "$flag" ] || continue
    if ! core_supports_flag "$binary" "$flag"; then
      err "当前喵速核心不支持 ${flag}（${label}），请升级核心或关闭该选项。"
      return 1
    fi
  done <<EOF
$(is_yes "$ENABLE_IPV6" && echo '-ipv6|IPv6 节点测试')
$(is_yes "$ENABLE_UPLOAD" && echo '-upload|上传测速')
$(is_no "$ENABLE_DOWNLOAD_SPEED" && echo '-nospeed|关闭下载测速')
$([ -n "$OUTBOUND_INTERFACE" ] && echo '-interface|出站接口')
$(is_yes "$VERBOSE_LOG" && echo '-verbose|详细日志')
$([ -n "$CLIENT_CA_FILE" ] && echo '-clientca|客户端证书验证')
$([ -n "$SERVER_PUBLIC_KEY_FILE" ] && echo '-serverpublickey|自定义服务端证书')
$([ -n "$SERVER_PRIVATE_KEY_FILE" ] && echo '-serverprivatekey|自定义服务端私钥')
$([ -n "$PPROF_ADDRESS" ] && echo '-pprof|pprof 诊断')
EOF
}

backup_config() {
  mkdir -p "$BACKUP_DIR"
  LAST_BACKUP_FILE="${BACKUP_DIR}/miaospeed.conf_$(date +%Y%m%d_%H%M%S)_$$_bak"
  cp "$CONF_FILE" "$LAST_BACKUP_FILE"
  if [ -f "$BOTID_NOTES_FILE" ]; then
    cp "$BOTID_NOTES_FILE" "${LAST_BACKUP_FILE}.botid_notes"
  fi
}

latest_config_backup() {
  ls -t "${BACKUP_DIR}"/miaospeed.conf_*_bak 2>/dev/null | head -n 1
}

restore_latest_config_backup() {
  local latest="$1" current_backup run_backup="" had_run=0
  if [ -z "$latest" ] || [ ! -f "$latest" ]; then
    err "未找到可恢复的配置备份。"
    return 1
  fi

  if [ -f "$CONF_FILE" ]; then
    backup_config || {
      err "恢复前备份当前配置失败，已取消恢复。"
      return 1
    }
    current_backup="$LAST_BACKUP_FILE"
  else
    current_backup=""
  fi

  if [ -f "$RUN_SCRIPT" ]; then
    run_backup=$(mktemp "${TMP_DIR}/run.sh.restore.XXXXXX") || {
      err "恢复前备份运行脚本失败，已取消恢复。"
      return 1
    }
    cp -p "$RUN_SCRIPT" "$run_backup" || {
      rm -f "$run_backup"
      err "恢复前备份运行脚本失败，已取消恢复。"
      return 1
    }
    had_run=1
  fi

  cp "$latest" "$CONF_FILE" || {
    [ -n "$run_backup" ] && rm -f "$run_backup"
    err "恢复配置失败。"
    return 1
  }
  chmod 600 "$CONF_FILE"
  if [ -f "${latest}.botid_notes" ]; then
    cp "${latest}.botid_notes" "$BOTID_NOTES_FILE" || true
    chmod 600 "$BOTID_NOTES_FILE" 2>/dev/null || true
  else
    rm -f "$BOTID_NOTES_FILE"
  fi

  say "配置已恢复，正在重启服务..."
  load_config
  if validate_runtime_configuration \
    && validate_core_flag_support "${INSTALL_DIR}/miaospeed" \
    && create_run_script \
    && restart_service_checked; then
    [ -n "$run_backup" ] && rm -f "$run_backup"
    ok "配置已恢复并重启服务。"
    return 0
  fi

  warn "备份配置未能正常启动，正在恢复操作前的配置。"
  if [ -n "$current_backup" ]; then
    cp "$current_backup" "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE" 2>/dev/null || true
    if [ -f "${current_backup}.botid_notes" ]; then
      cp "${current_backup}.botid_notes" "$BOTID_NOTES_FILE" 2>/dev/null || true
      chmod 600 "$BOTID_NOTES_FILE" 2>/dev/null || true
    else
      rm -f "$BOTID_NOTES_FILE"
    fi
  fi
  if [ "$had_run" -eq 1 ]; then
    cp -p "$run_backup" "$RUN_SCRIPT" 2>/dev/null || true
  else
    rm -f "$RUN_SCRIPT"
  fi
  [ -n "$run_backup" ] && rm -f "$run_backup"
  if restart_service_checked; then
    ok "已恢复操作前的配置，服务运行正常。"
  else
    err "配置已回滚，但服务仍未正常运行，请查看日志。"
  fi
  return 1
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

wait_for_service_alive() {
  local attempts="${1:-6}" stable_checks=0
  while [ "$attempts" -gt 0 ]; do
    sleep 1
    if is_service_alive; then
      stable_checks=$((stable_checks + 1))
      [ "$stable_checks" -ge 3 ] && return 0
    else
      stable_checks=0
    fi
    attempts=$((attempts - 1))
  done
  return 1
}

wait_for_service_stopped() {
  local attempts="${1:-5}"
  while [ "$attempts" -gt 0 ]; do
    is_service_alive || return 0
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] && sleep 1
  done
  return 1
}

restart_service_checked() {
  restart_service >/dev/null 2>&1 || return 1
  wait_for_service_alive 6
}

apply_config_and_restart() {
  local run_backup="" had_run=0
  validate_runtime_configuration || return 1
  validate_core_flag_support "${INSTALL_DIR}/miaospeed" || return 1

  if ! backup_config; then
    err "配置备份失败，已取消保存。"
    return 1
  fi

  if [ -f "$RUN_SCRIPT" ]; then
    run_backup=$(mktemp "${TMP_DIR}/run.sh.rollback.XXXXXX") || {
      err "运行脚本备份失败，已取消保存。"
      return 1
    }
    cp -p "$RUN_SCRIPT" "$run_backup" || {
      rm -f "$run_backup"
      err "运行脚本备份失败，已取消保存。"
      return 1
    }
    had_run=1
  fi

  say "正在保存配置、更新运行脚本并重启服务..."
  if write_config && create_run_script && restart_service_checked; then
    [ -n "$run_backup" ] && rm -f "$run_backup"
    ok "服务已重启。"
    return 0
  fi

  warn "新配置未能正常启动，正在恢复原配置和运行脚本。"
  cp "$LAST_BACKUP_FILE" "$CONF_FILE" 2>/dev/null || true
  chmod 600 "$CONF_FILE" 2>/dev/null || true
  if [ "$had_run" -eq 1 ]; then
    cp -p "$run_backup" "$RUN_SCRIPT" 2>/dev/null || true
  else
    rm -f "$RUN_SCRIPT"
  fi
  [ -n "$run_backup" ] && rm -f "$run_backup"
  if restart_service_checked; then
    ok "已恢复原配置，服务运行正常。"
  else
    err "配置已恢复，但服务仍未正常运行，请查看日志。"
  fi
  return 1
}

create_run_script() {
  local tmp_run="${RUN_SCRIPT}.tmp.$$"
  if ! {
    printf '#!/bin/sh\n'
    printf '# MiaoSpeed runtime template: %s\n' "$RUNTIME_TEMPLATE_VERSION"
    cat <<'EOF'
ulimit -n 65535 2>/dev/null
CONF="/opt/miaospeed/miaospeed.conf"

[ -f "$CONF" ] || exit 1

_get() {
  sed -n "s/^$1=//p" "$CONF" | head -n 1 | sed -e 's/^"//' -e 's/"$//'
}

_is_yes() {
  case "${1:-}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

_is_no() {
  case "${1:-}" in n|N|no|NO) return 0 ;; *) return 1 ;; esac
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
ENABLE_IPV6=$(_get ENABLE_IPV6)
ENABLE_UPLOAD=$(_get ENABLE_UPLOAD)
ENABLE_DOWNLOAD_SPEED=$(_get ENABLE_DOWNLOAD_SPEED)
OUTBOUND_INTERFACE=$(_get OUTBOUND_INTERFACE)
VERBOSE_LOG=$(_get VERBOSE_LOG)
BIND_ADDRESS=$(_get BIND_ADDRESS)
ALLOW_IPS=$(_get ALLOW_IPS)
CLIENT_CA_FILE=$(_get CLIENT_CA_FILE)
SERVER_PUBLIC_KEY_FILE=$(_get SERVER_PUBLIC_KEY_FILE)
SERVER_PRIVATE_KEY_FILE=$(_get SERVER_PRIVATE_KEY_FILE)
PPROF_ADDRESS=$(_get PPROF_ADDRESS)

[ -n "$BIND_ADDRESS" ] || BIND_ADDRESS="0.0.0.0:${PORT}"
[ -n "$ALLOW_IPS" ] || ALLOW_IPS="0.0.0.0/0"
[ -n "$ENABLE_DOWNLOAD_SPEED" ] || ENABLE_DOWNLOAD_SPEED="y"
[ -n "$VERBOSE_LOG" ] || VERBOSE_LOG="y"

set -- server -mtls \
  -bind "$BIND_ADDRESS" \
  -allowip "$ALLOW_IPS" \
  -path "$PATH_WS" \
  -token "$TOKEN" \
  -connthread "$CONNTHREAD" \
  -tasklimit "$TASKLIMIT" \
  -speedlimit "$SPEEDLIMIT" \
  -pausesecond "$PAUSESECOND"

_is_yes "$VERBOSE_LOG" && set -- "$@" -verbose
_is_yes "$ENABLE_IPV6" && set -- "$@" -ipv6
_is_yes "$ENABLE_UPLOAD" && set -- "$@" -upload
_is_no "$ENABLE_DOWNLOAD_SPEED" && set -- "$@" -nospeed
[ -n "$OUTBOUND_INTERFACE" ] && set -- "$@" -interface "$OUTBOUND_INTERFACE"
[ -n "$WHITELIST" ] && set -- "$@" -whitelist "$WHITELIST"
[ -n "$CLIENT_CA_FILE" ] && set -- "$@" -clientca "$CLIENT_CA_FILE"
[ -n "$SERVER_PUBLIC_KEY_FILE" ] && set -- "$@" -serverpublickey "$SERVER_PUBLIC_KEY_FILE"
[ -n "$SERVER_PRIVATE_KEY_FILE" ] && set -- "$@" -serverprivatekey "$SERVER_PRIVATE_KEY_FILE"
[ -n "$PPROF_ADDRESS" ] && set -- "$@" -pprof "$PPROF_ADDRESS"

case "$USE_MMDB" in
  y|Y|yes|YES)
    set -- "$@" -mmdb "/opt/miaospeed/data/GeoLite2-ASN.mmdb,/opt/miaospeed/data/GeoLite2-City.mmdb"
    ;;
esac

exec /opt/miaospeed/miaospeed "$@"
EOF
  } > "$tmp_run"; then
    rm -f "$tmp_run"
    return 1
  fi
  if chmod +x "$tmp_run" && mv -f "$tmp_run" "$RUN_SCRIPT"; then
    return 0
  fi
  rm -f "$tmp_run"
  return 1
}

create_service_files() {
  if [ "$SERVICE_MODE" -eq 1 ]; then
    if ! cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
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
    then
      return 1
    fi
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || return 1
  else
    if ! cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
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
    then
      return 1
    fi
    chmod +x "/etc/init.d/${SERVICE_NAME}" || return 1
    /etc/init.d/"$SERVICE_NAME" enable || return 1
  fi

  if command_exists logrotate; then
    if ! cat > /etc/logrotate.d/miaospeed <<EOF
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
    then
      warn "日志轮转配置写入失败，服务安装将继续。"
    fi
  fi
  return 0
}

create_update_script() {
  local tmp_update="${UPDATE_SCRIPT}.tmp.$$"
  if ! {
    printf '#!/bin/bash\n'
    printf '# MiaoSpeed runtime template: %s\n' "$RUNTIME_TEMPLATE_VERSION"
    cat <<'EOF'
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
    curl -fsSL --connect-timeout 15 --max-time 180 -o "$output" "$url"
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

get_conf() {
  local key="$1"
  awk -v key="$key" 'BEGIN { FS="=" } $1 == key {
    sub(/^[^=]*=/, "")
    gsub(/^"/, "")
    gsub(/"$/, "")
    print
    exit
  }' "$CONF" 2>/dev/null
}

set_conf() {
  local key="$1" value="$2" tmp_conf
  tmp_conf="${CONF}.tmp.$$"
  if grep -q "^${key}=" "$CONF"; then
    sed "s|^${key}=.*|${key}=\"${value}\"|" "$CONF" > "$tmp_conf"
  else
    cp "$CONF" "$tmp_conf"
    printf '%s="%s"\n' "$key" "$value" >> "$tmp_conf"
  fi
  mv -f "$tmp_conf" "$CONF"
  chmod 600 "$CONF"
}

CORE_VERSION=$(get_conf CORE_VERSION)
CORE_UPDATE_POLICY=$(get_conf CORE_UPDATE_POLICY)
CORE_VERSION="${CORE_VERSION#v}"
CORE_VERSION="${CORE_VERSION#V}"
CORE_UPDATE_POLICY="${CORE_UPDATE_POLICY:-latest}"
if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
  log "[OK] 当前已锁定喵速版本 ${CORE_VERSION:-unknown}，跳过自动更新。"
  exit 0
fi

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
  set_conf CORE_VERSION "$LAT_VER"
  set_conf CORE_UPDATE_POLICY "latest"
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
  } > "$tmp_update"; then
    rm -f "$tmp_update"
    return 1
  fi
  if chmod +x "$tmp_update" && mv -f "$tmp_update" "$UPDATE_SCRIPT"; then
    return 0
  fi
  rm -f "$tmp_update"
  return 1
}

runtime_files_current() {
  local marker="# MiaoSpeed runtime template: ${RUNTIME_TEMPLATE_VERSION}"
  [ -f "$RUN_SCRIPT" ] && grep -Fqx "$marker" "$RUN_SCRIPT" \
    && [ -f "$UPDATE_SCRIPT" ] && grep -Fqx "$marker" "$UPDATE_SCRIPT"
}

refresh_runtime_files() {
  local force="${1:-}"
  [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ] || return 0
  if [ "$force" != "force" ] && runtime_files_current; then
    return 0
  fi
  create_run_script && create_update_script
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
  load_config
  if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
    echo "版本已锁定，不可用"
  else
    has_cron_line "$UPDATE_SCRIPT" && echo "已开启，每日 04:00" || echo "未开启"
  fi
}

current_core_version() {
  local current
  current=""
  if [ -x "${INSTALL_DIR}/miaospeed" ]; then
    current=$("${INSTALL_DIR}/miaospeed" -version 2>/dev/null | awk '/^version:/ {print $2; exit}' || true)
  fi
  printf '%s' "${current:-unknown}"
}

core_version_status() {
  local current
  current=$(current_core_version)
  load_config
  if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
    printf '当前 %s，锁定 %s' "$current" "${CORE_VERSION:-unknown}"
  else
    printf '当前 %s，跟随最新版' "$current"
  fi
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

effective_bind_address() {
  printf '%s' "${BIND_ADDRESS:-0.0.0.0:${PORT}}"
}

configured_path_text() {
  [ -n "${1:-}" ] && printf '%s' "$1" || printf '未配置'
}

service_status_short() {
  if is_service_alive; then
    printf '%b' "${C_G}运行中${C_0}"
  elif [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || [ -x "/etc/init.d/${SERVICE_NAME}" ]; then
    printf '%b' "${C_Y}已停止${C_0}"
  else
    printf '%b' "${C_R}未安装${C_0}"
  fi
}

print_centered_title() {
  local title="$1" display_width="$2" total_width="${3:-60}" left_padding
  left_padding=$(( (total_width - display_width) / 2 ))
  [ "$left_padding" -lt 0 ] && left_padding=0
  printf '%*s%s\n' "$left_padding" '' "$title"
}

print_kv() {
  local label="$1" value="$2"
  case "$label" in
    "GEOIP 数据库")   echo "  GEOIP 数据库       : ${value}" ;;
    "喵速自动更新")   echo "  喵速自动更新       : ${value}" ;;
    "脚本自动更新")   echo "  脚本自动更新       : ${value}" ;;
    "喵速定时重启")   echo "  喵速定时重启       : ${value}" ;;
    "喵速版本")       echo "  喵速版本           : ${value}" ;;
    "运行状态")       echo -e "  运行状态           : ${value}" ;;
    "状态时间")       echo "  状态时间           : ${value}" ;;
    "脚本版本")       echo "  脚本版本           : ${value}" ;;
    "本地脚本")       echo "  本地脚本           : ${value}" ;;
    "快捷入口")       echo "  快捷入口           : ${value}" ;;
    "运行日志")       echo "  运行日志           : ${value}" ;;
    "监听端口")       echo "  监听端口           : ${value}" ;;
    "监听地址")       echo "  监听地址           : ${value}" ;;
    "WebSocket 路径") echo "  WebSocket 路径     : ${value}" ;;
    "连接 Token")     echo "  连接 Token         : ${value}" ;;
    "BotID 白名单")   echo "  BotID 白名单       : ${value}" ;;
    "最大并发数")     echo "  最大并发数         : ${value}" ;;
    "任务队列上限")   echo "  任务队列上限       : ${value}" ;;
    "测速限速")       echo "  测速限速           : ${value}" ;;
    "任务间隔")       echo "  任务间隔           : ${value}" ;;
    "IPv6 节点测试")  echo "  IPv6 节点测试      : ${value}" ;;
    "上传测速")       echo "  上传测速           : ${value}" ;;
    "下载测速")       echo "  下载测速           : ${value}" ;;
    "出站接口")       echo "  出站接口           : ${value}" ;;
    "详细日志")       echo "  详细日志           : ${value}" ;;
    "入站 IP 白名单") echo "  入站 IP 白名单     : ${value}" ;;
    "客户端 CA")      echo "  客户端 CA          : ${value}" ;;
    "服务端证书")     echo "  服务端证书         : ${value}" ;;
    "服务端私钥")     echo "  服务端私钥         : ${value}" ;;
    "pprof")          echo "  pprof              : ${value}" ;;
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
    "当前版本策略")   echo "  ${number}  当前版本策略       ${value}" ;;
    "检查最新版")     echo "  ${number}  检查最新版         ${value}" ;;
    "更新到最新版")   echo "  ${number}  更新到最新版       ${value}" ;;
    "安装指定版本")   echo "  ${number}  安装指定版本       ${value}" ;;
    "版本锁定")       echo "  ${number}  版本锁定           ${value}" ;;
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
  local show_sensitive="${1:-y}" mmdb_text speed_text
  load_config
  mmdb_text="未启用"
  is_yes "$USE_MMDB" && mmdb_text="已启用"
  speed_text=$(format_speed_text "$SPEEDLIMIT")

  echo
  echo "---------------- 连接参数 ----------------"
  print_kv "监听端口" "$PORT"
  if is_yes "$show_sensitive"; then
    print_kv "WebSocket 路径" "$PATH_WS"
    print_kv "连接 Token" "$TOKEN"
  else
    print_kv "WebSocket 路径" "[已隐藏]"
    print_kv "连接 Token" "[已隐藏]"
  fi

  echo
  echo "---------------- 访问控制 ----------------"
  print_botid_whitelist_table

  echo
  echo "---------------- 运行与测试参数 ----------------"
  print_kv "最大并发数" "$CONNTHREAD"
  print_kv "任务队列上限" "$TASKLIMIT"
  print_kv "测速限速" "$speed_text"
  print_kv "任务间隔" "${PAUSESECOND} 秒"
  print_kv "IPv6 节点测试" "$(yes_no_text "$ENABLE_IPV6")"
  print_kv "上传测速" "$(yes_no_text "$ENABLE_UPLOAD")"
  print_kv "下载测速" "$(yes_no_text "$ENABLE_DOWNLOAD_SPEED")"
  print_kv "出站接口" "${OUTBOUND_INTERFACE:-自动选择}"
  print_kv "详细日志" "$(yes_no_text "$VERBOSE_LOG")"

  echo
  echo "---------------- 高级网络、TLS 与诊断 ----------------"
  print_kv "监听地址" "$(effective_bind_address)"
  print_kv "入站 IP 白名单" "$ALLOW_IPS"
  print_kv "客户端 CA" "$(configured_path_text "$CLIENT_CA_FILE")"
  print_kv "服务端证书" "$(configured_path_text "$SERVER_PUBLIC_KEY_FILE")"
  print_kv "服务端私钥" "$(configured_path_text "$SERVER_PRIVATE_KEY_FILE")"
  print_kv "pprof" "$(configured_path_text "$PPROF_ADDRESS")"

  echo
  echo "---------------- 自动维护 ----------------"
  print_kv "GEOIP 数据库" "$mmdb_text"
  print_kv "喵速自动更新" "$(core_auto_update_status)"
  print_kv "脚本自动更新" "$(script_auto_update_status)"
  print_kv "喵速定时重启" "$(restart_cron_status)"

  echo
  echo "---------------- 版本信息 ----------------"
  print_kv "喵速版本" "$(core_version_status)"
  print_kv "脚本版本" "$SCRIPT_VERSION"

  echo
  echo "---------------- 服务与文件 ----------------"
  service_status_text
  print_kv "本地脚本" "$LOCAL_SCRIPT"
  print_kv "快捷入口" "$LAUNCHER"
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
  [ -n "$BIND_ADDRESS" ] && warn "当前使用自定义监听地址 ${BIND_ADDRESS}；修改监听端口不会改变该地址。"
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

add_botid_menu() {
  local input ids id note old_whitelist old_notes had_notes=0 existed=0 changed=0 _botid_items
  load_config
  old_whitelist="$WHITELIST"
  backup_botid_notes_snapshot had_notes old_notes
  trap 'restore_botid_notes_snapshot "$had_notes" "$old_notes"; cleanup_botid_notes_snapshot "$old_notes"; menu_child_interrupt_handler' INT TERM

  read -r -p "请输入要添加的 BotID，多个用英文逗号分隔: " input
  ids=$(normalize_botid_list "$input")
  if [ -z "$ids" ]; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "已取消。"
    return 0
  fi
  validate_botid "$ids" || {
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    err "BotID 仅允许数字和英文逗号。"
    return 1
  }

  IFS=',' read -r -a _botid_items <<< "$ids"
  for id in "${_botid_items[@]}"; do
    [ -n "$id" ] || continue
    if botid_exists "$id"; then
      existed=1
      read -r -p "BotID ${id} 已存在，更新备注 (y/N): " input
      if is_yes "$input"; then
        read -r -p "备注 ${id}（留空清除备注）: " note
        set_botid_note "$id" "$note"
      fi
    else
      add_botids_to_whitelist "$id"
      read -r -p "备注 ${id}（可留空）: " note
      set_botid_note "$id" "$note"
      changed=1
    fi
  done

  if [ "$WHITELIST" != "$old_whitelist" ]; then
    trap menu_child_interrupt_handler INT TERM
    if ! apply_config_and_restart; then
      restore_botid_notes_snapshot "$had_notes" "$old_notes"
    fi
  elif [ "$changed" -eq 0 ] && [ "$existed" -eq 0 ]; then
    echo "访问控制未变化。"
  elif [ "$changed" -eq 0 ]; then
    ok "备注已更新。"
  fi
  cleanup_botid_notes_snapshot "$old_notes"
  trap menu_child_interrupt_handler INT TERM
}

remove_botid_menu() {
  local input ids old_whitelist old_notes had_notes=0
  load_config
  old_whitelist="$WHITELIST"
  backup_botid_notes_snapshot had_notes old_notes
  trap 'restore_botid_notes_snapshot "$had_notes" "$old_notes"; cleanup_botid_notes_snapshot "$old_notes"; menu_child_interrupt_handler' INT TERM

  if [ -z "$WHITELIST" ]; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "当前白名单为空，访问控制为允许所有。"
    return 0
  fi

  read -r -p "请输入要删除的 BotID，多个用英文逗号分隔: " input
  ids=$(normalize_botid_list "$input")
  if [ -z "$ids" ]; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "已取消。"
    return 0
  fi
  validate_botid "$ids" || {
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    err "BotID 仅允许数字和英文逗号。"
    return 1
  }

  remove_botids_from_whitelist "$ids"
  remove_botid_notes "$ids"
  if [ "$WHITELIST" = "$old_whitelist" ]; then
    echo "访问控制未变化。"
  else
    trap menu_child_interrupt_handler INT TERM
    if ! apply_config_and_restart; then
      restore_botid_notes_snapshot "$had_notes" "$old_notes"
    fi
  fi
  cleanup_botid_notes_snapshot "$old_notes"
  trap menu_child_interrupt_handler INT TERM
}

edit_botid_note_menu() {
  local id note old_notes had_notes=0
  load_config
  backup_botid_notes_snapshot had_notes old_notes
  trap 'restore_botid_notes_snapshot "$had_notes" "$old_notes"; cleanup_botid_notes_snapshot "$old_notes"; menu_child_interrupt_handler' INT TERM
  if [ -z "$WHITELIST" ]; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "当前白名单为空，没有可备注的 BotID。"
    return 0
  fi

  read -r -p "请输入要修改备注的 BotID: " id
  id=$(normalize_botid_list "$id")
  validate_single_botid "$id" || {
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    err "BotID 必须是纯数字。"
    return 1
  }
  if ! botid_exists "$id"; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    err "BotID ${id} 不在当前白名单中。"
    return 1
  fi

  read -r -p "请输入新备注，留空表示清除备注: " note
  set_botid_note "$id" "$note"
  ok "备注已更新。"
  cleanup_botid_notes_snapshot "$old_notes"
  trap menu_child_interrupt_handler INT TERM
}

clear_whitelist_menu() {
  local confirm old_notes had_notes=0
  load_config
  backup_botid_notes_snapshot had_notes old_notes
  trap 'restore_botid_notes_snapshot "$had_notes" "$old_notes"; cleanup_botid_notes_snapshot "$old_notes"; menu_child_interrupt_handler' INT TERM
  if [ -z "$WHITELIST" ]; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "当前白名单已为空，访问控制为允许所有。"
    return 0
  fi

  read -r -p "清空 BotID 白名单并允许所有 (y/N): " confirm
  if ! is_yes "$confirm"; then
    cleanup_botid_notes_snapshot "$old_notes"
    trap menu_child_interrupt_handler INT TERM
    echo "已取消。"
    return 0
  fi

  WHITELIST=""
  read -r -p "同时清空 BotID 备注 (y/N): " confirm
  if is_yes "$confirm"; then
    clear_botid_notes
  fi
  trap menu_child_interrupt_handler INT TERM
  if ! apply_config_and_restart; then
    restore_botid_notes_snapshot "$had_notes" "$old_notes"
  fi
  cleanup_botid_notes_snapshot "$old_notes"
  trap menu_child_interrupt_handler INT TERM
}

edit_access_control() {
  local choice
  while true; do
    clear_screen
    echo "=================================================="
    echo "                修改访问控制"
    echo "=================================================="
    load_config
    print_botid_whitelist_table
    echo "--------------------------------------------------"
    echo "  1.  添加 BotID"
    echo "  2.  删除 BotID"
    echo "  3.  修改备注"
    echo "  4.  清空白名单"
    echo "  0.  返回主菜单"
    echo "=================================================="
    read -r -p "请输入序号: " choice

    case "$choice" in
      1) add_botid_menu; pause_menu ;;
      2) remove_botid_menu; pause_menu ;;
      3) edit_botid_note_menu; pause_menu ;;
      4) clear_whitelist_menu; pause_menu ;;
      0) return ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

prompt_yes_no_setting() {
  local variable="$1" label="$2" show_current="${3:-y}" input current options
  current=$(yes_no_text "${!variable}")
  if is_yes "${!variable}"; then
    options="Y/n"
  else
    options="y/N"
  fi
  if is_yes "$show_current"; then
    read -r -p "${label} [当前 ${current}] (${options}): " input
  else
    read -r -p "${label} (${options}): " input
  fi
  [ -z "$input" ] && return 0
  if is_yes "$input"; then
    printf -v "$variable" 'y'
  elif is_no "$input"; then
    printf -v "$variable" 'n'
  else
    err "请输入 y 或 n。"
    return 1
  fi
}

prompt_advanced_runtime_params() {
  local input current_bind
  current_bind="${BIND_ADDRESS:-默认 0.0.0.0:${PORT}}"

  echo
  echo "---------------- 高级网络与 TLS 参数 ----------------"
  read -r -p "监听地址 [当前 ${current_bind}]（回车保持，- 恢复默认）: " input
  if [ "$input" = "-" ]; then
    BIND_ADDRESS=""
  elif [ -n "$input" ]; then
    validate_bind_address "$input" || { err "监听地址格式无效。"; return 1; }
    BIND_ADDRESS="$input"
  fi

  read -r -p "入站 IP/CIDR 白名单 [当前 ${ALLOW_IPS}]: " input
  if [ -n "$input" ]; then
    validate_allow_ips "$input" || { err "入站 IP/CIDR 白名单格式无效。"; return 1; }
    ALLOW_IPS="$input"
  fi

  read -r -p "客户端 CA 文件 [当前 ${CLIENT_CA_FILE:-未配置}]（回车保持，- 清空）: " input
  if [ "$input" = "-" ]; then
    CLIENT_CA_FILE=""
  elif [ -n "$input" ]; then
    validate_absolute_file_path "$input" || { err "客户端 CA 必须使用绝对路径。"; return 1; }
    CLIENT_CA_FILE="$input"
  fi

  read -r -p "服务端证书文件 [当前 ${SERVER_PUBLIC_KEY_FILE:-未配置}]（回车保持，- 清空）: " input
  if [ "$input" = "-" ]; then
    SERVER_PUBLIC_KEY_FILE=""
  elif [ -n "$input" ]; then
    validate_absolute_file_path "$input" || { err "服务端证书必须使用绝对路径。"; return 1; }
    SERVER_PUBLIC_KEY_FILE="$input"
  fi

  read -r -p "服务端私钥文件 [当前 ${SERVER_PRIVATE_KEY_FILE:-未配置}]（回车保持，- 清空）: " input
  if [ "$input" = "-" ]; then
    SERVER_PRIVATE_KEY_FILE=""
  elif [ -n "$input" ]; then
    validate_absolute_file_path "$input" || { err "服务端私钥必须使用绝对路径。"; return 1; }
    SERVER_PRIVATE_KEY_FILE="$input"
  fi

  read -r -p "pprof 地址 [当前 ${PPROF_ADDRESS:-未配置}]（仅 loopback，回车保持，- 清空）: " input
  if [ "$input" = "-" ]; then
    PPROF_ADDRESS=""
  elif [ -n "$input" ]; then
    validate_pprof_address "$input" || { err "pprof 仅允许 127.0.0.1:端口或 [::1]:端口。"; return 1; }
    PPROF_ADDRESS="$input"
  fi
}

edit_runtime_params() {
  local old_state new_state input speed_gbps
  load_config
  old_state=$(declare -p CONNTHREAD TASKLIMIT SPEEDLIMIT PAUSESECOND ENABLE_IPV6 ENABLE_UPLOAD \
    ENABLE_DOWNLOAD_SPEED OUTBOUND_INTERFACE VERBOSE_LOG BIND_ADDRESS ALLOW_IPS CLIENT_CA_FILE \
    SERVER_PUBLIC_KEY_FILE SERVER_PRIVATE_KEY_FILE PPROF_ADDRESS 2>/dev/null)
  speed_gbps=$(bytes_to_gbps "$SPEEDLIMIT")

  echo
  echo "---------------- 修改运行与测试参数 ----------------"
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

  prompt_yes_no_setting ENABLE_IPV6 "启用 IPv6 节点测试" || { pause_menu; return; }
  prompt_yes_no_setting ENABLE_UPLOAD "启用上传测速" || { pause_menu; return; }
  prompt_yes_no_setting ENABLE_DOWNLOAD_SPEED "启用下载测速" || { pause_menu; return; }
  prompt_yes_no_setting VERBOSE_LOG "启用详细日志" || { pause_menu; return; }

  read -r -p "出站网络接口 [当前 ${OUTBOUND_INTERFACE:-自动选择}]（回车保持，- 清空）: " input
  if [ "$input" = "-" ]; then
    OUTBOUND_INTERFACE=""
  elif [ -n "$input" ]; then
    validate_interface_name "$input" || { err "出站接口名称包含非法字符。"; pause_menu; return; }
    interface_exists "$input" || { err "未找到网络接口 ${input}。"; pause_menu; return; }
    OUTBOUND_INTERFACE="$input"
  fi

  read -r -p "修改高级网络、TLS 与诊断参数 (y/N): " input
  if is_yes "$input"; then
    prompt_advanced_runtime_params || { pause_menu; return; }
  elif [ -n "$input" ] && ! is_no "$input"; then
    err "请输入 y 或 n。"
    pause_menu
    return
  fi

  new_state=$(declare -p CONNTHREAD TASKLIMIT SPEEDLIMIT PAUSESECOND ENABLE_IPV6 ENABLE_UPLOAD \
    ENABLE_DOWNLOAD_SPEED OUTBOUND_INTERFACE VERBOSE_LOG BIND_ADDRESS ALLOW_IPS CLIENT_CA_FILE \
    SERVER_PUBLIC_KEY_FILE SERVER_PRIVATE_KEY_FILE PPROF_ADDRESS 2>/dev/null)
  if [ "$new_state" = "$old_state" ]; then
    echo "运行与测试参数未变化。"
  else
    apply_config_and_restart
  fi
  pause_menu
}

install_core_version() {
  local target_version="$1" work_dir binary_path ts bin_bak conf_bak
  target_version=$(normalize_core_version "$target_version")
  validate_core_version "$target_version" || {
    err "版本号包含非法字符。"
    return 1
  }

  work_dir="${TMP_DIR}/manual-version-work"
  binary_path=$(download_core_to_workdir "$target_version" "$work_dir") || {
    rm -rf "$work_dir"
    err "指定版本下载或校验失败。"
    return 1
  }
  if ! validate_core_flag_support "$binary_path"; then
    rm -rf "$work_dir"
    err "目标核心版本与当前运行参数不兼容，已取消切换。"
    return 1
  fi

  mkdir -p "$BACKUP_DIR"
  ts=$(date +%Y%m%d_%H%M%S)
  bin_bak="${BACKUP_DIR}/miaospeed_${ts}_bak"
  conf_bak="${BACKUP_DIR}/miaospeed.conf_${ts}_bak"
  cp -p "${INSTALL_DIR}/miaospeed" "$bin_bak" || {
    rm -rf "$work_dir"
    err "主程序备份失败，已取消。"
    return 1
  }
  cp -p "$CONF_FILE" "$conf_bak" || {
    rm -rf "$work_dir"
    err "配置备份失败，已取消。"
    return 1
  }

  say "正在切换喵速版本..."
  stop_service >/dev/null 2>&1 || true
  cp "$binary_path" "${INSTALL_DIR}/miaospeed.new" || {
    start_service >/dev/null 2>&1 || true
    rm -rf "$work_dir"
    err "写入新版本失败。"
    return 1
  }
  chmod +x "${INSTALL_DIR}/miaospeed.new"
  mv -f "${INSTALL_DIR}/miaospeed.new" "${INSTALL_DIR}/miaospeed"
  start_service >/dev/null 2>&1 || true
  sleep 5

  if is_service_alive; then
    CORE_VERSION="$target_version"
    write_config
    create_update_script
    rm -rf "$work_dir"
    ok "喵速已切换到版本 ${target_version}。"
    return 0
  fi

  warn "新版本启动失败，正在回滚。"
  stop_service >/dev/null 2>&1 || true
  cp -p "$bin_bak" "${INSTALL_DIR}/miaospeed" || {
    rm -rf "$work_dir"
    err "回滚主程序失败，请手动检查: ${bin_bak}"
    return 1
  }
  cp -p "$conf_bak" "$CONF_FILE" >/dev/null 2>&1 || true
  chmod +x "${INSTALL_DIR}/miaospeed"
  start_service >/dev/null 2>&1 || true
  rm -rf "$work_dir"
  if is_service_alive; then
    ok "已恢复旧版本。"
  else
    err "回滚后服务仍未运行，请查看日志。"
  fi
  return 1
}

core_update_menu() {
  local choice latest_version input confirm current lock_after_install
  while true; do
    clear_screen
    echo "=================================================="
    echo "                检查喵速更新"
    echo "=================================================="
    load_config
    print_menu_item "1." "当前版本策略" "$(core_version_status)"
    print_menu_item "2." "检查最新版" "从 GitHub 获取"
    print_menu_item "3." "更新到最新版" "解除锁定并更新"
    print_menu_item "4." "安装指定版本" "可选择锁定"
    if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
      print_menu_item "5." "版本锁定" "已锁定 ${CORE_VERSION:-unknown}"
    else
      print_menu_item "5." "版本锁定" "未锁定"
    fi
    echo "--------------------------------------------------"
    echo "  0.  返回主菜单"
    echo "=================================================="
    read -r -p "请输入序号: " choice

    case "$choice" in
      1)
        echo
        print_kv "喵速版本" "$(core_version_status)"
        pause_menu
        ;;
      2)
        say "获取喵速最新版本..."
        latest_version=$(get_latest_core_version || true)
        if [ -n "$latest_version" ]; then
          ok "最新版本: ${latest_version}"
        else
          err "获取最新版本失败。"
        fi
        pause_menu
        ;;
      3)
        say "获取喵速最新版本..."
        latest_version=$(get_latest_core_version || true)
        if [ -z "$latest_version" ]; then
          err "获取最新版本失败。"
          pause_menu
          continue
        fi
        read -r -p "更新到最新版 ${latest_version} 并解除版本锁定 (y/N): " confirm
        if is_yes "$confirm"; then
          load_config
          CORE_UPDATE_POLICY="latest"
          CORE_VERSION="$(normalize_core_version "$latest_version")"
          if install_core_version "$latest_version"; then
            read -r -p "恢复每日 04:00 喵速自动更新 (y/N): " confirm
            is_yes "$confirm" && enable_core_auto_update >/dev/null 2>&1
          fi
        else
          echo "已取消。"
        fi
        pause_menu
        ;;
      4)
        read -r -p "请输入喵速版本号，例如 4.6.8 或 v4.6.8: " input
        input=$(normalize_core_version "$input")
        if [ -z "$input" ]; then
          echo "已取消。"
          pause_menu
          continue
        fi
        validate_core_version "$input" || {
          err "版本号包含非法字符。"
          pause_menu
          continue
        }
        read -r -p "安装后锁定该版本并关闭喵速自动更新 (Y/n): " confirm
        load_config
        lock_after_install=0
        if [ -z "$confirm" ] || is_yes "$confirm"; then
          CORE_UPDATE_POLICY="pinned"
          lock_after_install=1
        else
          CORE_UPDATE_POLICY="latest"
        fi
        CORE_VERSION="$input"
        if install_core_version "$input" && [ "$lock_after_install" -eq 1 ]; then
          disable_core_auto_update >/dev/null 2>&1 || true
          ok "喵速自动更新已关闭。"
        fi
        pause_menu
        ;;
      5)
        load_config
        if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
          read -r -p "解除当前版本锁定 ${CORE_VERSION:-unknown} (y/N): " confirm
          if is_yes "$confirm"; then
            CORE_UPDATE_POLICY="latest"
            current=$(current_core_version)
            if [ "$current" != "unknown" ]; then
              CORE_VERSION="$(normalize_core_version "$current")"
            fi
            write_config
            create_update_script
            ok "已解除版本锁定。"
            read -r -p "恢复每日 04:00 喵速自动更新 (y/N): " confirm
            is_yes "$confirm" && enable_core_auto_update >/dev/null 2>&1
          fi
        else
          current=$(current_core_version)
          if [ "$current" = "unknown" ]; then
            err "无法识别当前喵速版本，不能锁定。"
            pause_menu
            continue
          fi
          read -r -p "锁定当前喵速版本 ${current} 并关闭喵速自动更新 (y/N): " confirm
          if is_yes "$confirm"; then
            CORE_VERSION="$(normalize_core_version "$current")"
            CORE_UPDATE_POLICY="pinned"
            disable_core_auto_update >/dev/null 2>&1 || true
            write_config
            create_update_script
            ok "已锁定喵速版本 ${CORE_VERSION:-unknown}，喵速自动更新已关闭。"
          fi
        fi
        pause_menu
        ;;
      0) return ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

fetch_remote_script_version() {
  local content
  content=$(fetch_text "$SCRIPT_REMOTE_URL" 2>/dev/null || true)
  printf '%s\n' "$content" | awk -F '"' '/^SCRIPT_VERSION=/ {print $2; exit}'
}

self_update() {
  local remote_version tmp reload_menu="${1:-}"
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
    if [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ]; then
      refresh_runtime_files force \
        || warn "管理脚本无需更新，但运行脚本同步失败；请检查目录权限。"
    fi
    ok "管理脚本已是最新版: ${SCRIPT_VERSION}"
    return 0
  fi

  say "发现管理脚本新版本: ${SCRIPT_VERSION} -> ${remote_version}"
  if validate_script_file "$tmp"; then
    [ -f "$LOCAL_SCRIPT" ] && cp -f "$LOCAL_SCRIPT" "$LOCAL_SCRIPT_BAK"
    mv -f "$tmp" "$LOCAL_SCRIPT"
    chmod 700 "$LOCAL_SCRIPT"
    create_launcher
    if [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ]; then
      /bin/bash "$LOCAL_SCRIPT" --refresh-runtime >/dev/null 2>&1 \
        || warn "管理脚本已更新，但运行脚本同步失败；请稍后运行 miao 重试。"
    fi
    ok "管理脚本已更新到 ${remote_version}。"
    [ "$reload_menu" = "reload-menu" ] && return 111
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
  read -r -p "立即更新管理脚本 (y/N): " confirm
  if is_yes "$confirm"; then
    self_update "reload-menu"
    return $?
  else
    echo "已取消。"
  fi
  pause_menu
}

toggle_geoip() {
  load_config
  if is_yes "$USE_MMDB"; then
    read -r -p "关闭 GEOIP 数据库 (y/N): " confirm
    if is_yes "$confirm"; then
      USE_MMDB="n"
      apply_config_and_restart
    fi
  else
    read -r -p "下载并启用 GEOIP 数据库 (y/N): " confirm
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
    clear_screen
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
        load_config
        if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
          warn "当前已锁定喵速版本，请先在“检查喵速更新”中解除版本锁定。"
        elif has_cron_line "$UPDATE_SCRIPT"; then
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
  local choice confirm count latest script_backup_text
  while true; do
    clear_screen
    count=$(find "$BACKUP_DIR" -type f -name "miaospeed.conf_*_bak" ! -name "*.botid_notes" 2>/dev/null | wc -l | awk '{print $1}')
    latest=$(latest_config_backup)
    script_backup_text="无"
    [ -f "$LOCAL_SCRIPT_BAK" ] && script_backup_text="$LOCAL_SCRIPT_BAK"

    echo "=================================================="
    echo "                备份与清理"
    echo "=================================================="
    echo "配置备份数量: ${count}"
    echo "管理脚本备份: ${script_backup_text}"
    [ -n "${latest:-}" ] && echo "最近配置备份: ${latest}"
    echo "--------------------------------------------------"
    echo "  1.  立即备份配置"
    echo "  2.  恢复最近配置备份"
    echo "  3.  清理 30 天前配置备份"
    echo "  4.  清理所有配置备份"
    echo "  5.  清理管理脚本备份"
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
          read -r -p "恢复最近配置备份并重启服务 (y/N): " confirm
          if is_yes "$confirm"; then
            restore_latest_config_backup "$latest"
          else
            echo "已取消。"
          fi
        fi
        pause_menu
        ;;
      3)
        find "$BACKUP_DIR" -type f \( -name "miaospeed.conf_*_bak" -o -name "miaospeed.conf_*_bak.botid_notes" \) -mtime +30 -exec rm -f {} \; 2>/dev/null
        ok "已清理 30 天前配置备份。"
        pause_menu
        ;;
      4)
        read -r -p "清理所有配置备份文件 (y/N): " confirm
        if is_yes "$confirm"; then
          find "$BACKUP_DIR" -type f \( -name "miaospeed.conf_*_bak" -o -name "miaospeed.conf_*_bak.botid_notes" \) -exec rm -f {} \; 2>/dev/null
          ok "所有配置备份文件已清理。"
        else
          echo "已取消。"
        fi
        pause_menu
        ;;
      5)
        if [ -f "$LOCAL_SCRIPT_BAK" ]; then
          read -r -p "删除管理脚本备份 ${LOCAL_SCRIPT_BAK} (y/N): " confirm
          if is_yes "$confirm"; then
            rm -f "$LOCAL_SCRIPT_BAK"
            ok "管理脚本备份已清理。"
          else
            echo "已取消。"
          fi
        else
          echo "未找到管理脚本备份。"
        fi
        pause_menu
        ;;
      0) return ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

service_control_action() {
  local action="$1"
  case "$action" in
    start)
      if is_service_alive; then
        ok "喵速服务已在运行。"
      elif start_service >/dev/null 2>&1 && wait_for_service_alive 5; then
        ok "喵速服务已启动。"
      else
        err "喵速服务启动失败，请查看日志。"
      fi
      ;;
    stop)
      if ! is_service_alive; then
        ok "喵速服务已处于停止状态。"
      elif stop_service >/dev/null 2>&1 && wait_for_service_stopped 5; then
        ok "喵速服务已停止。"
      else
        err "喵速服务未能正常停止，请查看进程状态。"
      fi
      ;;
    restart)
      if restart_service_checked; then
        ok "喵速服务已重启。"
      else
        err "喵速服务重启失败，请查看日志。"
      fi
      ;;
  esac
  pause_menu
}

show_menu() {
  clear_screen
  load_config
  echo "=================================================="
  echo "              喵速管理控制台"
  echo "=================================================="
  echo "  服务: $(service_status_short) | 核心: $(current_core_version) | IPv6 测试: $(yes_no_text "$ENABLE_IPV6")"
  echo "--------------------------------------------------"
  echo "  [状态与服务]"
  printf "  %-3s %s\n" "1." "查看状态配置"
  printf "  %-3s %s\n" "2." "查看实时日志"
  printf "  %-3s %s\n" "3." "启动服务"
  printf "  %-3s %s\n" "4." "停止服务"
  printf "  %-3s %s\n" "5." "重启服务"
  echo "--------------------------------------------------"
  echo "  [配置修改]"
  printf "  %-3s %s\n" "6." "修改连接参数"
  printf "  %-3s %s\n" "7." "修改访问控制"
  printf "  %-3s %s\n" "8." "修改运行与测试参数"
  echo "--------------------------------------------------"
  echo "  [更新与维护]"
  printf "  %-3s %s\n" "9." "检查喵速更新"
  printf "  %-3s %s\n" "10." "更新管理脚本"
  printf "  %-3s %s\n" "11." "自动维护设置"
  printf "  %-3s %s\n" "12." "备份与清理"
  echo "--------------------------------------------------"
  echo "  [危险操作]"
  printf "  %-3s %s\n" "13." "卸载程序（保留配置）"
  printf "  %-3s %s\n" "14." "彻底清除程序与配置"
  echo "--------------------------------------------------"
  printf "  %-3s %s\n" "0." "退出"
  echo "=================================================="
}

main_menu() {
  local choice action_status
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    err "管理控制台需要交互式终端，请在终端中运行 miao。"
    return 1
  fi
  detect_environment 1
  ensure_dirs
  refresh_runtime_files || warn "运行脚本同步失败，当前服务文件保持不变。"
  while true; do
    trap main_menu_interrupt_handler INT TERM
    show_menu
    read -r -p "请输入序号: " choice
    trap - INT TERM
    case "$choice" in
      1) run_menu_action show_status_config_menu ;;
      2) run_menu_action view_logs_menu ;;
      3) run_menu_action service_control_action start ;;
      4) run_menu_action service_control_action stop ;;
      5) run_menu_action service_control_action restart ;;
      6) run_menu_action edit_connection_params ;;
      7) run_menu_action edit_access_control ;;
      8) run_menu_action edit_runtime_params ;;
      9) run_menu_action core_update_menu ;;
      10)
        run_menu_action script_update_menu
        action_status=$?
        if [ "$action_status" -eq 111 ]; then
          say "管理脚本已更新，正在重新载入新版控制台..."
          exec /bin/bash "$LOCAL_SCRIPT" menu
        fi
        ;;
      11) run_menu_action auto_maintenance_menu ;;
      12) run_menu_action backup_cleanup_menu ;;
      13)
        run_menu_action uninstall_menu_action keep-config
        action_status=$?
        if [ "$action_status" -eq 112 ]; then
          uninstall_flow "keep-config"
          exit 0
        fi
        ;;
      14)
        run_menu_action uninstall_menu_action purge
        action_status=$?
        if [ "$action_status" -eq 113 ]; then
          uninstall_flow "purge"
          exit 0
        fi
        ;;
      0) exit 0 ;;
      *) echo "无效选项。"; pause_menu ;;
    esac
  done
}

prompt_maintenance_settings() {
  echo -e "\n${C_B}=== 阶段四: 自动维护 ===${C_0}"
  prompt_yes_no_setting USE_MMDB "下载并启用 GEOIP 数据库" n || exit 1

  if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
    warn "当前已锁定喵速版本，已跳过喵速自动更新设置。"
    ENABLE_CORE_AUTO_UPDATE="n"
  else
    prompt_yes_no_setting ENABLE_CORE_AUTO_UPDATE "启用每日 04:00 喵速自动更新" n || exit 1
  fi

  prompt_yes_no_setting ENABLE_SCRIPT_AUTO_UPDATE "启用每日 03:30 管理脚本自动更新" n || exit 1
  prompt_yes_no_setting ENABLE_RESTART "启用每日 04:30 喵速定时重启" n || exit 1
}

prompt_initial_config() {
  local input note speed_gbps latest_version="${1:-}"

  echo -e "\n${C_G}=== 安装版本 ===${C_0}"
  if [ -n "$latest_version" ]; then
    read -r -p "喵速版本 (直接回车安装最新版 ${latest_version}，输入版本号可指定): " input
  else
    read -r -p "喵速版本 (直接回车安装默认版本 4.6.1，输入版本号可指定): " input
  fi
  if [ -z "$input" ]; then
    CORE_VERSION="$(normalize_core_version "${latest_version:-4.6.1}")"
    CORE_UPDATE_POLICY="latest"
  else
    CORE_VERSION="$(normalize_core_version "$input")"
    validate_core_version "$CORE_VERSION" || { err "版本号包含非法字符。"; exit 1; }
    read -r -p "锁定该版本并关闭喵速自动更新 (Y/n): " input
    if [ -z "$input" ] || is_yes "$input"; then
      CORE_UPDATE_POLICY="pinned"
    else
      CORE_UPDATE_POLICY="latest"
    fi
  fi

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
  WHITELIST="$(normalize_botid_list "${input:-}")"
  validate_botid "$WHITELIST" || { err "BotID 白名单仅允许数字和英文逗号，或留空。"; exit 1; }
  if [ -n "$WHITELIST" ]; then
    ensure_botid_notes_file
    IFS=',' read -r -a _botid_items <<< "$WHITELIST"
    for input in "${_botid_items[@]}"; do
      [ -n "$input" ] || continue
      read -r -p "备注 ${input}（可留空）: " note
      set_botid_note "$input" "$note"
    done
  fi

  echo -e "\n${C_Y}=== 阶段三: 运行与测试参数 ===${C_0}"
  read -r -p "手工配置运行与测试参数 (y/N): " input
  CONNTHREAD="$DEFAULT_CONN"
  TASKLIMIT=150
  SPEEDLIMIT=0
  PAUSESECOND=0
  ENABLE_IPV6="y"
  ENABLE_UPLOAD="n"
  ENABLE_DOWNLOAD_SPEED="y"
  OUTBOUND_INTERFACE=""
  VERBOSE_LOG="y"
  BIND_ADDRESS=""
  ALLOW_IPS="0.0.0.0/0"
  CLIENT_CA_FILE=""
  SERVER_PUBLIC_KEY_FILE=""
  SERVER_PRIVATE_KEY_FILE=""
  PPROF_ADDRESS=""

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

    prompt_yes_no_setting ENABLE_IPV6 "启用 IPv6 节点测试" n || exit 1
    prompt_yes_no_setting ENABLE_UPLOAD "启用上传测速" n || exit 1
    prompt_yes_no_setting ENABLE_DOWNLOAD_SPEED "启用下载测速" n || exit 1
    prompt_yes_no_setting VERBOSE_LOG "启用详细日志" n || exit 1

    read -r -p "出站网络接口（留空自动选择）: " input
    if [ -n "$input" ]; then
      validate_interface_name "$input" || { err "出站接口名称包含非法字符。"; exit 1; }
      interface_exists "$input" || { err "未找到网络接口 ${input}。"; exit 1; }
      OUTBOUND_INTERFACE="$input"
    fi

    read -r -p "配置高级网络、TLS 与诊断参数 (y/N): " input
    if is_yes "$input"; then
      prompt_advanced_runtime_params || exit 1
    elif [ -n "$input" ] && ! is_no "$input"; then
      err "请输入 y 或 n。"
      exit 1
    fi
  fi

  validate_runtime_configuration || exit 1
  USE_MMDB="n"
  ENABLE_CORE_AUTO_UPDATE="n"
  ENABLE_SCRIPT_AUTO_UPDATE="n"
  ENABLE_RESTART="y"
  prompt_maintenance_settings
}

prepare_install_config() {
  local latest_version="$1" input
  if [ -f "$CONF_FILE" ]; then
    HAD_CONFIG_BEFORE_INSTALL=1
    echo
    warn "检测到保留的配置文件: ${CONF_FILE}"
    read -r -p "复用该配置重新安装 (Y/n): " input
    if [ -z "$input" ] || is_yes "$input"; then
      load_config
      if [ "$CORE_UPDATE_POLICY" != "pinned" ] \
        && { [ "$LATEST_VERSION_FALLBACK" -eq 0 ] || [ -z "$CORE_VERSION" ]; }; then
        CORE_VERSION="$(normalize_core_version "$latest_version")"
        CORE_UPDATE_POLICY="latest"
      elif [ "$CORE_UPDATE_POLICY" != "pinned" ]; then
        warn "最新版查询失败，将沿用保留配置中的核心版本 ${CORE_VERSION}。"
      fi
      validate_runtime_configuration || {
        err "保留配置无效，请修正 ${CONF_FILE} 后重试，或重新安装时选择不复用。"
        exit 1
      }
      ok "已载入保留配置；旧配置缺少 IPv6 开关时将继续保持关闭。"
      ENABLE_CORE_AUTO_UPDATE="n"
      ENABLE_SCRIPT_AUTO_UPDATE="n"
      ENABLE_RESTART="y"
      prompt_maintenance_settings
      return 0
    fi
    if ! is_no "$input"; then
      err "请输入 y 或 n。"
      exit 1
    fi
    PENDING_BOTID_NOTES_FILE="${TMP_DIR}/botid_notes.pending.$$"
    rm -f "$PENDING_BOTID_NOTES_FILE"
    BOTID_NOTES_FILE="$PENDING_BOTID_NOTES_FILE"
    ok "原配置已备份到 ${INSTALL_ROLLBACK_CONFIG}。"
  fi
  prompt_initial_config "$latest_version"
}

install_flow() {
  local latest_version work_dir binary_path
  require_root
  HAD_CONFIG_BEFORE_INSTALL=0
  [ -f "$CONF_FILE" ] && HAD_CONFIG_BEFORE_INSTALL=1
  INSTALL_COMPLETED=0
  INSTALL_CLEANUP_DONE=0
  INSTALL_SKIP_AUTO_CLEANUP=0
  INSTALL_ROLLBACK_CONFIG=""
  LATEST_VERSION_FALLBACK=0
  PENDING_BOTID_NOTES_FILE=""
  BOTID_NOTES_FILE="$DEFAULT_BOTID_NOTES_FILE"
  trap install_exit_handler EXIT
  trap install_interrupt_handler INT TERM
  ensure_dirs
  if [ "$HAD_CONFIG_BEFORE_INSTALL" -eq 1 ]; then
    if ! backup_config; then
      err "安装前备份现有配置失败，已取消安装。"
      exit 1
    fi
    INSTALL_ROLLBACK_CONFIG="$LAST_BACKUP_FILE"
  fi
  detect_environment
  install_local_script
  install_dependencies
  install_local_script 1

  say "获取喵速最新版本..."
  latest_version=$(get_latest_core_version || true)
  if [ -z "$latest_version" ]; then
    warn "获取最新版本失败；新安装将回退至 4.6.1，复用配置时优先沿用记录版本。"
    latest_version="4.6.1"
    LATEST_VERSION_FALLBACK=1
  else
    ok "最新版本: ${latest_version}"
  fi

  prepare_install_config "$latest_version"

  work_dir="${TMP_DIR}/install-work"
  binary_path=$(download_core_to_workdir "$CORE_VERSION" "$work_dir") || {
    err "核心程序下载或校验失败。"
    trap - INT TERM
    exit 1
  }
  if ! validate_core_flag_support "$binary_path"; then
    rm -rf "$work_dir"
    err "所选核心版本与当前运行参数不兼容。"
    trap - INT TERM
    exit 1
  fi

  if is_yes "$USE_MMDB"; then
    if ! download_mmdb; then
      warn "GEOIP 数据库下载失败，已自动关闭 GEOIP。"
      USE_MMDB="n"
    fi
  fi

  say "写入配置与服务文件..."
  if ! write_config || ! create_run_script || ! create_update_script; then
    err "写入配置或运行脚本失败，请检查磁盘空间和目录权限。"
    trap - INT TERM
    exit 1
  fi
  if ! create_service_files; then
    err "系统服务文件创建或启用失败。"
    trap - INT TERM
    exit 1
  fi

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
    if wait_for_service_alive 6; then
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

  if ! commit_pending_botid_notes; then
    warn "新配置已生效，但 BotID 备注写入失败；原备注仍保留在 ${DEFAULT_BOTID_NOTES_FILE}。"
    discard_pending_botid_notes
  fi

  INSTALL_COMPLETED=1
  trap - EXIT INT TERM
  show_install_summary
}

show_install_summary() {
  local mmdb_text speed_text tls_text
  mmdb_text="未启用"
  is_yes "$USE_MMDB" && mmdb_text="已启用 (${DATA_DIR})"
  speed_text=$(format_speed_text "$SPEEDLIMIT")
  tls_text="未配置"
  [ -n "$SERVER_PUBLIC_KEY_FILE" ] && tls_text="已配置"

  echo -e "\n${C_G}============================================================${C_0}"
  print_centered_title "喵速部署完成" 12 60
  echo -e "${C_G}============================================================${C_0}"

  echo -e " ${C_B}[连接参数]${C_0}"
  echo -e " - 监听端口        : ${C_Y}${PORT}${C_0}"
  echo -e " - WebSocket 路径  : ${C_Y}${PATH_WS}${C_0}"
  echo -e " - 连接 Token      : ${C_Y}${TOKEN}${C_0}"

  echo
  echo -e " ${C_B}[访问控制]${C_0}"
  print_botid_whitelist_table

  echo
  echo -e " ${C_B}[运行与测试参数]${C_0}"
  echo -e " - 最大并发数      : ${CONNTHREAD}"
  echo -e " - 任务队列上限    : ${TASKLIMIT}"
  echo -e " - 测速限速        : ${speed_text}"
  echo -e " - 任务间隔        : ${PAUSESECOND} 秒"
  echo -e " - IPv6 节点测试   : $(yes_no_text "$ENABLE_IPV6")"
  echo -e " - 上传测速        : $(yes_no_text "$ENABLE_UPLOAD")"
  echo -e " - 下载测速        : $(yes_no_text "$ENABLE_DOWNLOAD_SPEED")"
  echo -e " - 出站接口        : ${OUTBOUND_INTERFACE:-自动选择}"
  echo -e " - 详细日志        : $(yes_no_text "$VERBOSE_LOG")"

  echo
  echo -e " ${C_B}[高级网络、TLS 与诊断]${C_0}"
  echo -e " - 监听地址        : $(effective_bind_address)"
  echo -e " - 入站 IP 白名单  : ${ALLOW_IPS}"
  echo -e " - 客户端 CA       : $(configured_path_text "$CLIENT_CA_FILE")"
  echo -e " - 自定义服务证书  : ${tls_text}"
  echo -e " - pprof           : $(configured_path_text "$PPROF_ADDRESS")"

  echo
  echo -e " ${C_B}[自动维护]${C_0}"
  echo -e " - GEOIP 数据库    : ${mmdb_text}"
  echo -e " - 喵速自动更新    : $(core_auto_update_status)"
  echo -e " - 脚本自动更新    : $(script_auto_update_status)"
  echo -e " - 喵速定时重启    : $(restart_cron_status)"
  if [ "$CORE_UPDATE_POLICY" = "pinned" ]; then
    echo -e " - 喵速版本        : 已锁定 ${CORE_VERSION:-unknown}"
  else
    echo -e " - 喵速版本        : ${CORE_VERSION:-unknown}，跟随最新版"
  fi

  echo
  echo -e " ${C_B}[管理入口]${C_0}"
  echo -e " - 快捷菜单        : ${C_G}miao${C_0}"
  echo -e " - 本地脚本        : ${LOCAL_SCRIPT}"
  echo -e " - 保留配置卸载    : bash ${LOCAL_SCRIPT} --uninstall"
  echo -e " - 彻底清除        : bash ${LOCAL_SCRIPT} --purge"
  echo -e " - 运行日志        : ${LOG_DIR}/miaospeed.log"
  echo -e "${C_G}============================================================${C_0}"
  if [ -z "$BIND_ADDRESS" ]; then
    echo -e " ${C_R}[!] 请确认云安全组或本机防火墙已放行 TCP 端口 ${PORT}${C_0}"
  else
    echo -e " ${C_R}[!] 请按自定义监听地址 ${BIND_ADDRESS} 检查防火墙与访问路径${C_0}"
  fi
  echo -e "${C_G}============================================================${C_0}"
}

uninstall_flow() {
  local mode="${1:-keep-config}" quiet="${2:-}"
  require_root
  [ "$quiet" = "quiet" ] || say "开始卸载喵速..."

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

  rm -f /etc/logrotate.d/miaospeed /usr/local/bin/miao

  if [ "$mode" = "purge" ]; then
    rm -rf "$INSTALL_DIR"
    rm -f "$LAUNCHER"
    rm -f "$LOCAL_SCRIPT" "$LOCAL_SCRIPT_BAK"
    [ "$quiet" = "quiet" ] || ok "喵速程序、配置、备份和管理脚本已彻底清除。"
  else
    rm -f "${INSTALL_DIR}/miaospeed" "${INSTALL_DIR}/miaospeed.new" "$RUN_SCRIPT" "$UPDATE_SCRIPT"
    rm -rf "$TMP_DIR" "$LOG_DIR"
    rm -f "${DATA_DIR}/GeoLite2-ASN.mmdb" "${DATA_DIR}/GeoLite2-City.mmdb"
    rmdir "$DATA_DIR" 2>/dev/null || true
    [ "$quiet" = "quiet" ] || {
      ok "喵速程序已卸载。"
      echo "已保留: ${CONF_FILE}、${BOTID_NOTES_FILE}、${BACKUP_DIR}"
      echo "重新安装: miao 或 bash ${LOCAL_SCRIPT}"
    }
  fi
}

ensure_installed_or_offer() {
  local confirm
  if [ -f "$CONF_FILE" ] && [ -x "${INSTALL_DIR}/miaospeed" ]; then
    return 0
  fi
  warn "未检测到完整安装。"
  read -r -p "立即开始安装 (y/N): " confirm
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
  bash $0 --uninstall     卸载程序并保留配置
  bash $0 --purge         彻底清除程序、配置和管理脚本

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
      uninstall_flow "keep-config"
      ;;
    --purge)
      if confirm_purge; then
        uninstall_flow "purge"
      else
        echo "已取消。"
      fi
      ;;
    --refresh-runtime)
      if [ ! -f "$CONF_FILE" ] || [ ! -x "${INSTALL_DIR}/miaospeed" ]; then
        err "未检测到完整安装，无法同步运行脚本。"
        exit 1
      fi
      ensure_dirs
      refresh_runtime_files force || {
        err "运行脚本同步失败。"
        exit 1
      }
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
