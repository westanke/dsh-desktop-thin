#!/usr/bin/env bash
# dsh-desktop-thin 一键启动器。
#
# 流程：解析配置 → 判断是否首次启动 → 缺运行时则自动下载（tools/bootstrap.sh）
#       → 设 DSH_HOME 环境变量 → 直启 Electron（薄壳，内核 = 已下载的 dsh）。
#
# 首次启动的判断依据：三个运行时是否都可用（Electron ≥ 33、Node ≥ 22.15、任意可用 dsh）。
# 齐备就直接启动（零下载）；缺任何一项进自举。
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[ "$SCRIPT_DIR" = "$SCRIPT_PATH" ] && SCRIPT_DIR="."
SHELL_DIR="$(cd "$SCRIPT_DIR" && pwd)"
CONFIG="$SHELL_DIR/config.json"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dsh-thin"
USER_CONFIG="$USER_CONFIG_DIR/config.json"
BOOTSTRAP="$SHELL_DIR/tools/bootstrap.sh"
RUNTIME_DIR="${HOME}/.dsh-thin/runtime"

err()  { echo "✖ $*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

NODE_MIN_MAJOR=22; NODE_MIN_MINOR=15
ELECTRON_MIN_MAJOR=33

[ -f "$CONFIG" ] || err "配置文件缺失: $CONFIG"

config_value() {
  local key="$1" v=""
  if [ -f "$USER_CONFIG" ]; then
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$USER_CONFIG" | head -1)"
  fi
  [ -z "$v" ] && [ -f "$CONFIG" ] && v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG" | head -1)"
  printf '%s' "$v"
}

version_ge() {
  local a="$1" b="$2" am aj bm bj
  am=$(printf '%s' "$a" | sed -n 's/^v\{0,1\}\([0-9]*\)\..*/\1/p')
  aj=$(printf '%s' "$a" | sed -n 's/^v\{0,1\}[0-9]*\.\([0-9]*\).*/\1/p')
  bm=$(printf '%s' "$b" | sed -n 's/^v\{0,1\}\([0-9]*\)\..*/\1/p')
  bj=$(printf '%s' "$b" | sed -n 's/^v\{0,1\}[0-9]*\.\([0-9]*\).*/\1/p')
  [ -z "$am" ] && am=0; [ -z "$aj" ] && aj=0
  [ -z "$bm" ] && bm=0; [ -z "$bj" ] && bj=0
  [ "$am" -gt "$bm" ] && return 0
  [ "$am" -lt "$bm" ] && return 1
  [ "$aj" -ge "$bj" ]
}

ELECTRON=""; NODE_BIN=""; SYSTEM_DSH=""

detect() {
  local cfg_e cfg_d cfg_n
  cfg_e="$(config_value electron || true)"
  cfg_d="$(config_value systemDsh || true)"
  cfg_n="$(config_value nodeBinDir || true)"
  if [ -n "$cfg_e" ] && [ -x "$cfg_e" ]; then ELECTRON="$cfg_e"
  elif have electron; then ELECTRON="$(command -v electron)"
  else for c in /usr/bin/electron /usr/local/bin/electron "$RUNTIME_DIR"/electron-*/electron; do [ -x "$c" ] && { ELECTRON="$c"; break; }; done; fi
  if [ -n "$cfg_n" ] && [ -x "$cfg_n/node" ]; then NODE_BIN="$cfg_n/node"
  elif have node; then NODE_BIN="$(command -v node)"
  else for c in /usr/local/bin/node /usr/bin/node /usr/local/nodejs/bin/node "$RUNTIME_DIR"/node-*/bin/node; do [ -x "$c" ] && { NODE_BIN="$c"; break; }; done; fi
  if [ -n "$cfg_d" ] && { [ -x "$cfg_d" ] || [ -f "$cfg_d" ]; }; then SYSTEM_DSH="$cfg_d"
  elif have dsh; then SYSTEM_DSH="$(command -v dsh)"
  else for c in /usr/local/bin/dsh /usr/bin/dsh /usr/local/nodejs/bin/dsh /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js; do [ -e "$c" ] && { SYSTEM_DSH="$c"; break; }; done; fi
}

verify() {
  if [ -n "$ELECTRON" ]; then
    local v; v="$("$ELECTRON" --version 2>/dev/null | head -1)"
    version_ge "$v" "v${ELECTRON_MIN_MAJOR}.0" || ELECTRON=""
  fi
  if [ -n "$NODE_BIN" ]; then
    local v; v="$("$NODE_BIN" --version 2>/dev/null | head -1)"
    version_ge "$v" "v${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}" || NODE_BIN=""
  fi
}

missing_list() {
  local m=""
  [ -z "$ELECTRON" ] && m="$m electron"
  [ -z "$NODE_BIN" ] && m="$m node"
  [ -z "$SYSTEM_DSH" ] && m="$m dsh"
  printf '%s' "${m# }"
}

detect
verify
MISSING="$(missing_list)"

# 缺运行时且当前不在终端里（双击启动器，Terminal=false 无输出）：借终端模拟器
# 重跑自己，让下载全过程可见。DSH_BOOTSTRAP_IN_TTY=1 防死循环。
if [ -n "$MISSING" ] && [ ! -t 0 ] && [ "${DSH_BOOTSTRAP_IN_TTY:-}" != "1" ]; then
  for term in deepin-terminal x-terminal-emulator gnome-terminal konsole xfce4-terminal; do
    if command -v "$term" >/dev/null 2>&1; then
      exec env DSH_BOOTSTRAP_IN_TTY=1 "$term" -e bash "$SCRIPT_PATH"
    fi
  done
fi

if [ -n "$MISSING" ]; then
  say ""
  say "══════════════════════════════════════════════════════"
  say " 首次启动：缺少运行时 -> $MISSING"
  say "══════════════════════════════════════════════════════"
  say ""
  say "薄壳本身很小，运行时按需获取。现在自动下载（国内镜像+测速选最快）。"
  say ""
  [ -x "$BOOTSTRAP" ] || err "自举脚本缺失或不可执行: $BOOTSTRAP"
  # 等待安装期后台预下载（若还在跑）完成，避免争抢 runtime 目录。
  LOCK="$RUNTIME_DIR/.bootstrap-install.lock"
  if [ -d "$LOCK" ]; then
    say "检测到预下载进行中，等待…"
    waited=0
    while [ -d "$LOCK" ] && [ "$waited" -lt 900 ]; do sleep 5; waited=$((waited+5)); [ $((waited%60)) -eq 0 ] && say "  已等待 ${waited}s…"; done
    [ -d "$LOCK" ] || say "  预下载完成。"
  fi
  bash "$BOOTSTRAP" install || err "运行时下载失败，请检查网络或手动执行 bootstrap.sh"
  # 重新读取写回后的路径
  detect; verify
fi

# 选 electron 启动：用户配置 > PATH > 私有 runtime
ELECTRON="$(config_value electron)"; [ -z "$ELECTRON" ] && ELECTRON="$(command -v electron)"
[ -x "$ELECTRON" ] || ELECTRON="$(ls "$RUNTIME_DIR"/electron-*/electron 2>/dev/null | head -1)"
[ -n "$ELECTRON" ] && [ -x "$ELECTRON" ] || err "找不到 electron，无法启动"

# DSH_HOME：每用户私有内核家。多 Home 切换时由 main.js 通过 IPC 重指。
export DSH_HOME="${DSH_HOME:-$HOME/.dsh-thin/home}"

say "启动 dsh-desktop-thin（electron=$ELECTRON, DSH_HOME=$DSH_HOME）"
exec "$ELECTRON" "$SHELL_DIR"
