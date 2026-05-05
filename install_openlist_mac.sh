#!/bin/zsh

set -euo pipefail

MANAGER_DIR="$HOME/.openlist-manager"
MANAGER_PATH="$MANAGER_DIR/openlist-menu.sh"

mkdir -p "$MANAGER_DIR"

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

APP_NAME="OpenList"
MANAGER_DIR="$HOME/.openlist-manager"
MANAGER_PATH="$MANAGER_DIR/openlist-menu.sh"
APP_DIR="$MANAGER_DIR/app"
TMP_DIR="$MANAGER_DIR/tmp"
APP_BIN="$APP_DIR/openlist"
VERSION_FILE="$APP_DIR/version.txt"
ARCHIVE_PATH="$TMP_DIR/openlist.tar.gz"
EXTRACT_DIR="$TMP_DIR/extract"
DATA_DIR="$HOME/Library/Application Support/OpenList/data"
RUN_DIR="$HOME/Library/Application Support/OpenList/run"
LOG_DIR="$HOME/Library/Logs/OpenList"
LOG_PATH="$LOG_DIR/openlist.log"
DATA_LOG_DIR="$DATA_DIR/log"
PID_PATH="$RUN_DIR/openlist.pid"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openlist.server.plist"
DEFAULT_URL="http://127.0.0.1:5244"
BACKUP_DIR="$HOME/OpenList-Backups"
API_TOKEN_PATH="$MANAGER_DIR/api-token"
INSTALLER_URL="https://raw.githubusercontent.com/xiyingruyi/openlist/main/install_openlist_mac.sh"

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
    IFS= read -r REPLY
  fi
  echo
}

prompt_input() {
  local prompt="$1"

  printf "%s" "$prompt"
  IFS= read -r REPLY
}

prompt_secret() {
  local prompt="$1"

  if [[ -t 0 ]]; then
    read -rs "REPLY?$prompt"
    echo
  else
    IFS= read -r REPLY
  fi
}

prepare_dirs() {
  mkdir -p "$MANAGER_DIR" "$APP_DIR" "$TMP_DIR" "$DATA_DIR" "$RUN_DIR" "$LOG_DIR" "$BACKUP_DIR"
}

require_cmd() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    print_msg "$RED" "缺少命令：$cmd"
    print_msg "$BLUE" "$hint"
    return 1
  fi
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

download_url() {
  local arch
  arch="$(detect_arch)" || return 1
  echo "https://github.com/OpenListTeam/OpenList/releases/latest/download/openlist-darwin-${arch}.tar.gz"
}

normalize_version() {
  printf '%s\n' "$1" | sed 's/^[Vv]//' | grep -Eo '[0-9]+(\.[0-9]+){1,3}' | head -n 1
}

get_local_version() {
  local raw

  if [ -f "$VERSION_FILE" ]; then
    raw="$(cat "$VERSION_FILE" 2>/dev/null)"
    raw="$(normalize_version "$raw")"
    if [ -n "$raw" ]; then
      printf '%s\n' "$raw"
      return 0
    fi
  fi

  if [ ! -x "$APP_BIN" ]; then
    return 1
  fi

  raw="$("$APP_BIN" version 2>/dev/null)"
  normalize_version "$raw"
}

get_latest_version() {
  local raw

  require_cmd "curl" "macOS 通常自带 curl。"
  raw="$(curl -fsSL https://api.github.com/repos/OpenListTeam/OpenList/releases/latest | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
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
  [ "$(version_to_sort_key "$1")" '>' "$(version_to_sort_key "$2")" ]
}

require_installed() {
  if [ ! -x "$APP_BIN" ]; then
    print_msg "$RED" "未检测到 OpenList，请先安装。"
    return 1
  fi
}

latest_backup_file() {
  ls -1t "$BACKUP_DIR"/openlist-backup-*.tar.gz 2>/dev/null | head -n 1
}

create_backup_archive() {
  local prefix="$1"
  local timestamp archive

  require_cmd "tar" "macOS 通常自带 tar。"
  prepare_dirs

  if [ ! -d "$DATA_DIR" ]; then
    print_msg "$RED" "未找到 OpenList 数据目录：$DATA_DIR"
    return 1
  fi

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  if [ -n "$prefix" ]; then
    archive="$BACKUP_DIR/openlist-backup-${prefix}-${timestamp}.tar.gz"
  else
    archive="$BACKUP_DIR/openlist-backup-${timestamp}.tar.gz"
  fi

  tar -czf "$archive" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
  printf '%s\n' "$archive"
}

is_running() {
  get_running_pid >/dev/null 2>&1
}

get_http_port() {
  local port

  if [ -f "$DATA_DIR/config.json" ]; then
    port="$(sed -n 's/.*"http_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/config.json" | head -n 1)"
  fi

  printf '%s\n' "${port:-5244}"
}

pid_is_openlist_server() {
  local pid="$1"
  local http_port

  [ -n "$pid" ] || return 1
  http_port="$(get_http_port)"
  lsof -nP -a -p "$pid" -iTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1
}

get_launchd_pid() {
  local launchd_info
  local pid

  launchd_info="$(launchctl print "gui/$(id -u)/com.openlist.server" 2>/dev/null || true)"
  [ -n "$launchd_info" ] || return 1

  printf '%s\n' "$launchd_info" | grep -F "state = running" >/dev/null 2>&1 || return 1
  printf '%s\n' "$launchd_info" | grep -F "program = $APP_BIN" >/dev/null 2>&1 || return 1
  printf '%s\n' "$launchd_info" | grep -F "$DATA_DIR" >/dev/null 2>&1 || return 1
  printf '%s\n' "$launchd_info" | grep -F "server" >/dev/null 2>&1 || return 1

  pid="$(printf '%s\n' "$launchd_info" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)"
  pid_is_openlist_server "$pid" || return 1
  printf '%s\n' "$pid"
}

get_running_pid() {
  local pid

  if [ -f "$PID_PATH" ]; then
    pid="$(cat "$PID_PATH" 2>/dev/null)"
    if pid_is_openlist_server "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi

  pid="$(get_launchd_pid 2>/dev/null || true)"
  if pid_is_openlist_server "$pid"; then
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

show_initial_password() {
  local initial_password

  initial_password="$(grep -Eo 'initial password is: .*' "$LOG_PATH" 2>/dev/null | tail -n 1 | sed 's/^initial password is: //')"
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

  "$APP_BIN" --data "$DATA_DIR" admin set "$new_pass"
  print_msg "$GREEN" "管理员密码已更新为你刚输入的新密码。"
  if is_running; then
    print_msg "$BLUE" "正在重启 OpenList，使新密码立即生效并清除登录封禁..."
    restart_openlist
  fi
}

download_and_install() {
  local url found_bin latest_version

  require_cmd "curl" "macOS 通常自带 curl。"
  require_cmd "tar" "macOS 通常自带 tar。"
  prepare_dirs

  latest_version="$(get_latest_version)"
  url="$(download_url)" || return 1

  if [ -z "$latest_version" ]; then
    print_msg "$RED" "未能获取 OpenList 官方最新版本信息，请稍后再试。"
    return 1
  fi

  print_msg "$BLUE" "正在从 OpenList 官方发布页下载最新版本..."
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  curl -fL "$url" -o "$ARCHIVE_PATH"

  print_msg "$BLUE" "正在解压安装包..."
  tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

  found_bin="$(find "$EXTRACT_DIR" -type f \( -name 'openlist' -o -name 'OpenList' \) | head -n 1)"
  if [ -z "$found_bin" ]; then
    print_msg "$RED" "解压后未找到 OpenList 可执行文件。"
    return 1
  fi

  stop_openlist >/dev/null 2>&1 || true

  rm -f "$APP_BIN"
  cp "$found_bin" "$APP_BIN"
  chmod +x "$APP_BIN"
  printf '%s\n' "$latest_version" > "$VERSION_FILE"
  rm -rf "$EXTRACT_DIR" "$ARCHIVE_PATH"

  print_msg "$GREEN" "OpenList 安装/更新完成。当前版本：$latest_version"
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
  local local_version latest_version

  if [ ! -x "$APP_BIN" ]; then
    print_msg "$YELLOW" "当前未安装 OpenList，先执行安装。"
    install_openlist
    return
  fi

  local_version="$(get_local_version)"
  latest_version="$(get_latest_version)"

  if [ -z "$local_version" ]; then
    print_msg "$YELLOW" "未能识别当前本地版本，将直接尝试更新。"
    download_and_install
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
    download_and_install
  else
    print_msg "$GREEN" "当前已是最新版，无需更新。"
  fi
}

start_openlist() {
  local first_run
  local running_pid

  require_installed || return 1
  prepare_dirs
  cleanup_stale_pid
  first_run=0

  if [ ! -f "$DATA_DIR/config.json" ]; then
    first_run=1
  fi

  running_pid="$(get_running_pid 2>/dev/null || true)"
  if [ -n "$running_pid" ]; then
    print_msg "$YELLOW" "OpenList 已在运行。"
    return 0
  fi

  if [ -f "$PLIST_PATH" ]; then
    print_msg "$BLUE" "检测到已开启开机自启，正在通过 launchd 启动 OpenList..."
    launchctl_bootout
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    launchctl enable "gui/$(id -u)/com.openlist.server" >/dev/null 2>&1 || true
  else
    print_msg "$BLUE" "正在启动 OpenList..."
    nohup "$APP_BIN" --data "$DATA_DIR" server >>"$LOG_PATH" 2>&1 &
    echo $! > "$PID_PATH"
  fi
  sleep 2

  running_pid="$(get_running_pid 2>/dev/null || true)"
  if [ -n "$running_pid" ]; then
    print_msg "$GREEN" "OpenList 启动成功。"
    printf "访问地址：%b%s%b\n" "$BLUE" "$DEFAULT_URL" "$NC"
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
    return 0
  fi

  print_msg "$BLUE" "正在停止 OpenList..."
  if [ -f "$PLIST_PATH" ]; then
    launchctl_bootout
  fi
  kill "$pid" >/dev/null 2>&1 || true

  for _ in 1 2 3 4 5; do
    if ! is_running; then
      break
    fi
    sleep 1
  done

  if is_running; then
    pid="$(get_running_pid 2>/dev/null || true)"
    [ -n "$pid" ] && kill -9 "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$PID_PATH"
  print_msg "$GREEN" "OpenList 已停止。"
}

restart_openlist() {
  stop_openlist
  start_openlist
}

create_backup() {
  local archive
  local was_running=0

  require_installed || return 1

  if is_running; then
    was_running=1
    print_msg "$BLUE" "为保证数据库快照一致，正在临时停止 OpenList..."
    stop_openlist
  fi

  archive="$(create_backup_archive "")" || return 1
  print_msg "$GREEN" "备份完成。"
  printf "备份文件：%b%s%b\n" "$BLUE" "$archive" "$NC"
  printf "备份目录：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"

  if [ "$was_running" -eq 1 ]; then
    print_msg "$BLUE" "正在恢复 OpenList 运行状态..."
    start_openlist
  fi
}

restore_backup() {
  local input_path archive confirm was_running safety_backup
  local restore_tmp="$TMP_DIR/restore"
  local restored_dir

  require_installed || return 1
  require_cmd "tar" "macOS 通常自带 tar。"
  prepare_dirs

  input_path="${1:-}"
  if [ -n "$input_path" ]; then
    archive="${input_path/#\~/$HOME}"
  else
    archive="$(latest_backup_file)"
    if [ -z "$archive" ]; then
      print_msg "$RED" "未找到可用备份。"
      printf "默认备份目录：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"
      return 1
    fi

    echo "检测到以下最近备份："
    ls -1t "$BACKUP_DIR"/openlist-backup-*.tar.gz 2>/dev/null | head -n 5
    echo
    prompt_input "回车使用最新备份，或输入要还原的完整备份文件路径: "
    if [ -n "$REPLY" ]; then
      archive="${REPLY/#\~/$HOME}"
    fi
  fi

  if [ ! -f "$archive" ]; then
    print_msg "$RED" "备份文件不存在：$archive"
    return 1
  fi

  print_msg "$YELLOW" "即将还原备份：$archive"
  print_msg "$YELLOW" "还原会覆盖当前 OpenList 数据。"
  prompt_input "确认继续吗？(Y/N，默认为Y): "
  confirm="$REPLY"
  if [[ "$confirm" = "n" || "$confirm" = "N" ]]; then
    print_msg "$YELLOW" "已取消还原。"
    return 0
  fi

  was_running=0
  if is_running; then
    was_running=1
    print_msg "$BLUE" "正在停止 OpenList..."
    stop_openlist
  fi

  print_msg "$BLUE" "正在为当前数据创建安全备份..."
  safety_backup="$(create_backup_archive "pre-restore")" || return 1

  rm -rf "$restore_tmp"
  mkdir -p "$restore_tmp"
  tar -xzf "$archive" -C "$restore_tmp"

  restored_dir="$restore_tmp/$(basename "$DATA_DIR")"
  if [ ! -d "$restored_dir" ]; then
    print_msg "$RED" "备份文件内容不符合预期，未找到数据目录。"
    rm -rf "$restore_tmp"
    return 1
  fi

  rm -rf "$DATA_DIR"
  mkdir -p "$(dirname "$DATA_DIR")"
  mv "$restored_dir" "$DATA_DIR"
  rm -rf "$restore_tmp"

  print_msg "$GREEN" "OpenList 数据已还原完成。"
  printf "已还原备份：%b%s%b\n" "$BLUE" "$archive" "$NC"
  printf "还原前安全备份：%b%s%b\n" "$BLUE" "$safety_backup" "$NC"
  printf "备份目录：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"

  if [ "$was_running" -eq 1 ]; then
    print_msg "$BLUE" "正在恢复 OpenList 运行状态..."
    start_openlist
  fi
}

login_troubleshooting() {
  local auth_log="$DATA_LOG_DIR/log.log"

  prepare_dirs
  print_msg "$YELLOW" "OpenList 官方网页理论上会在登录失败时弹出错误提示。"
  print_msg "$YELLOW" "如果你这里输入错误用户名或密码后一直转圈，通常不是本脚本卡住，而是浏览器缓存、登录封禁或前端提示没有正常弹出。"
  echo
  echo "建议按下面顺序处理："
  echo "1. 管理员用户名通常是 admin。"
  echo "2. 如果忘了密码，回主菜单使用“密码管理”。脚本会在重置后自动重启 OpenList，并清除登录封禁。"
  echo "3. 关闭当前网页后重新打开，或用无痕窗口访问：$DEFAULT_URL"
  echo "4. 仍然异常时，查看下面的最近登录日志。"
  echo
  printf "数据目录：%b%s%b\n" "$BLUE" "$DATA_DIR" "$NC"
  printf "日志文件：%b%s%b\n" "$BLUE" "$LOG_PATH" "$NC"
  echo

  if [ -f "$auth_log" ]; then
    print_msg "$BLUE" "最近登录相关日志："
    grep -E '/api/auth/login/hash|/api/auth/login/ldap|/api/me' "$auth_log" | tail -n 12 || true
  else
    print_msg "$YELLOW" "暂未找到登录日志。"
  fi
}

clear_logs() {
  local was_running=0
  local restart_choice=""

  if is_running; then
    was_running=1
    print_msg "$BLUE" "OpenList 正在运行，先停止后再清理日志，避免残留正在写入的日志文件。"
    stop_openlist
  fi

  rm -rf "$LOG_DIR" "$DATA_LOG_DIR"
  print_msg "$GREEN" "日志目录已清理完成。"
  printf "已删除：%b%s%b\n" "$BLUE" "$LOG_DIR" "$NC"
  printf "已删除：%b%s%b\n" "$BLUE" "$DATA_LOG_DIR" "$NC"

  if [ "$was_running" -eq 1 ]; then
    echo
    prompt_input "OpenList 一旦重新启动会重新生成新日志，是否现在就重启？(Y/N，默认为N): "
    restart_choice="$REPLY"
    if [[ "$restart_choice" = "y" || "$restart_choice" = "Y" ]]; then
      start_openlist
    else
      print_msg "$YELLOW" "OpenList 当前保持停止状态，避免刚清完日志又立刻生成新日志。"
    fi
  fi
}

delete_backups() {
  local confirm

  if [ ! -d "$BACKUP_DIR" ]; then
    print_msg "$YELLOW" "当前没有备份目录可删除。"
    return 0
  fi

  print_msg "$RED" "警告：此操作将删除整个备份目录及其中所有备份文件。"
  printf "目标目录：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"
  prompt_input "确认继续吗？(Y/N，默认为Y): "
  confirm="$REPLY"

  if [[ "$confirm" = "n" || "$confirm" = "N" ]]; then
    print_msg "$YELLOW" "已取消删除备份目录。"
    return 0
  fi

  rm -rf "$BACKUP_DIR"
  print_msg "$GREEN" "备份目录已删除完成。"
  printf "已删除：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"
}

show_status() {
  local current_version
  local running_pid
  local latest_backup

  cleanup_stale_pid

  if [ -x "$APP_BIN" ]; then
    current_version="$(get_local_version)"
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
    printf "访问地址：%b%s%b\n" "$BLUE" "$DEFAULT_URL" "$NC"
    printf "进程 PID：%b%s%b\n" "$GREEN" "$running_pid" "$NC"
  else
    printf "运行状态：%b已停止%b\n" "$RED" "$NC"
  fi

  if [ -f "$PLIST_PATH" ]; then
    printf "开机自启：%b已开启%b\n" "$GREEN" "$NC"
  else
    printf "开机自启：%b未开启%b\n" "$RED" "$NC"
  fi

  printf "数据目录：%b%s%b\n" "$BLUE" "$DATA_DIR" "$NC"
  printf "备份目录：%b%s%b\n" "$BLUE" "$BACKUP_DIR" "$NC"
  latest_backup="$(latest_backup_file)"
  if [ -n "$latest_backup" ]; then
    printf "最近备份：%b%s%b\n" "$GREEN" "$latest_backup" "$NC"
  else
    printf "最近备份：%b暂无%b\n" "$YELLOW" "$NC"
  fi
  printf "日志文件：%b%s%b\n" "$BLUE" "$LOG_PATH" "$NC"
}

open_console() {
  require_cmd "open" "macOS 自带 open 命令。"

  if ! get_running_pid >/dev/null 2>&1; then
    print_msg "$YELLOW" "OpenList 尚未运行，正在自动启动..."
    start_openlist || return 1
  fi

  open "$DEFAULT_URL"
  print_msg "$GREEN" "已使用默认浏览器打开 OpenList 控制台。"
  print_msg "$BLUE" "如果网页登录一直转圈，可回菜单使用“登录故障排查”或“密码管理”。"
}

get_api_base_url() {
  printf 'http://127.0.0.1:%s\n' "$(get_http_port)"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

sha256_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

api_response_code() {
  printf '%s\n' "$1" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1
}

api_response_message() {
  local message

  message="$(printf '%s\n' "$1" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  printf '%s\n' "${message:-无返回消息}"
}

api_response_token() {
  printf '%s\n' "$1" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

openlist_api_request() {
  local method="$1"
  local endpoint="$2"
  local token="${3:-}"
  local body="${4:-}"
  local url response

  url="$(get_api_base_url)$endpoint"
  if [ -n "$body" ]; then
    response="$(curl -sS --connect-timeout 5 -X "$method" "$url" \
      -H "Content-Type: application/json" \
      -H "Authorization: $token" \
      --data-binary "$body")" || return 1
  else
    response="$(curl -sS --connect-timeout 5 -X "$method" "$url" \
      -H "Authorization: $token")" || return 1
  fi

  printf '%s\n' "$response"
}

is_api_token_valid() {
  local token="$1"
  local response code

  [ -n "$token" ] || return 1
  response="$(openlist_api_request "GET" "/api/me" "$token" "" 2>/dev/null)" || return 1
  code="$(api_response_code "$response")"
  [ "$code" = "200" ]
}

login_openlist_api() {
  local username password password_hash escaped_username escaped_otp otp_code body response code message token

  require_cmd "curl" "macOS 通常自带 curl。"
  require_cmd "shasum" "macOS 通常自带 shasum。"
  require_cmd "awk" "macOS 通常自带 awk。"

  prompt_input "管理员用户名(默认 admin): "
  username="${REPLY:-admin}"

  if [ -n "${OPENLIST_ADMIN_PASSWORD:-}" ]; then
    password="$OPENLIST_ADMIN_PASSWORD"
  else
    prompt_secret "管理员密码: "
    password="$REPLY"
  fi

  if [ -z "$password" ]; then
    print_msg "$RED" "密码不能为空。"
    return 1
  fi

  password_hash="$(sha256_text "$password")"
  escaped_username="$(json_escape "$username")"
  body="{\"username\":\"$escaped_username\",\"password\":\"$password_hash\",\"otp_code\":\"\"}"
  response="$(openlist_api_request "POST" "/api/auth/login/hash" "" "$body")" || {
    print_msg "$RED" "登录接口请求失败，请确认 OpenList 正在运行。"
    return 1
  }

  code="$(api_response_code "$response")"
  if [ "$code" != "200" ]; then
    message="$(api_response_message "$response")"
    if printf '%s\n' "$message" | grep -Eiq 'otp|2fa|totp|验证码'; then
      prompt_input "请输入 2FA 验证码: "
      otp_code="$REPLY"
      escaped_otp="$(json_escape "$otp_code")"
      body="{\"username\":\"$escaped_username\",\"password\":\"$password_hash\",\"otp_code\":\"$escaped_otp\"}"
      response="$(openlist_api_request "POST" "/api/auth/login/hash" "" "$body")" || return 1
      code="$(api_response_code "$response")"
    fi
  fi

  if [ "$code" != "200" ]; then
    message="$(api_response_message "$response")"
    print_msg "$RED" "管理员登录失败：$message"
    return 1
  fi

  token="$(api_response_token "$response")"
  if [ -z "$token" ]; then
    print_msg "$RED" "登录成功但没有取得 API token。"
    return 1
  fi

  printf '%s\n' "$token" > "$API_TOKEN_PATH"
  chmod 600 "$API_TOKEN_PATH" 2>/dev/null || true
  API_TOKEN_RESULT="$token"
}

get_openlist_api_token() {
  local token
  API_TOKEN_RESULT=""

  if [ -n "${OPENLIST_API_TOKEN:-}" ]; then
    token="$OPENLIST_API_TOKEN"
    if is_api_token_valid "$token"; then
      API_TOKEN_RESULT="$token"
      return 0
    fi
  fi

  if [ -f "$API_TOKEN_PATH" ]; then
    token="$(cat "$API_TOKEN_PATH" 2>/dev/null)"
    if is_api_token_valid "$token"; then
      API_TOKEN_RESULT="$token"
      return 0
    fi
  fi

  login_openlist_api
}

list_enabled_mount_paths() {
  if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DATA_DIR/data.db" ]; then
    sqlite3 "$DATA_DIR/data.db" 'select mount_path from x_storages where disabled = 0 order by "order", id;' 2>/dev/null | sed '/^[[:space:]]*$/d'
    return 0
  fi

  return 1
}

show_enabled_mount_paths() {
  local paths

  paths="$(list_enabled_mount_paths)"
  if [ -n "$paths" ]; then
    print_msg "$BLUE" "当前启用的挂载点："
    printf '%s\n' "$paths"
    echo
  fi
}

reload_all_storages_api() {
  local token="$1"
  local response code message

  print_msg "$BLUE" "正在重新加载全部挂载..."
  response="$(openlist_api_request "POST" "/api/admin/storage/load_all" "$token" "{}")" || {
    print_msg "$RED" "重新加载挂载失败，请确认 OpenList 正在运行。"
    return 1
  }

  code="$(api_response_code "$response")"
  if [ "$code" = "200" ]; then
    print_msg "$GREEN" "全部挂载已重新加载。"
    return 0
  fi

  message="$(api_response_message "$response")"
  print_msg "$RED" "重新加载挂载失败：$message"
  return 1
}

refresh_fs_path_api() {
  local token="$1"
  local target_path="$2"
  local escaped_path response code message body

  escaped_path="$(json_escape "$target_path")"
  body="{\"path\":\"$escaped_path\",\"password\":\"\",\"page\":1,\"per_page\":1,\"refresh\":true}"
  response="$(openlist_api_request "POST" "/api/fs/list" "$token" "$body")" || {
    print_msg "$RED" "刷新目录失败，请确认 OpenList 正在运行。"
    return 1
  }

  code="$(api_response_code "$response")"
  if [ "$code" = "200" ]; then
    print_msg "$GREEN" "已刷新：$target_path"
    return 0
  fi

  message="$(api_response_message "$response")"
  print_msg "$RED" "刷新失败：$target_path，原因：$message"
  return 1
}

refresh_all_mount_roots() {
  local token="$1"
  local paths path ok fail
  local -a mount_paths

  paths="$(list_enabled_mount_paths)"
  if [ -z "$paths" ]; then
    print_msg "$YELLOW" "没有从本地数据库读到启用的挂载点。"
    print_msg "$BLUE" "请先确认网页后台里已有启用的挂载云盘。"
    return 1
  fi

  mount_paths=("${(@f)paths}")
  ok=0
  fail=0
  for path in "${mount_paths[@]}"; do
    refresh_fs_path_api "$token" "$path"
    if [ "$?" -eq 0 ]; then
      ((ok++))
    else
      ((fail++))
    fi
  done

  echo
  printf "刷新结果：%b成功 %s 个%b，%b失败 %s 个%b\n" "$GREEN" "$ok" "$NC" "$RED" "$fail" "$NC"
  if [ "$fail" -gt 0 ]; then
    print_msg "$YELLOW" "如果某个挂载授权过期，可到网页后台重新授权后再刷新。"
    return 1
  fi
}

refresh_all_storage_content() {
  local token="$1"
  local result=0

  reload_all_storages_api "$token" || result=1
  refresh_all_mount_roots "$token" || result=1
  print_msg "$BLUE" "已对所有启用挂载执行刷新，不需要输入具体目录。"
  return "$result"
}

refresh_storage_content() {
  local target_path token arg

  require_installed || return 1
  require_cmd "curl" "macOS 通常自带 curl。"

  if ! get_running_pid >/dev/null 2>&1; then
    print_msg "$YELLOW" "OpenList 尚未运行，正在自动启动..."
    start_openlist || return 1
  fi

  get_openlist_api_token || return 1
  token="$API_TOKEN_RESULT"
  arg="${1:-}"

  if [ -n "$arg" ]; then
    case "$arg" in
      reload|load-all|--reload)
        reload_all_storages_api "$token"
        ;;
      *)
        for target_path in "$@"; do
          refresh_fs_path_api "$token" "$target_path"
        done
        ;;
    esac
    return $?
  fi

  show_enabled_mount_paths
  refresh_all_storage_content "$token"
}

password_menu() {
  local choice new_pass

  require_installed || return 1
  prepare_dirs

  echo "1. 随机生成新密码"
  echo "2. 手动设置新密码"
  prompt_input "请选择(1/2): "
  choice="$REPLY"

  case "$choice" in
    1)
      "$APP_BIN" --data "$DATA_DIR" admin random
      if is_running; then
        print_msg "$BLUE" "正在重启 OpenList，使新密码立即生效并清除登录封禁..."
        restart_openlist
      fi
      ;;
    2)
      prompt_input "请输入新的管理员密码: "
      new_pass="$REPLY"
      if [ -z "$new_pass" ]; then
        print_msg "$RED" "密码不能为空。"
        return 1
      fi
      "$APP_BIN" --data "$DATA_DIR" admin set "$new_pass"
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
  require_installed || return 1
  prepare_dirs

  case "${1:-}" in
    backup)
      shift
      create_backup "$@"
      ;;
    restore)
      shift
      restore_backup "${1:-}"
      ;;
    clear-logs)
      clear_logs
      ;;
    delete-backups)
      delete_backups
      ;;
    refresh)
      shift
      refresh_storage_content "$@"
      ;;
    login-help)
      login_troubleshooting
      ;;
    server|admin)
      "$APP_BIN" --data "$DATA_DIR" "$@"
      ;;
    *)
      "$APP_BIN" "$@"
      ;;
  esac
}

show_logs() {
  prepare_dirs
  touch "$LOG_PATH"
  print_msg "$BLUE" "正在显示实时日志，按 Ctrl + C 退出。"
  tail -f "$LOG_PATH"
}

write_plist() {
  prepare_dirs

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openlist.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BIN</string>
    <string>--data</string>
    <string>$DATA_DIR</string>
    <string>server</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
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
}

enable_autostart() {
  require_installed || return 1
  mkdir -p "$HOME/Library/LaunchAgents"
  write_plist
  launchctl_bootout
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/com.openlist.server" >/dev/null 2>&1 || true
  print_msg "$GREEN" "已设置开机自启。"
}

disable_autostart() {
  if [ -f "$PLIST_PATH" ]; then
    launchctl_bootout
    rm -f "$PLIST_PATH"
    print_msg "$GREEN" "已取消开机自启。"
  else
    print_msg "$YELLOW" "当前未设置开机自启。"
  fi
}

remove_entry() {
  local candidate

  for candidate in "$HOME/.local/bin/openlist" "/usr/local/bin/openlist" "/opt/homebrew/bin/openlist"; do
    if [ -L "$candidate" ]; then
      rm -f "$candidate"
    fi
  done
}

full_uninstall() {
  local confirm

  print_msg "$RED" "警告：此操作将删除 OpenList 程序、数据、日志、自启项及本脚本本身。"
  print_msg "$YELLOW" "位于 $BACKUP_DIR 的备份文件不会自动删除。"
  prompt_input "确认继续吗？(Y/N，默认为Y): "
  confirm="$REPLY"

  if [[ "$confirm" = "n" || "$confirm" = "N" ]]; then
    print_msg "$YELLOW" "已取消卸载。"
    return 0
  fi

  disable_autostart >/dev/null 2>&1 || true
  stop_openlist >/dev/null 2>&1 || true
  remove_entry
  rm -rf "$MANAGER_DIR" "$HOME/Library/Application Support/OpenList" "$HOME/Library/Logs/OpenList"
  print_msg "$GREEN" "OpenList 已彻底卸载完成。"
  exit 0
}

update_script() {
  local temp_installer

  require_cmd "curl" "macOS 通常自带 curl。"
  prepare_dirs
  temp_installer="$TMP_DIR/install_openlist_mac.sh"

  print_msg "$BLUE" "正在从 GitHub 获取最新脚本..."
  curl -fsSL "$INSTALLER_URL" -o "$temp_installer"
  chmod +x "$temp_installer"

  print_msg "$BLUE" "正在更新本地脚本..."
  OPENLIST_SKIP_MENU_AUTORUN=1 zsh "$temp_installer"

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
  echo " 1. 安装 OpenList"
  echo " 2. 更新 OpenList"
  echo " 3. 彻底卸载 (程序、数据及本脚本本身)"
  echo " 4. 查看状态"
  echo " 5. 一键打开网页控制台"
  echo " 6. 密码管理 (忘记密码时重置)"
  echo " 7. 启动 OpenList"
  echo " 8. 停止 OpenList"
  echo " 9. 重启 OpenList"
  echo "10. 查看实时运行日志"
  echo "11. 设置开机自启"
  echo "12. 取消开机自启"
  echo "13. 登录故障排查"
  echo "14. 备份 OpenList 数据"
  echo "15. 还原 OpenList 数据"
  echo "16. 清空日志目录"
  echo "17. 删除整个备份目录"
  echo "18. 更新脚本"
  echo "19. 刷新全部云盘挂载内容"
  echo " 0. 退出脚本"
  echo
}

if [ "$#" -gt 0 ]; then
  run_official_command "$@"
  exit $?
fi

while true; do
  show_menu
  prompt_input "请输入菜单编号: "
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
    10) show_logs ;;
    11) enable_autostart ;;
    12) disable_autostart ;;
    13) login_troubleshooting ;;
    14) create_backup ;;
    15) restore_backup ;;
    16) clear_logs ;;
    17) delete_backups ;;
    18) update_script ;;
    19) refresh_storage_content ;;
    0) exit 0 ;;
    *) print_msg "$RED" "无效输入，请重新选择。" ;;
  esac

  if [ "$choice" != "0" ] && [ "$choice" != "3" ] && [ "$choice" != "10" ]; then
    pause
  fi
done
EOF

chmod +x "$MANAGER_PATH"

remove_legacy_entry

for candidate in "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  if [ -d "$candidate" ] || mkdir -p "$candidate" 2>/dev/null; then
    if [ -w "$candidate" ]; then
      ln -sf "$MANAGER_PATH" "$candidate/openlist"
      LINK_TARGET="$candidate/openlist"
      break
    fi
  fi
done

LINK_TARGET="${LINK_TARGET:-$MANAGER_PATH}"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    SHELL_RC=""
    if [ -n "${ZSH_VERSION:-}" ]; then
      SHELL_RC="$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ]; then
      SHELL_RC="$HOME/.bash_profile"
    elif [ -f "$HOME/.zshrc" ]; then
      SHELL_RC="$HOME/.zshrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      SHELL_RC="$HOME/.bash_profile"
    else
      SHELL_RC="$HOME/.zshrc"
    fi

    mkdir -p "$(dirname "$SHELL_RC")"
    touch "$SHELL_RC"
    if ! grep -F 'export PATH="$HOME/.local/bin:$PATH"' "$SHELL_RC" >/dev/null 2>&1; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$SHELL_RC"
    fi
    export PATH="$HOME/.local/bin:$PATH"
    ;;
esac

warn_if_legacy_remains

cat <<MSG
============================================
OpenList 菜单脚本安装成功

以后你可以在终端输入：
  openlist

即可进入 OpenList 管理脚本菜单

如果提示找不到 openlist，可直接运行：
  $MANAGER_PATH

当前入口位置：
  $LINK_TARGET

如果当前终端还提示找不到 openlist，可执行：
  hash -r
============================================
MSG

if [[ "${OPENLIST_SKIP_MENU_AUTORUN:-0}" != "1" && -t 0 && -t 1 ]]; then
  echo
  echo "正在进入 OpenList 管理菜单..."
  exec "$MANAGER_PATH"
fi
