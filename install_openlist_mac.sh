#!/bin/zsh

set -euo pipefail

MANAGER_DIR="$HOME/.openlist-manager"
MANAGER_PATH="$MANAGER_DIR/openlist-menu.sh"

mkdir -p "$MANAGER_DIR"
rm -f "$MANAGER_DIR/api-token" 2>/dev/null || true

remove_legacy_entry() {
  for legacy in "/usr/local/bin/openlist" "/opt/homebrew/bin/openlist"; do
    if [ -L "$legacy" ] || [ -f "$legacy" ]; then
      rm -f "$legacy" 2>/dev/null || true
    fi
  done
}

warn_if_legacy_remains() {
  local active_cmd
  active_cmd="$(command -v openlist 2>/dev/null || true)"
  if [ -n "$active_cmd" ] && [ "$active_cmd" != "$HOME/.local/bin/openlist" ]; then
    cat <<WARN

注意：当前终端优先使用的 openlist 不是新安装的菜单入口：
  $active_cmd

如果执行 openlist 仍然异常，请手动执行：
  sudo rm -f /usr/local/bin/openlist
  sudo rm -f /opt/homebrew/bin/openlist
  hash -r
  export PATH="\$HOME/.local/bin:\$PATH"
WARN
  fi
}

cat > "$MANAGER_PATH" <<'EOF'
#!/bin/zsh

set -u

# 本地管理脚本版本（上传 GitHub 后，选「更新脚本」才会同步到别人机器）
SCRIPT_VERSION="2026.07.24.2"

APP_NAME="OpenList"
MANAGER_DIR="${OPENLIST_MANAGER_DIR:-$HOME/.openlist-manager}"
MANAGER_PATH="$MANAGER_DIR/openlist-menu.sh"
APP_DIR="$MANAGER_DIR/app"
TMP_DIR="$MANAGER_DIR/tmp"
APP_BIN="$APP_DIR/openlist"
VERSION_FILE="$APP_DIR/version.txt"
ARCHIVE_PATH="$TMP_DIR/openlist.tar.gz"
EXTRACT_DIR="$TMP_DIR/extract"
MD5_LIST_PATH="$TMP_DIR/md5.txt"
DATA_DIR="${OPENLIST_DATA_DIR:-$HOME/Library/Application Support/OpenList/data}"
RUN_DIR="${OPENLIST_RUN_DIR:-$HOME/Library/Application Support/OpenList/run}"
LOG_DIR="${OPENLIST_LOG_DIR:-$HOME/Library/Logs/OpenList}"
LOG_PATH="$LOG_DIR/openlist.log"
PID_PATH="$RUN_DIR/openlist.pid"
PLIST_PATH="${OPENLIST_PLIST_PATH:-$HOME/Library/LaunchAgents/com.openlist.server.plist}"
# 开机自启开关（与是否用 launchd 管进程分开：日常启停一律走 launchd）
AUTOSTART_FLAG="${OPENLIST_AUTOSTART_FLAG:-$MANAGER_DIR/autostart.on}"
INSTALLER_URL="https://raw.githubusercontent.com/xiyingruyi/openlist/main/install_openlist_mac.sh"
GITHUB_REPO="OpenListTeam/OpenList"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases"
LAUNCH_LABEL="${OPENLIST_LAUNCH_LABEL:-com.openlist.server}"
MIN_ARCHIVE_BYTES=1048576
# 日志超过该大小则轮转（50MB）
LOG_MAX_BYTES=52428800
CURL_UA="OpenList-macOS-Manager/${SCRIPT_VERSION}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_msg() {
  local color="$1"
  shift
  printf "%b%s%b\n" "$color" "$*" "$NC"
}

pause() {
  echo
  if [[ -t 0 ]]; then
    read -rsk 1 "REPLY?按任意键返回主菜单..."
  else
    IFS= read -r REPLY || true
  fi
  echo
}

prompt_input() {
  local prompt="$1"

  REPLY=""
  printf "%s" "$prompt"
  IFS= read -r REPLY || return 1
}

prepare_dirs() {
  mkdir -p "$MANAGER_DIR" "$APP_DIR" "$TMP_DIR" "$DATA_DIR" "$RUN_DIR" "$LOG_DIR"
  # LaunchAgents 目录在写 plist 时再确保
}

require_cmd() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_msg "$RED" "缺少命令：$cmd"
    print_msg "$BLUE" "$hint"
    return 1
  fi
  return 0
}

detect_arch() {
  case "$(uname -m)" in
    arm64) echo "arm64" ;;
    x86_64) echo "amd64" ;;
    *)
      print_msg "$RED" "暂不支持当前架构：$(uname -m)"
      return 1
      ;;
  esac
}

asset_name() {
  local arch
  arch="$(detect_arch)" || return 1
  echo "openlist-darwin-${arch}.tar.gz"
}

download_url() {
  local name
  name="$(asset_name)" || return 1
  echo "${GITHUB_RELEASES}/latest/download/${name}"
}

# 精确读取 scheme.http_port（OpenList 真实字段）；失败再兜底
get_http_port() {
  local port=""
  local cfg="$DATA_DIR/config.json"

  if [ -f "$cfg" ]; then
    if command -v python3 >/dev/null 2>&1; then
      port="$(
        python3 - "$cfg" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
scheme = data.get("scheme") or {}
port = scheme.get("http_port")
if port is None:
    port = data.get("http_port")
try:
    port = int(port)
except Exception:
    sys.exit(0)
if port > 0:
    print(port)
PY
      )"
    fi

    # 无 python3 或解析失败：优先匹配 scheme 段内 http_port
    if [ -z "$port" ]; then
      port="$(
        awk '
          /"scheme"[[:space:]]*:/ { in_scheme=1 }
          in_scheme && /"http_port"[[:space:]]*:/ {
            if (match($0, /[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit }
          }
          in_scheme && /}/ { in_scheme=0 }
        ' "$cfg" 2>/dev/null | head -n 1
      )"
    fi
    if [ -z "$port" ]; then
      port="$(sed -n 's/.*"http_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -n 1)"
    fi
  fi

  printf '%s\n' "${port:-5244}"
}

get_console_url() {
  printf 'http://127.0.0.1:%s\n' "$(get_http_port)"
}

normalize_version() {
  printf '%s\n' "$1" | tr -d '\r' | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -n 1
}

read_binary_version() {
  local raw

  if [ ! -x "$APP_BIN" ]; then
    return 1
  fi

  raw="$("$APP_BIN" version 2>/dev/null | grep -E '^[[:space:]]*Version:' | head -n 1)"
  if [ -z "$raw" ]; then
    raw="$("$APP_BIN" version 2>/dev/null | grep -Ei 'Version:' | grep -vi 'Go Version' | head -n 1)"
  fi
  normalize_version "$raw"
}

write_version_file() {
  local version="$1"
  if [ -n "$version" ]; then
    printf '%s\n' "$version" > "$VERSION_FILE"
  fi
}

get_local_version() {
  local bin_ver file_ver

  bin_ver="$(read_binary_version 2>/dev/null || true)"
  if [ -n "$bin_ver" ]; then
    if [ -f "$VERSION_FILE" ]; then
      file_ver="$(normalize_version "$(cat "$VERSION_FILE" 2>/dev/null)")"
      if [ "$file_ver" != "$bin_ver" ]; then
        write_version_file "$bin_ver"
      fi
    else
      write_version_file "$bin_ver"
    fi
    printf '%s\n' "$bin_ver"
    return 0
  fi

  if [ -f "$VERSION_FILE" ]; then
    file_ver="$(normalize_version "$(cat "$VERSION_FILE" 2>/dev/null)")"
    if [ -n "$file_ver" ]; then
      printf '%s\n' "$file_ver"
      return 0
    fi
  fi

  return 1
}

get_latest_version() {
  local raw=""
  local http_body
  local location

  require_cmd "curl" "macOS 通常自带 curl。" || return 1

  http_body="$(curl -fsSL -A "$CURL_UA" \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}/releases/latest" 2>/dev/null || true)"
  if [ -n "$http_body" ]; then
    raw="$(printf '%s\n' "$http_body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  fi

  if [ -z "$raw" ]; then
    location="$(curl -fsSL -A "$CURL_UA" -o /dev/null -w '%{url_effective}' \
      "${GITHUB_RELEASES}/latest" 2>/dev/null || true)"
    raw="$(printf '%s\n' "$location" | grep -Eo 'tag/[^/[:space:]]+' | head -n 1 | sed 's|^tag/||')"
  fi

  normalize_version "$raw"
}

version_to_sort_key() {
  local version
  local a b c d

  version="$1"
  IFS='.' read -r a b c d <<EOFV
$version
EOFV
  a="${a:-0}"
  b="${b:-0}"
  c="${c:-0}"
  d="${d:-0}"
  printf '%05d%05d%05d%05d\n' "$a" "$b" "$c" "$d"
}

is_version_newer() {
  local newer older
  newer="$(version_to_sort_key "$1")"
  older="$(version_to_sort_key "$2")"
  [[ "$newer" > "$older" ]]
}

require_installed() {
  if [ ! -x "$APP_BIN" ]; then
    print_msg "$RED" "未检测到 OpenList，请先安装。"
    return 1
  fi
}

is_running() {
  get_running_pid >/dev/null 2>&1
}

# 兼容旧版：仅有 plist 且 KeepAlive/RunAtLoad 为 true 时视为已开自启
migrate_autostart_flag_if_needed() {
  if [ -f "$AUTOSTART_FLAG" ]; then
    return 0
  fi
  if [ -f "$PLIST_PATH" ] && grep -q '<key>KeepAlive</key>' "$PLIST_PATH" 2>/dev/null; then
    if grep -A1 '<key>KeepAlive</key>' "$PLIST_PATH" 2>/dev/null | grep -q '<true/>'; then
      mkdir -p "$MANAGER_DIR"
      : > "$AUTOSTART_FLAG"
    fi
  fi
}

is_autostart_configured() {
  migrate_autostart_flag_if_needed
  [ -f "$AUTOSTART_FLAG" ]
}

is_autostart_loaded() {
  launchctl print "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null 2>&1
}

pid_command_looks_like_openlist() {
  local pid="$1"
  local cmd

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"$APP_BIN"* ]] || [[ "$cmd" == *"/openlist"* ]] || [[ "$cmd" == *" openlist "* ]]
}

pid_is_openlist_server() {
  local pid="$1"
  local http_port

  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  http_port="$(get_http_port)"
  if lsof -nP -a -p "$pid" -iTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi

  pid_command_looks_like_openlist "$pid"
}

find_pid_by_listen_port() {
  local http_port
  local line pid

  http_port="$(get_http_port)"
  while IFS= read -r line; do
    pid="$(printf '%s\n' "$line" | awk '{print $2}' | head -n 1)"
    if pid_command_looks_like_openlist "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(lsof -nP -iTCP:"$http_port" -sTCP:LISTEN 2>/dev/null || true)

  return 1
}

get_launchd_pid() {
  local launchd_info
  local pid

  launchd_info="$(launchctl print "gui/$(id -u)/${LAUNCH_LABEL}" 2>/dev/null || true)"
  [ -n "$launchd_info" ] || return 1

  printf '%s\n' "$launchd_info" | grep -F "state = running" >/dev/null 2>&1 || return 1

  pid="$(printf '%s\n' "$launchd_info" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)"
  [ -n "$pid" ] || return 1

  if pid_is_openlist_server "$pid" || pid_command_looks_like_openlist "$pid"; then
    printf '%s\n' "$pid"
    return 0
  fi

  return 1
}

get_running_pid() {
  local pid

  pid="$(get_launchd_pid 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    printf '%s\n' "$pid"
    return 0
  fi

  if [ -f "$PID_PATH" ]; then
    pid="$(cat "$PID_PATH" 2>/dev/null)"
    if pid_is_openlist_server "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi

  pid="$(find_pid_by_listen_port 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    printf '%s\n' "$pid" > "$PID_PATH" 2>/dev/null || true
    printf '%s\n' "$pid"
    return 0
  fi

  return 1
}

cleanup_stale_pid() {
  if ! is_running; then
    rm -f "$PID_PATH"
  fi
}

rotate_logs_if_needed() {
  local size

  [ -f "$LOG_PATH" ] || return 0
  size="$(wc -c < "$LOG_PATH" | tr -d '[:space:]')"
  if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    print_msg "$YELLOW" "日志约 ${size} 字节，超过阈值，正在轮转..."
    rm -f "${LOG_PATH}.1"
    mv -f "$LOG_PATH" "${LOG_PATH}.1" 2>/dev/null || true
    : > "$LOG_PATH"
  fi
}

show_initial_password() {
  local initial_password

  initial_password="$(grep -Eo 'initial password is: .*' "$LOG_PATH" 2>/dev/null | tail -n 1 | sed 's/^initial password is: //')"
  if [ -z "$initial_password" ] && [ -f "${LOG_PATH}.1" ]; then
    initial_password="$(grep -Eo 'initial password is: .*' "${LOG_PATH}.1" 2>/dev/null | tail -n 1 | sed 's/^initial password is: //')"
  fi
  if [ -n "$initial_password" ]; then
    print_msg "$GREEN" "首次启动已生成默认管理员信息："
    printf "用户名：%badmin%b\n" "$GREEN" "$NC"
    printf "初始密码：%b%s%b\n" "$GREEN" "$initial_password" "$NC"
  else
    print_msg "$YELLOW" "没有从日志里成功提取到初始密码。"
    print_msg "$BLUE" "你可以在主菜单使用“密码管理”来随机生成或手动设置密码。"
  fi
}

offer_set_password_now() {
  local choice new_pass

  # 非交互环境不要读 stdin，避免把后续脚本/管道内容当密码
  if [[ ! -t 0 ]]; then
    print_msg "$BLUE" "非交互环境，已跳过设置密码。可稍后在菜单使用「密码管理」。"
    return 0
  fi

  echo
  prompt_input "是否现在就设置一个你自己的管理员密码？(Y/N，默认为Y): "
  choice="$REPLY"
  if [[ "$choice" = "n" || "$choice" = "N" ]]; then
    return 0
  fi

  prompt_input "请输入新的管理员密码: "
  new_pass="$REPLY"
  if [ -z "$new_pass" ]; then
    print_msg "$RED" "密码不能为空，已跳过设置。"
    return 1
  fi

  "$APP_BIN" --data "$DATA_DIR" admin set "$new_pass" || {
    print_msg "$RED" "设置密码失败。"
    return 1
  }
  print_msg "$GREEN" "管理员密码已更新为你刚输入的新密码。"
  if is_running; then
    print_msg "$BLUE" "正在重启 OpenList，使新密码立即生效并清除登录封禁..."
    restart_openlist
  fi
}

curl_download() {
  local url="$1"
  local dest="$2"

  require_cmd "curl" "macOS 通常自带 curl。" || return 1

  if [[ -t 1 ]]; then
    curl -fL --connect-timeout 20 --retry 2 --retry-delay 2 \
      -A "$CURL_UA" --progress-bar "$url" -o "$dest"
  else
    curl -fL --connect-timeout 20 --retry 2 --retry-delay 2 \
      -A "$CURL_UA" -sS "$url" -o "$dest"
  fi
}

verify_archive_md5() {
  local archive="$1"
  local name expected actual

  name="$(asset_name)" || return 0

  print_msg "$BLUE" "正在校验安装包 MD5..."
  if ! curl -fsSL -A "$CURL_UA" \
    "${GITHUB_RELEASES}/latest/download/md5.txt" -o "$MD5_LIST_PATH"; then
    print_msg "$YELLOW" "未能下载官方 MD5 清单，已跳过校验（仍保留体积检查）。"
    return 0
  fi

  # 官方格式: <md5>  ./openlist-darwin-arm64.tar.gz
  expected="$(grep -F "$name" "$MD5_LIST_PATH" 2>/dev/null | awk '{print $1}' | head -n 1)"
  if [ -z "$expected" ]; then
    print_msg "$YELLOW" "MD5 清单中未找到 ${name}，已跳过校验。"
    return 0
  fi

  if command -v md5 >/dev/null 2>&1; then
    actual="$(md5 -q "$archive" 2>/dev/null || true)"
  elif command -v md5sum >/dev/null 2>&1; then
    actual="$(md5sum "$archive" 2>/dev/null | awk '{print $1}')"
  else
    print_msg "$YELLOW" "系统无 md5/md5sum，已跳过校验。"
    return 0
  fi

  if [ -z "$actual" ]; then
    print_msg "$YELLOW" "无法计算本地 MD5，已跳过校验。"
    return 0
  fi

  if [ "$actual" != "$expected" ]; then
    print_msg "$RED" "MD5 校验失败。"
    print_msg "$RED" "期望：$expected"
    print_msg "$RED" "实际：$actual"
    return 1
  fi

  print_msg "$GREEN" "MD5 校验通过。"
  return 0
}

download_and_install() {
  local url found_bin latest_version was_running archive_size
  local staged_bin

  latest_version="${1:-}"

  require_cmd "curl" "macOS 通常自带 curl。" || return 1
  require_cmd "tar" "macOS 通常自带 tar。" || return 1
  require_cmd "find" "macOS 通常自带 find。" || return 1
  prepare_dirs

  if [ -z "$latest_version" ]; then
    latest_version="$(get_latest_version)" || true
  fi
  url="$(download_url)" || return 1

  if [ -z "$latest_version" ]; then
    print_msg "$RED" "未能获取 OpenList 官方最新版本信息，请稍后再试。"
    return 1
  fi

  was_running=0
  if is_running; then
    was_running=1
  fi

  print_msg "$BLUE" "正在从 OpenList 官方发布页下载 ${latest_version} ..."
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  rm -f "$ARCHIVE_PATH"

  if ! curl_download "$url" "$ARCHIVE_PATH"; then
    print_msg "$RED" "下载失败，请检查网络后重试。"
    rm -f "$ARCHIVE_PATH"
    return 1
  fi

  if [ ! -f "$ARCHIVE_PATH" ]; then
    print_msg "$RED" "下载失败：未找到安装包文件。"
    return 1
  fi

  archive_size="$(wc -c < "$ARCHIVE_PATH" | tr -d '[:space:]')"
  if [ -z "$archive_size" ] || [ "$archive_size" -lt "$MIN_ARCHIVE_BYTES" ]; then
    print_msg "$RED" "下载文件异常（大小 ${archive_size:-0} 字节），已中止安装。"
    rm -f "$ARCHIVE_PATH"
    return 1
  fi

  if ! verify_archive_md5 "$ARCHIVE_PATH"; then
    rm -f "$ARCHIVE_PATH"
    return 1
  fi

  print_msg "$BLUE" "正在解压安装包（${archive_size} 字节）..."
  if ! tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"; then
    print_msg "$RED" "解压失败，安装包可能损坏。"
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    return 1
  fi

  found_bin="$(find "$EXTRACT_DIR" -type f \( -name 'openlist' -o -name 'OpenList' \) | head -n 1)"
  if [ -z "$found_bin" ] || [ ! -f "$found_bin" ]; then
    print_msg "$RED" "解压后未找到 OpenList 可执行文件。"
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    return 1
  fi

  stop_openlist >/dev/null 2>&1 || true

  staged_bin="${APP_BIN}.new"
  rm -f "$staged_bin"
  if ! cp "$found_bin" "$staged_bin"; then
    print_msg "$RED" "复制可执行文件失败。"
    rm -f "$staged_bin"
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    return 1
  fi
  chmod +x "$staged_bin"
  xattr -dr com.apple.quarantine "$staged_bin" 2>/dev/null || true
  if ! mv -f "$staged_bin" "$APP_BIN"; then
    print_msg "$RED" "替换可执行文件失败。"
    rm -f "$staged_bin"
    rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"
    return 1
  fi
  xattr -dr com.apple.quarantine "$APP_BIN" 2>/dev/null || true

  write_version_file "$latest_version"
  rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH" "$MD5_LIST_PATH"

  local actual
  actual="$(read_binary_version 2>/dev/null || true)"
  if [ -n "$actual" ]; then
    write_version_file "$actual"
    print_msg "$GREEN" "OpenList 安装/更新完成。当前版本：$actual"
  else
    print_msg "$GREEN" "OpenList 安装/更新完成。当前版本：$latest_version"
  fi

  if [ "$was_running" -eq 1 ]; then
    print_msg "$BLUE" "更新前服务在运行，正在重新启动..."
    start_openlist || {
      print_msg "$YELLOW" "自动重启失败，请在菜单手动选择「启动 OpenList」。"
      return 1
    }
  fi

  return 0
}

install_openlist() {
  if [ -x "$APP_BIN" ]; then
    print_msg "$YELLOW" "已检测到 OpenList，若需覆盖升级请使用“更新 OpenList”。"
    return 0
  fi

  download_and_install || return 1
  start_openlist
}

update_openlist() {
  local local_version latest_version force_choice

  if [ ! -x "$APP_BIN" ]; then
    print_msg "$YELLOW" "当前未安装 OpenList，先执行安装。"
    install_openlist
    return
  fi

  local_version="$(get_local_version || true)"
  latest_version="$(get_latest_version || true)"

  if [ -z "$local_version" ]; then
    print_msg "$YELLOW" "未能识别当前本地版本，将直接尝试更新。"
    download_and_install "$latest_version"
    return
  fi

  if [ -z "$latest_version" ]; then
    print_msg "$RED" "未能获取 OpenList 官方最新版本信息，请稍后再试。"
    return 1
  fi

  printf "本地版本：%b%s%b\n" "$BLUE" "$local_version" "$NC"
  printf "官方版本：%b%s%b\n" "$BLUE" "$latest_version" "$NC"

  if is_version_newer "$latest_version" "$local_version"; then
    print_msg "$YELLOW" "检测到官方有更新，正在升级..."
    download_and_install "$latest_version"
    return
  fi

  print_msg "$GREEN" "当前已是最新版（$local_version）。"
  if [[ ! -t 0 ]]; then
    print_msg "$BLUE" "非交互环境，已跳过强制重装询问。"
    return 0
  fi
  prompt_input "是否强制重新安装官方包？(Y/N，默认为N): "
  force_choice="$REPLY"
  if [[ "$force_choice" = "y" || "$force_choice" = "Y" ]]; then
    print_msg "$YELLOW" "正在强制重新安装 $latest_version ..."
    download_and_install "$latest_version"
  else
    print_msg "$BLUE" "已跳过强制重装。"
  fi
}

# run_at_load / keep_alive: 字符串 true 或 false（写入 plist 布尔）
write_plist() {
  local run_at_load="${1:-false}"
  local keep_alive="${2:-false}"
  local run_xml keep_xml

  prepare_dirs
  mkdir -p "$(dirname "$PLIST_PATH")"

  if [[ "$run_at_load" == "true" ]]; then
    run_xml="<true/>"
  else
    run_xml="<false/>"
  fi
  if [[ "$keep_alive" == "true" ]]; then
    keep_xml="<true/>"
  else
    keep_xml="<false/>"
  fi

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BIN</string>
    <string>--data</string>
    <string>$DATA_DIR</string>
    <string>server</string>
  </array>
  <key>RunAtLoad</key>
  ${run_xml}
  <key>KeepAlive</key>
  ${keep_xml}
  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
  <key>StandardErrorPath</key>
  <string>$LOG_PATH</string>
</dict>
</plist>
PLIST
}

launchctl_bootout() {
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
}

# 统一用 launchd 托管进程；开机自启仅影响 RunAtLoad/KeepAlive
launchd_start_service() {
  local domain="gui/$(id -u)"

  if is_autostart_configured; then
    write_plist "true" "true"
  else
    write_plist "false" "false"
  fi

  launchctl_bootout
  if ! launchctl bootstrap "$domain" "$PLIST_PATH"; then
    print_msg "$RED" "launchctl bootstrap 失败。"
    return 1
  fi
  launchctl enable "${domain}/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  # 确保立即拉起（尤其是 RunAtLoad=false 时）
  launchctl kickstart -k "${domain}/${LAUNCH_LABEL}" >/dev/null 2>&1 || true
  return 0
}

wait_for_running_pid() {
  local seconds="${1:-12}"
  local i pid=""

  i=0
  while [ "$i" -lt "$seconds" ]; do
    i=$((i + 1))
    sleep 1
    pid="$(get_running_pid 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

start_via_nohup() {
  nohup "$APP_BIN" --data "$DATA_DIR" server >>"$LOG_PATH" 2>&1 &
  echo $! > "$PID_PATH"
}

start_openlist() {
  local first_run
  local running_pid
  local console_url

  require_installed || return 1
  prepare_dirs
  cleanup_stale_pid
  rotate_logs_if_needed
  first_run=0
  console_url="$(get_console_url)"

  if [ ! -f "$DATA_DIR/config.json" ]; then
    first_run=1
  fi

  running_pid="$(get_running_pid 2>/dev/null || true)"
  if [ -n "$running_pid" ]; then
    print_msg "$YELLOW" "OpenList 已在运行。"
    printf "访问地址：%b%s%b\n" "$BLUE" "$console_url" "$NC"
    return 0
  fi

  if is_autostart_configured; then
    print_msg "$BLUE" "正在通过 launchd 启动 OpenList（开机自启已开启）..."
  else
    print_msg "$BLUE" "正在通过 launchd 启动 OpenList..."
  fi

  running_pid=""
  if launchd_start_service; then
    running_pid="$(wait_for_running_pid 12 || true)"
  else
    print_msg "$YELLOW" "launchd bootstrap 失败。"
  fi

  # launchd 在部分路径/权限场景下会静默失败：回退 nohup，保证可用性
  if [ -z "$running_pid" ]; then
    print_msg "$YELLOW" "launchd 未成功拉起进程，回退为 nohup 启动..."
    launchctl_bootout
    start_via_nohup
    running_pid="$(wait_for_running_pid 12 || true)"
  fi

  if [ -n "$running_pid" ]; then
    printf '%s\n' "$running_pid" > "$PID_PATH" 2>/dev/null || true
    print_msg "$GREEN" "OpenList 启动成功。"
    printf "访问地址：%b%s%b\n" "$BLUE" "$console_url" "$NC"
    printf "进程 PID：%b%s%b\n" "$GREEN" "$running_pid" "$NC"
    if [ "$first_run" -eq 1 ]; then
      sleep 1
      show_initial_password
      offer_set_password_now
    fi
  else
    rm -f "$PID_PATH"
    print_msg "$RED" "启动失败，请查看日志：$LOG_PATH"
    return 1
  fi
}

stop_openlist() {
  local pid

  cleanup_stale_pid

  pid="$(get_running_pid 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    print_msg "$YELLOW" "OpenList 当前未运行。"
    if is_autostart_loaded; then
      launchctl_bootout
    fi
    return 0
  fi

  print_msg "$BLUE" "正在停止 OpenList (PID $pid)..."
  # 统一 bootout，避免 KeepAlive 把进程拉回来
  launchctl_bootout
  kill "$pid" >/dev/null 2>&1 || true

  local _
  for _ in 1 2 3 4 5 6 7 8; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  pid="$(find_pid_by_listen_port 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$PID_PATH"
  print_msg "$GREEN" "OpenList 已停止。"
  if is_autostart_configured; then
    print_msg "$BLUE" "开机自启仍已配置；下次登录或手动「启动」时会再次拉起。"
  fi
}

restart_openlist() {
  stop_openlist
  start_openlist
}

enable_autostart() {
  require_installed || return 1
  prepare_dirs
  mkdir -p "$(dirname "$PLIST_PATH")"
  : > "$AUTOSTART_FLAG"
  write_plist "true" "true"

  # 若当前已在跑，先停再按自启配置拉起（统一走 start_openlist，含 launchd/nohup 回退）
  if is_running; then
    stop_openlist >/dev/null 2>&1 || true
  else
    launchctl_bootout
  fi

  if ! start_openlist; then
    print_msg "$YELLOW" "自启配置已写入，但立即启动失败；可稍后手动「启动 OpenList」。"
    print_msg "$GREEN" "已设置开机自启（RunAtLoad + KeepAlive）。"
    return 0
  fi
  print_msg "$GREEN" "已设置开机自启（RunAtLoad + KeepAlive）。"
}

disable_autostart() {
  local was_running=0

  if is_running; then
    was_running=1
  fi

  rm -f "$AUTOSTART_FLAG"
  launchctl_bootout

  if [ -f "$PLIST_PATH" ]; then
    # 保留可被 start 复用的非自启 plist
    write_plist "false" "false"
  fi

  print_msg "$GREEN" "已取消开机自启。"

  if [ "$was_running" -eq 1 ]; then
    print_msg "$BLUE" "服务原先在运行，正在以非自启方式重新拉起..."
    start_openlist || print_msg "$YELLOW" "重新启动失败，请手动启动。"
  fi
}

show_status() {
  local current_version
  local running_pid
  local console_url
  local active_cmd
  local log_size="0"

  cleanup_stale_pid
  console_url="$(get_console_url)"

  printf "管理脚本：%b%s%b\n" "$BLUE" "$SCRIPT_VERSION" "$NC"

  if [ -x "$APP_BIN" ]; then
    current_version="$(get_local_version || true)"
    printf "程序状态：%b已安装%b\n" "$GREEN" "$NC"
    printf "程序路径：%b%s%b\n" "$BLUE" "$APP_BIN" "$NC"
    if [ -n "$current_version" ]; then
      printf "程序版本：%b%s%b\n" "$GREEN" "$current_version" "$NC"
    else
      printf "程序版本：%b未识别%b\n" "$YELLOW" "$NC"
    fi
  else
    printf "程序状态：%b未安装%b\n" "$RED" "$NC"
  fi

  running_pid="$(get_running_pid 2>/dev/null || true)"
  if [ -n "$running_pid" ]; then
    printf "运行状态：%b运行中%b\n" "$GREEN" "$NC"
    printf "托管方式：%blaunchd%b\n" "$BLUE" "$NC"
    printf "访问地址：%b%s%b\n" "$BLUE" "$console_url" "$NC"
    printf "监听端口：%b%s%b\n" "$BLUE" "$(get_http_port)" "$NC"
    printf "进程 PID：%b%s%b\n" "$GREEN" "$running_pid" "$NC"
  else
    printf "运行状态：%b已停止%b\n" "$RED" "$NC"
    printf "配置端口：%b%s%b\n" "$BLUE" "$(get_http_port)" "$NC"
  fi

  if is_autostart_configured; then
    if is_autostart_loaded; then
      printf "开机自启：%b已配置且已加载%b\n" "$GREEN" "$NC"
    else
      printf "开机自启：%b已配置（当前未加载）%b\n" "$YELLOW" "$NC"
    fi
  else
    printf "开机自启：%b未配置%b\n" "$RED" "$NC"
  fi

  active_cmd="$(command -v openlist 2>/dev/null || true)"
  if [ -n "$active_cmd" ]; then
    printf "PATH 入口：%b%s%b\n" "$BLUE" "$active_cmd" "$NC"
  fi

  if [ -f "$LOG_PATH" ]; then
    log_size="$(wc -c < "$LOG_PATH" | tr -d '[:space:]')"
  fi
  printf "数据目录：%b%s%b\n" "$BLUE" "$DATA_DIR" "$NC"
  printf "日志文件：%b%s%b（%s 字节）\n" "$BLUE" "$LOG_PATH" "$NC" "$log_size"
}

print_menu_summary() {
  local ver="未安装"
  local run="已停止"
  local port
  local auto="关"
  local pid

  port="$(get_http_port)"
  if [ -x "$APP_BIN" ]; then
    ver="$(get_local_version 2>/dev/null || echo 未知)"
  fi
  pid="$(get_running_pid 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    run="运行中 PID $pid"
  fi
  if is_autostart_configured; then
    if is_autostart_loaded; then
      auto="已配置/已加载"
    else
      auto="已配置/未加载"
    fi
  fi

  printf "  版本：%b%s%b  |  状态：%b%s%b\n" "$GREEN" "$ver" "$NC" "$BLUE" "$run" "$NC"
  printf "  端口：%b%s%b  |  自启：%b%s%b  |  脚本：%b%s%b\n\n" \
    "$BLUE" "$port" "$NC" "$BLUE" "$auto" "$NC" "$BLUE" "$SCRIPT_VERSION" "$NC"
}

open_console() {
  local console_url

  require_cmd "open" "macOS 自带 open 命令。" || return 1
  console_url="$(get_console_url)"

  if ! get_running_pid >/dev/null 2>&1; then
    print_msg "$YELLOW" "OpenList 尚未运行，正在自动启动..."
    start_openlist || return 1
  fi

  open "$console_url"
  print_msg "$GREEN" "已使用默认浏览器打开 OpenList 控制台。"
  printf "地址：%b%s%b\n" "$BLUE" "$console_url" "$NC"
  print_msg "$BLUE" "如果忘记管理员密码，可回菜单使用“密码管理”。"
}

view_logs() {
  local choice

  prepare_dirs
  echo "1. 查看最近 50 行日志"
  echo "2. 查看最近 200 行日志"
  echo "3. 在 Finder 中打开日志目录"
  echo "4. 用系统默认程序打开日志文件"
  echo "0. 返回主菜单"
  prompt_input "请选择(0/1/2/3/4，默认为1): "
  choice="$REPLY"

  case "$choice" in
    ""|1)
      if [ -f "$LOG_PATH" ]; then
        echo
        tail -n 50 "$LOG_PATH"
      else
        print_msg "$YELLOW" "日志文件尚不存在：$LOG_PATH"
      fi
      ;;
    2)
      if [ -f "$LOG_PATH" ]; then
        echo
        tail -n 200 "$LOG_PATH"
      else
        print_msg "$YELLOW" "日志文件尚不存在：$LOG_PATH"
      fi
      ;;
    3)
      open "$LOG_DIR" 2>/dev/null || print_msg "$RED" "无法打开日志目录。"
      ;;
    4)
      if [ -f "$LOG_PATH" ]; then
        open "$LOG_PATH"
      else
        print_msg "$YELLOW" "日志文件尚不存在：$LOG_PATH"
      fi
      ;;
    0)
      return 0
      ;;
    *)
      print_msg "$RED" "无效选择。"
      return 1
      ;;
  esac
}

password_menu() {
  local choice new_pass

  require_installed || return 1
  prepare_dirs

  echo "1. 随机生成新密码"
  echo "2. 手动设置新密码"
  echo "0. 返回主菜单"
  prompt_input "请选择(0/1/2，默认为0): "
  choice="$REPLY"

  case "$choice" in
    ""|0)
      print_msg "$YELLOW" "已返回主菜单，未修改管理员密码。"
      return 0
      ;;
    1)
      "$APP_BIN" --data "$DATA_DIR" admin random || {
        print_msg "$RED" "随机密码生成失败。"
        return 1
      }
      if is_running; then
        print_msg "$BLUE" "正在重启 OpenList，使新密码立即生效并清除登录封禁..."
        restart_openlist
      fi
      ;;
    2)
      prompt_input "请输入新的管理员密码: "
      new_pass="$REPLY"
      if [ -z "$new_pass" ]; then
        print_msg "$YELLOW" "密码为空，已取消修改。"
        return 0
      fi
      "$APP_BIN" --data "$DATA_DIR" admin set "$new_pass" || {
        print_msg "$RED" "设置密码失败。"
        return 1
      }
      print_msg "$GREEN" "管理员密码已重置。"
      if is_running; then
        print_msg "$BLUE" "正在重启 OpenList，使新密码立即生效并清除登录封禁..."
        restart_openlist
      fi
      ;;
    *)
      print_msg "$RED" "无效选择。"
      return 1
      ;;
  esac
}

run_official_command() {
  case "${1:-}" in
    backup|restore|delete-backups)
      print_msg "$YELLOW" "这个脚本已移除该功能：$1"
      print_msg "$BLUE" "如需保留 OpenList 数据，请直接复制数据目录：$DATA_DIR"
      return 1
      ;;
    refresh)
      print_msg "$YELLOW" "这个脚本已移除该功能：refresh"
      print_msg "$BLUE" "如需刷新夸克网盘等内容，请到对应网页端刷新或同步后再回 OpenList 查看。"
      return 1
      ;;
    clear-logs|login-help)
      print_msg "$YELLOW" "这个脚本已移除该功能：$1"
      print_msg "$BLUE" "如需查看日志，可在菜单使用“查看日志”。"
      return 1
      ;;
  esac

  require_installed || return 1
  prepare_dirs

  case "${1:-}" in
    server|admin)
      "$APP_BIN" --data "$DATA_DIR" "$@"
      ;;
    *)
      "$APP_BIN" "$@"
      ;;
  esac
}

try_remove_path() {
  local path="$1"
  local hint_sudo="${2:-0}"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if rm -f "$path" 2>/dev/null; then
    return 0
  fi

  if [ "$hint_sudo" = "1" ]; then
    print_msg "$YELLOW" "无法删除：$path（权限不足）"
    print_msg "$BLUE" "请手动执行：sudo rm -f \"$path\""
  else
    print_msg "$YELLOW" "无法删除：$path"
  fi
  return 1
}

remove_entry() {
  local candidate target
  local hint

  for candidate in "$HOME/.local/bin/openlist" "/usr/local/bin/openlist" "/opt/homebrew/bin/openlist"; do
    hint=0
    if [[ "$candidate" == /usr/* ]] || [[ "$candidate" == /opt/* ]]; then
      hint=1
    fi

    if [ -L "$candidate" ]; then
      target="$(readlink "$candidate" 2>/dev/null || true)"
      # 仅删除指向本管理目录的入口，避免误伤其他安装
      if [[ "$target" == "$MANAGER_PATH" ]] || [[ "$target" == "$MANAGER_DIR/"* ]]; then
        try_remove_path "$candidate" "$hint" || true
      fi
    fi
  done

  # 家目录快捷入口：仅当内容指向本脚本时删除
  if [ -f "$HOME/openlist_manager.sh" ] || [ -L "$HOME/openlist_manager.sh" ]; then
    if [ -L "$HOME/openlist_manager.sh" ]; then
      target="$(readlink "$HOME/openlist_manager.sh" 2>/dev/null || true)"
      if [[ "$target" == "$MANAGER_PATH" ]] || [[ "$target" == "$MANAGER_DIR/"* ]]; then
        try_remove_path "$HOME/openlist_manager.sh" 0 || true
      fi
    elif grep -Fq "$MANAGER_PATH" "$HOME/openlist_manager.sh" 2>/dev/null \
      || grep -Fq "$MANAGER_DIR/openlist-menu.sh" "$HOME/openlist_manager.sh" 2>/dev/null; then
      try_remove_path "$HOME/openlist_manager.sh" 0 || true
    fi
  fi

  return 0
}

full_uninstall() {
  local confirm

  print_msg "$RED" "警告：此操作将删除 OpenList 程序、数据、日志、自启项及本脚本本身。"
  print_msg "$YELLOW" "数据目录：$DATA_DIR"
  prompt_input "确认继续吗？(Y/N，默认为N): "
  confirm="$REPLY"

  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    print_msg "$YELLOW" "已取消卸载。"
    return 0
  fi

  prompt_input "请再次输入 YES 以确认彻底删除: "
  if [[ "$REPLY" != "YES" ]]; then
    print_msg "$YELLOW" "确认词不匹配，已取消卸载。"
    return 0
  fi

  # 先清自启标记再停止，避免 disable_autostart 在卸载流程里把服务又拉起来
  rm -f "$AUTOSTART_FLAG"
  stop_openlist >/dev/null 2>&1 || true
  launchctl_bootout
  rm -f "$PLIST_PATH"
  remove_entry
  rm -rf "$MANAGER_DIR" "$HOME/Library/Application Support/OpenList" "$HOME/Library/Logs/OpenList"
  print_msg "$GREEN" "OpenList 已彻底卸载完成。"
  exit 0
}

update_script() {
  local temp_installer

  require_cmd "curl" "macOS 通常自带 curl。" || return 1
  prepare_dirs
  temp_installer="$TMP_DIR/install_openlist_mac.sh"

  print_msg "$BLUE" "正在从 GitHub 获取最新脚本..."
  print_msg "$YELLOW" "注意：若远程仓库尚未同步本次修复，更新后可能覆盖本地改进。"
  if ! curl -fsSL -A "$CURL_UA" "$INSTALLER_URL" -o "$temp_installer"; then
    print_msg "$RED" "下载安装脚本失败。"
    return 1
  fi
  if [ ! -s "$temp_installer" ]; then
    print_msg "$RED" "下载的安装脚本为空。"
    return 1
  fi
  chmod +x "$temp_installer"

  print_msg "$BLUE" "正在更新本地脚本..."
  OPENLIST_SKIP_MENU_AUTORUN=1 zsh "$temp_installer" || {
    print_msg "$RED" "执行安装脚本失败。"
    return 1
  }

  print_msg "$GREEN" "脚本更新完成。"
  if [[ -t 0 && -t 1 ]]; then
    pause
    exec "$MANAGER_PATH"
  fi
  exit 0
}

show_menu() {
  clear
  printf "%b====================================%b\n" "$GREEN" "$NC"
  printf "%b       OpenList 管理脚本 (macOS)      %b\n" "$GREEN" "$NC"
  printf "%b====================================%b\n\n" "$GREEN" "$NC"
  print_menu_summary
  echo " 1. 安装 OpenList"
  echo " 2. 更新 OpenList（已最新时可强制重装）"
  echo " 3. 彻底卸载 (程序、数据及本脚本本身)"
  echo " 4. 查看状态"
  echo " 5. 一键打开网页控制台"
  echo " 6. 密码管理 (忘记密码时重置)"
  echo " 7. 启动 OpenList"
  echo " 8. 停止 OpenList"
  echo " 9. 重启 OpenList"
  echo "10. 设置开机自启"
  echo "11. 取消开机自启"
  echo "12. 更新脚本"
  echo "13. 查看日志"
  echo " 0. 退出脚本"
  echo
}

if [ "$#" -gt 0 ]; then
  run_official_command "$@"
  exit $?
fi

while true; do
  show_menu
  if ! prompt_input "请输入菜单编号: "; then
    echo
    exit 0
  fi
  choice="$REPLY"
  clear

  case "$choice" in
    1) install_openlist ;;
    2) update_openlist ;;
    3) full_uninstall ;;
    4) show_status ;;
    5) open_console ;;
    6) password_menu ;;
    7) start_openlist ;;
    8) stop_openlist ;;
    9) restart_openlist ;;
    10) enable_autostart ;;
    11) disable_autostart ;;
    12) update_script ;;
    13) view_logs ;;
    0) exit 0 ;;
    *) print_msg "$RED" "无效输入，请重新选择。" ;;
  esac

  if [ "$choice" != "0" ] && [ "$choice" != "3" ]; then
    pause
  fi
done
EOF

chmod +x "$MANAGER_PATH"

mkdir -p "$HOME/.local/bin"
ln -sfn "$MANAGER_PATH" "$HOME/.local/bin/openlist"

if [ -w /usr/local/bin ] 2>/dev/null; then
  ln -sfn "$MANAGER_PATH" /usr/local/bin/openlist 2>/dev/null || true
fi

cat > "$HOME/openlist_manager.sh" <<'WRAP'
#!/bin/zsh

set -euo pipefail

TARGET="$HOME/.openlist-manager/openlist-menu.sh"

if [[ ! -x "$TARGET" ]]; then
  print -u2 -- "未找到 OpenList 管理脚本：$TARGET"
  print -u2 -- "请重新安装或重新生成 OpenList 管理脚本后再试。"
  exit 1
fi

exec "$TARGET" "$@"
WRAP
chmod +x "$HOME/openlist_manager.sh"

remove_legacy_entry
warn_if_legacy_remains

echo "OpenList 管理脚本已安装/更新："
echo "  $MANAGER_PATH"
echo "命令入口：openlist  或  $HOME/openlist_manager.sh"

# 注意：不能写成 [[ cond ]] && exec —— set -e 下 cond 为假会直接退出
if [[ "${OPENLIST_SKIP_MENU_AUTORUN:-0}" != "1" && -t 0 && -t 1 ]]; then
  exec "$MANAGER_PATH"
fi
