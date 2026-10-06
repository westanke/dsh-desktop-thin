#!/usr/bin/env bash
# dsh-desktop-thin 运行时自举：在没有任何 Node/Electron 的机器上把薄壳跑起来。
#
# 薄壳哲学（与官方 self-contained 路线相反）：装包装的是纯 Electron 外壳 JS
# （≈160KB），Electron / Node / dsh 内核全部首启按需下载到用户私有 runtime 目录。
#
# 设计要点（沿用已验证的自研壳策略）：
#   - 只用 bash + curl/wget + tar/unzip，不依赖 Node（自举循环规避）。
#   - 国内镜像优先（npmmirror → 华为云），并做镜像测速选最快。
#   - 每个下载产物做 sha256 校验（官方 SHASUMS256.txt 或 deb 内嵌清单）。
#   - dsh 内核走 npm 国内源（registry.npmmirror.com）按需安装。
#
# 用法：
#   bootstrap.sh check     只检测，报告缺什么（exit 1 表示有缺失）
#   bootstrap.sh install   检测并下载缺失项
#   bootstrap.sh run       保证就绪后启动壳

set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[ "$SCRIPT_DIR" = "$SCRIPT_PATH" ] && SCRIPT_DIR="."
SHELL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SHELL_DIR/config.json"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dsh-thin"
USER_CONFIG="$USER_CONFIG_DIR/config.json"
# 运行时节点的官方落点：$DSH_HOME/dsh-runtimes/...（与官方 Python/Office 同目录树）
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RUNTIME_DIR="$DSH_HOME/dsh-runtimes/dsh-thin-runtime"

# 国内镜像（全部实测可用）。顺序即优先级。
NODE_MIRRORS=(
  "https://npmmirror.com/mirrors/node"
  "https://mirrors.huaweicloud.com/nodejs"
)
ELECTRON_MIRRORS=(
  "https://npmmirror.com/mirrors/electron"
  "https://mirrors.huaweicloud.com/electron"
)
NPM_REGISTRY="https://registry.npmmirror.com"

NODE_WANT="v24.19.0"
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=15
ELECTRON_WANT="v33.3.0"
ELECTRON_MIN_MAJOR=33
# dsh 内核版本：与壳同版本（官方铁律：dsh 升级即 Desktop 发版）。
DSH_VERSION="$(sed -n 's/.*"dshVersion"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' "$CONFIG" 2>/dev/null || true)"
[ -z "$DSH_VERSION" ] && DSH_VERSION="0.2.0"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

require_basics() {
  local missing="" c
  for c in mkdir rm cp mv sed grep head tar; do
    have "$c" || missing="$missing $c"
  done
  if ! have curl && ! have wget; then missing="$missing curl/wget"; fi
  if [ -n "$missing" ]; then
    bad "缺少基础命令：$missing"
    say "    sudo apt install coreutils sed grep tar gzip curl unzip"
    return 1
  fi
  return 0
}

fetch() {
  local url="$1" dest="$2"
  if have curl; then
    curl -fSL --retry 2 --connect-timeout 20 -o "$dest" "$url" 2>/dev/null
  elif have wget; then
    wget -q -O "$dest" "$url"
  else
    return 1
  fi
}

verify_sha256() {
  local file="$1" name="$2" ver="$3" mirror="$4" kind="$5"
  local manifest_file="${6:-}"
  have sha256sum || { say "  ⚠ 无 sha256sum，跳过校验（仅信 HTTPS 来源）"; return 0; }
  local expected actual manifest_src
  if [ -n "$manifest_file" ] && [ -f "$manifest_file" ]; then
    manifest_src="$manifest_file"
    expected="$(grep -E "^[0-9a-f]{64}[[:space:]]+\*?$name\$" "$manifest_src" | awk '{print $1}')" || true
  else
    manifest_src="$RUNTIME_DIR/SHASUMS256.$kind.$ver.txt"
    expected="$(fetch "$mirror/$ver/SHASUMS256.txt" "$manifest_src" \
      && grep -E "^[0-9a-f]{64}[[:space:]]+\*?$name\$" "$manifest_src" | awk '{print $1}')" || true
    rm -f "$manifest_src" 2>/dev/null
  fi
  if [ -z "$expected" ]; then
    say "  ⚠ 未获得 $name 的校验值，跳过校验（仅信 HTTPS 来源）"
    return 0
  fi
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" = "$expected" ]; then ok "sha256 校验通过"; return 0; fi
  bad "sha256 校验失败：期望 $expected，实际 $actual"
  return 1
}

arch_label() {
  local a; a="$(uname -m)"
  case "$a" in x86_64) printf x64 ;; aarch64) printf arm64 ;; *) printf "$a" ;; esac
}

speed_of() {
  local url="$1" bytes="${2:-262144}" out
  if have curl; then
    out=$(curl -sSL --connect-timeout 8 --max-time 15 -r "0-$((bytes-1))" -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null) || out=0
  elif have wget; then
    local t0 t1
    t0=$(date +%s%N 2>/dev/null || echo 0)
    wget -q --timeout=15 -O /dev/null "$url" 2>/dev/null || { echo 0; return; }
    t1=$(date +%s%N 2>/dev/null || echo 0)
    [ "$t1" -gt "$t0" ] && out=$(( bytes * 1000000000 / (t1 - t0) )) || out=0
  else
    out=0
  fi
  printf '%.0f' "${out:-0}" 2>/dev/null || printf '0'
}

pick_fastest() {
  local version="$1" sample_file="$2"; shift 2
  local best="" best_speed=0 m url sp tried=0
  for m in "$@"; do
    [ "$tried" -ge 3 ] && break
    url="$m/$version/$sample_file"
    sp=$(speed_of "$url")
    tried=$((tried + 1))
    info "测速 $m → $((sp / 1024)) KB/s" >&2
    if [ "$sp" -gt "$best_speed" ]; then best_speed="$sp"; best="$m"; fi
  done
  printf '%s' "$best"
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

locate() {
  local configured="$1" name="$2"; shift 2
  if [ -n "$configured" ] && [ -x "$configured" ]; then printf '%s' "$configured"; return 0; fi
  if have "$name"; then command -v "$name"; return 0; fi
  local c
  for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}

config_value() {
  local key="$1" v=""
  if [ -f "$USER_CONFIG" ]; then
    v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$USER_CONFIG" | head -1)"
  fi
  [ -z "$v" ] && [ -f "$CONFIG" ] && v="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG" | head -1)"
  printf '%s' "$v"
}

NODE_BIN=""; ELECTRON_BIN=""; DSH_BIN=""

detect() {
  local cfg_electron cfg_dsh cfg_nodebin
  cfg_electron="$(config_value electron || true)"
  cfg_dsh="$(config_value systemDsh || true)"
  cfg_nodebin="$(config_value nodeBinDir || true)"
  NODE_BIN="$(locate "${cfg_nodebin:+$cfg_nodebin/node}" node \
    /usr/local/bin/node /usr/bin/node /usr/local/nodejs/bin/node \
    /opt/node/bin/node /snap/bin/node \
    "${HOME}/.nvm/versions/node/"*/bin/node \
    "${HOME}/.local/bin/node" \
    "$RUNTIME_DIR"/node-*/bin/node || true)"
  ELECTRON_BIN="$(locate "$cfg_electron" electron \
    /usr/bin/electron /usr/local/bin/electron /usr/lib/electron/electron \
    /opt/electron/electron "${HOME}/.local/bin/electron" \
    "$RUNTIME_DIR"/electron-*/electron || true)"
  local node_dir=""
  [ -n "$NODE_BIN" ] && node_dir="$(dirname "$NODE_BIN")"
  DSH_BIN="$(locate "$cfg_dsh" dsh \
    ${node_dir:+"$node_dir/dsh"} \
    /usr/local/bin/dsh /usr/bin/dsh /usr/local/nodejs/bin/dsh \
    "${HOME}/.local/bin/dsh" "${HOME}/.yarn/bin/dsh" \
    "${HOME}/.nvm/versions/node/"*/bin/dsh \
    "${HOME}/.local/share/pnpm/dsh" || true)"
  if [ -z "$DSH_BIN" ] && [ -n "$NODE_BIN" ]; then
    local candidate
    for candidate in \
      "${node_dir%/bin}"/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js \
      "${HOME}/.nvm/versions/node/"*/lib/node_modules/@deepseek-ai/dsh/lib/bin.js; do
      [ -f "$candidate" ] && { DSH_BIN="$candidate"; break; }
    done
  fi
}

report() {
  say "运行时检测："
  if [ -n "$NODE_BIN" ]; then
    local v; v="$("$NODE_BIN" --version 2>/dev/null || echo '?')"
    if version_ge "$v" "v${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}"; then ok "Node      $v   $NODE_BIN"; else bad "Node $v (需要 ≥ v${NODE_MIN_MAJOR}.${NODE_MIN_MINOR})"; NODE_BIN=""; fi
  else bad "Node      未找到"; fi
  if [ -n "$ELECTRON_BIN" ]; then
    local v; v="$("$ELECTRON_BIN" --version 2>/dev/null || echo '?')"
    if version_ge "$v" "v${ELECTRON_MIN_MAJOR}.0"; then ok "Electron  $v   $ELECTRON_BIN"; else bad "Electron $v (需要 ≥ v${ELECTRON_MIN_MAJOR})"; ELECTRON_BIN=""; fi
  else bad "Electron  未找到"; fi
  if [ -n "$DSH_BIN" ]; then ok "dsh 内核   $DSH_BIN"; else bad "dsh 内核   未找到"; fi
  say ""
}

missing() {
  local m=""
  [ -z "$NODE_BIN" ] && m="$m node"
  [ -z "$ELECTRON_BIN" ] && m="$m electron"
  [ -z "$DSH_BIN" ] && m="$m dsh"
  printf '%s' "${m# }"
}

install_node() {
  say "下载 Node ${NODE_WANT}（国内镜像优先）"
  mkdir -p "$RUNTIME_DIR"
  local arch file url dest mirror
  arch="$(uname -m)"; case "$arch" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac
  file="node-${NODE_WANT}-linux-${arch}.tar.gz"
  dest="$RUNTIME_DIR/$file"
  local fastest ordered=()
  fastest="$(pick_fastest "$NODE_WANT" "$file" "${NODE_MIRRORS[@]}")"
  if [ -n "$fastest" ]; then
    for m in "${NODE_MIRRORS[@]}"; do [ "$m" = "$fastest" ] && ordered=("$m" "${ordered[@]}") || ordered+=("$m"); done
  else ordered=("${NODE_MIRRORS[@]}"); fi
  for mirror in "${ordered[@]}"; do
    url="$mirror/$NODE_WANT/$file"
    info "$url"
    if fetch "$url" "$dest" && verify_sha256 "$dest" "$file" "$NODE_WANT" "$mirror" node; then break; fi
    bad "该镜像失败或校验未过，换下一个"; dest=""
  done
  [ -n "$dest" ] && [ -f "$dest" ] || { bad "所有镜像都下载失败"; return 1; }
  tar -xzf "$dest" -C "$RUNTIME_DIR" || { bad "解压失败"; return 1; }
  rm -f "$dest"
  NODE_BIN="$RUNTIME_DIR/node-${NODE_WANT}-linux-${arch}/bin/node"
  chmod +x "$NODE_BIN" 2>/dev/null
  ok "Node 已装到 $NODE_BIN"
}

install_electron() {
  say "下载 Electron ${ELECTRON_WANT}（约 180MB，请耐心）"
  mkdir -p "$RUNTIME_DIR"
  local arch file url dest mirror
  arch="$(uname -m)"; case "$arch" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac
  file="electron-${ELECTRON_WANT}-linux-${arch}.zip"
  dest="$RUNTIME_DIR/$file"
  local fastest ordered=()
  fastest="$(pick_fastest "$ELECTRON_WANT" "$file" "${ELECTRON_MIRRORS[@]}")"
  if [ -n "$fastest" ]; then
    for m in "${ELECTRON_MIRRORS[@]}"; do [ "$m" = "$fastest" ] && ordered=("$m" "${ordered[@]}") || ordered+=("$m"); done
  else ordered=("${ELECTRON_MIRRORS[@]}"); fi
  for mirror in "${ordered[@]}"; do
    url="$mirror/$ELECTRON_WANT/$file"
    info "$url"
    if fetch "$url" "$dest" && verify_sha256 "$dest" "$file" "$ELECTRON_WANT" "$mirror" electron; then break; fi
    bad "该镜像失败或校验未过，换下一个"; dest=""
  done
  [ -n "$dest" ] && [ -f "$dest" ] || { bad "所有镜像都下载失败"; return 1; }
  local target="$RUNTIME_DIR/electron-${ELECTRON_WANT}"
  mkdir -p "$target"
  have unzip || { bad "缺少 unzip"; return 1; }
  unzip -q -o "$dest" -d "$target" || { bad "解压失败"; return 1; }
  rm -f "$dest"
  ELECTRON_BIN="$target/electron"
  chmod +x "$ELECTRON_BIN" 2>/dev/null
  ok "Electron 已装到 $ELECTRON_BIN"
}

install_dsh() {
  say "安装 dsh 内核（npm 国内源，版本钉死 ${DSH_VERSION}）…"
  [ -n "$NODE_BIN" ] || { bad "需要先有 Node"; return 1; }
  local npm_bin="${NODE_BIN%/bin/node}/bin/npm"
  [ -x "$npm_bin" ] || npm_bin="$(command -v npm || true)"
  [ -n "$npm_bin" ] || { bad "找不到 npm"; return 1; }
  "$npm_bin" install --global --registry "$NPM_REGISTRY" "@deepseek-ai/dsh@${DSH_VERSION}" >/dev/null 2>&1 \
    && { DSH_BIN="$(command -v dsh || echo "${NODE_BIN%/bin/node}/bin/dsh")"; ok "dsh@${DSH_VERSION} 已通过 npm 安装"; return 0; }
  bad "npm 安装失败（dsh@${DSH_VERSION}）"; return 1
}

writeback() {
  mkdir -p "$USER_CONFIG_DIR"
  local tmp="$USER_CONFIG.tmp.$$"
  if [ -f "$USER_CONFIG" ]; then cp "$USER_CONFIG" "$tmp"; else cp "$CONFIG" "$tmp" 2>/dev/null || { bad "找不到 $CONFIG"; return 1; }; fi
  set_kv() {
    local key="$1" value="$2"
    local escaped; escaped=$(printf '%s' "$value" | sed 's/[&/\\]/\\&/g')
    sed -i "s|\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"${key}\": \"${escaped}\"|" "$tmp"
  }
  [ -n "$ELECTRON_BIN" ] && set_kv electron "$ELECTRON_BIN"
  [ -n "$NODE_BIN" ] && set_kv nodeBinDir "$(dirname "$NODE_BIN")"
  [ -n "$DSH_BIN" ] && set_kv systemDsh "$DSH_BIN"
  mv "$tmp" "$USER_CONFIG"
  ok "已写回用户配置：$USER_CONFIG"
}

cmd="${1:-check}"
detect
case "$cmd" in
  check)
    report
    m="$(missing)"
    if [ -z "$m" ]; then say "全部就绪。"; exit 0; fi
    say "缺失：$m"; say "执行 bootstrap.sh install 自动下载（国内源优先）"; exit 1 ;;
  install)
    require_basics || exit 1
    detect
    m="$(missing)"
    [ -z "$m" ] && { say "无需下载，全部就绪。"; exit 0; }
    say "需要下载：$m"
    case "$m" in *node*) install_node || exit 1 ;; esac
    case "$m" in *electron*) install_electron || exit 1 ;; esac
    case "$m" in *dsh*) install_dsh || exit 1 ;; esac
    writeback
    say "✅ 自举完成。"; exit 0 ;;
  run)
    bootstrap_run() {
      require_basics || exit 1
      detect
      m="$(missing)"
      if [ -n "$m" ]; then
        say "首次启动：下载缺失运行时（$m）…"
        case "$m" in *node*) install_node || exit 1 ;; esac
        case "$m" in *electron*) install_electron || exit 1 ;; esac
        case "$m" in *dsh*) install_dsh || exit 1 ;; esac
        writeback
      fi
      local electron
      electron="$(config_value electron)"; [ -z "$electron" ] && electron="$(command -v electron)"
      [ -n "$electron" ] && exec "$electron" "$SHELL_DIR" || { bad "找不到 electron，无法启动"; exit 1; }
    }
    bootstrap_run ;;
  *) say "用法: bootstrap.sh [check|install|run]"; exit 1 ;;
esac
