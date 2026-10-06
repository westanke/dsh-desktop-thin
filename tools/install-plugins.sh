#!/usr/bin/env bash
# 默认插件安装：含「插件市场」(dshmarket)。
#
# 设计（沿用已验证的自研壳逻辑）：
#   - 幂等：dsh plugin --profile web list 查重，已装跳过；传 force 重装全部。
#   - 单插件失败只告警不阻塞壳启动。
#   - dsh 命令缺失时静默退出。
#   - 清单 PLUGINS：@xmanrui/dsh-im / dsh-pocket-relay / dsh-mcp-panel / dshmarket（含插件市场）。
#
# 用法：
#   install-plugins.sh            正常安装（已装跳过）
#   install-plugins.sh force      强制重装全部
#   install-plugins.sh check      只查询缺哪些（空格分隔打印，exit 1=有缺；零副作用）
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[ "$SCRIPT_DIR" = "$SCRIPT_PATH" ] && SCRIPT_DIR="."
SHELL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SHELL_DIR/config.json"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

FORCE="${1:-}"
DSH_BIN=""
# 优先用 config 里写回的 dsh，否则 PATH
cfg_dsh="$(sed -n 's/.*"systemDsh"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' "$CONFIG" 2>/dev/null | head -1)"
[ -n "$cfg_dsh" ] && [ -e "$cfg_dsh" ] && DSH_BIN="$cfg_dsh"
[ -z "$DSH_BIN" ] && DSH_BIN="$(command -v dsh || true)"

# 默认插件清单（npm 真实包名；dshmarket = 插件市场）
PLUGINS=("@xmanrui/dsh-im" dsh-pocket-relay dsh-mcp-panel dshmarket)

installed() {
  local pkg="$1"
  printf '%s' "$LIST_OUT" | grep -q "$pkg"
}

# ── check 模式：零副作用、快速返回（供 start-shell 决定是否补装）──
if [ "$FORCE" = "check" ]; then
  [ -n "$DSH_BIN" ] || exit 0
  LIST_OUT="$("$DSH_BIN" plugin --profile web list 2>/dev/null || true)"
  miss=""
  for pkg in "${PLUGINS[@]}"; do installed "$pkg" || miss="$miss $pkg"; done
  if [ -n "$miss" ]; then printf '%s\n' "${miss# }"; exit 1; fi
  exit 0
fi

[ -n "$DSH_BIN" ] || { say "（未找到 dsh，跳过插件安装）"; exit 0; }
LIST_OUT="$("$DSH_BIN" plugin --profile web list 2>/dev/null || true)"

# 确保 pnpm（dsh plugin add 依赖）
ensure_pnpm() {
  if have pnpm; then PNPM_BIN="$(command -v pnpm)"; return 0; fi
  local ndir; ndir="$(dirname "$DSH_BIN")"
  if [ -x "$ndir/pnpm" ]; then PNPM_BIN="$ndir/pnpm"; return 0; fi
  local npm_bin; npm_bin="$(command -v npm 2>/dev/null || true)"
  [ -z "$npm_bin" ] && [ -x "$ndir/npm" ] && npm_bin="$ndir/npm"
  if [ -n "$npm_bin" ]; then
    info "未找到 pnpm，用户级安装（~/.local）…"
    "$npm_bin" install -g --prefix "$HOME/.local" pnpm --registry=https://registry.npmmirror.com >/dev/null 2>&1 || true
    if [ -x "$HOME/.local/bin/pnpm" ]; then export PATH="$HOME/.local/bin:$PATH"; PNPM_BIN="$HOME/.local/bin/pnpm"; return 0; fi
  fi
  return 1
}

info "使用内核: $DSH_BIN"
if ! ensure_pnpm; then
  bad "没有 pnpm 且自动安装失败，插件无法安装（不影响壳启动）。"
  bad "手动：corepack enable pnpm  或  npm i -g --prefix \$HOME/.local pnpm"
  exit 0
fi
say ""

# ── 安装循环 ────────────────────────────────────────────────────────────
for pkg in "${PLUGINS[@]}"; do
  if [ "$FORCE" != "force" ] && installed "$pkg"; then
    ok "$pkg 已装，跳过"
    continue
  fi
  info "安装 $pkg …"
  if "$DSH_BIN" plugin --profile web add "$pkg" >/dev/null 2>&1; then
    ok "$pkg 安装成功"
  else
    bad "$pkg 安装失败（继续其余插件）"
  fi
done

say ""
ok "默认插件处理完成（含插件市场 dshmarket）"
exit 0
