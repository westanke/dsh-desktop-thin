#!/usr/bin/env bash
# 把薄壳代码打成「只含壳代码」的 deb（约 160KB）。
#
# 不走 electron-builder：它的职责是把 Electron 打进包，而本壳的招牌是
# Electron / Node / dsh 全部首次启动按需下载。这里用 dpkg-deb 手工打包，
# deb 里只有纯文本 JS + shell + 图标，不含任何运行时。
set -uo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[ "$SCRIPT_DIR" = "$SCRIPT_PATH" ] && SCRIPT_DIR="."
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STAGE="$ROOT/debian"
PKG_NAME="dsh-desktop-thin"
VERSION="${2:-${DEB_VERSION:-}}"
if [ -z "$VERSION" ]; then
  VERSION="$(node -p "require('$ROOT/package.json').version" 2>/dev/null || echo '0.1.0')"
fi
OUTPUT_DIR="$ROOT/release"

ARCH="${1:-amd64}"
case "$ARCH" in
  amd64|x86_64) ARCH="amd64"; DEB_ARCH="amd64"; NODE_ARCH_LABEL="x64" ;;
  arm64|aarch64|arm) ARCH="arm64"; DEB_ARCH="arm64"; NODE_ARCH_LABEL="arm64" ;;
  *) echo "✖ 不支持的架构: $ARCH（仅 amd64 / arm64）" >&2; exit 1 ;;
esac

err() { echo "✖ $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ -f "$ROOT/package.json" ] || err "找不到 package.json"
command -v dpkg-deb >/dev/null 2>&1 || err "缺少 dpkg-deb（dpkg 工具）"

# ── 清空并重建 stage ───────────────────────────────────────────────────
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN"
APP_DIR="$STAGE/opt/$PKG_NAME"
mkdir -p "$APP_DIR"

# ── 复制壳代码（不进包：node_modules、.git、release、测试产物）──────────
say "复制壳代码…"
cp -r "$ROOT/src"           "$APP_DIR/src"
cp -r "$ROOT/tools"         "$APP_DIR/tools"
cp    "$ROOT/config.json"   "$APP_DIR/config.json"
cp    "$ROOT/start-shell.sh" "$APP_DIR/start-shell.sh"
cp    "$ROOT/package.json"  "$APP_DIR/package.json"
cp    "$ROOT/LICENSE"       "$APP_DIR/LICENSE" 2>/dev/null || true

# 排除测试文件与打包工具自身
find "$APP_DIR/src" -name '*.test.js' -delete 2>/dev/null
rm -f "$APP_DIR/tools/build-deb.sh"

# 权限兜底：普通用户能读能进；启动脚本钉 0755
chmod -R a+rX "$APP_DIR"
chmod 0755 "$APP_DIR/start-shell.sh"
chmod 0755 "$APP_DIR/tools/bootstrap.sh"
chmod 0644 "$APP_DIR/config.json"
chmod 0644 "$APP_DIR/package.json"

# ── DEBIAN 控制文件 ────────────────────────────────────────────────────
say "写 DEBIAN/control…"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $DEB_ARCH
Depends: bash, curl | wget, tar, gzip, unzip, ca-certificates
Maintainer: dsh-desktop-thin <noreply@example.com>
Description: DeepSeek Harness thin desktop shell (Linux $NODE_ARCH_LABEL)
 面向 Deepin / UOS / Linux $NODE_ARCH_LABEL 的 DeepSeek Harness 薄壳。
 把命令行 agent 运行时 dsh 包进 Electron 窗口，双击即用。
 .
 本包只包含壳代码（约 160KB）。Electron、Node 与 dsh 内核在首次
 启动时按需下载（国内镜像优先），见 tools/bootstrap.sh。
Homepage: https://github.com/dsh-desktop-thin/dsh-desktop-thin
EOF

# conffiles：全局 config.json 受 dpkg 保护
cat > "$STAGE/DEBIAN/conffiles" <<EOF
/opt/$PKG_NAME/config.json
EOF

# postinst：安装后自检 + 以登录用户身份后台预下载运行时（不阻塞 apt）
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
INSTALL_DIR="/opt/dsh-desktop-thin"
BOOTSTRAP="$INSTALL_DIR/tools/bootstrap.sh"
echo ""
echo "dsh-desktop-thin 已安装到 $INSTALL_DIR"
echo ""
if [ -x "$BOOTSTRAP" ]; then
  echo "正在检查运行时依赖（Electron / Node / dsh）…"
  echo ""
  bash "$BOOTSTRAP" check || {
    echo ""
    echo "提示：缺少运行时依赖。可自动下载："
    echo "  bash $BOOTSTRAP install"
    echo "或直接启动（首次启动也会自动补齐）："
    echo "  bash $INSTALL_DIR/start-shell.sh"
    echo ""
  }
fi

# 以「真实登录用户」身份在后台预下载运行时（约 180MB，不阻塞安装）。
if [ "${DSH_NO_POSTINST_DOWNLOAD:-}" = "1" ]; then
  echo "（已设置 DSH_NO_POSTINST_DOWNLOAD=1，跳过安装后预下载）"
else
  INSTALL_USER="${SUDO_USER:-}"
  if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
    INSTALL_USER="$(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -v '^root$' | head -1)"
  fi
  if [ -z "$INSTALL_USER" ]; then
    for candidate in /home/*; do
      [ -d "$candidate" ] || continue
      name="$(basename "$candidate")"
      if id "$name" >/dev/null 2>&1; then INSTALL_USER="$name"; break; fi
    done
  fi
  if [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != "root" ] && id "$INSTALL_USER" >/dev/null 2>&1 && [ -x "$BOOTSTRAP" ]; then
    echo "正在为 $INSTALL_USER 后台预下载运行时（约 180MB，不阻塞安装）…"
    LOG="/home/$INSTALL_USER/.dsh-thin/bootstrap-postinst.log"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$INSTALL_USER" -- setsid nohup bash "$BOOTSTRAP" install >>"$LOG" 2>&1 &
    else
      su - "$INSTALL_USER" -c "setsid nohup bash '$BOOTSTRAP' install >>'$LOG' 2>&1 &"
    fi
    echo "下载在后台进行；完成后双击启动器即可直接使用。"
  else
    echo "（未能识别登录用户，跳过预下载；首次启动时会自动补齐）"
  fi
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# ── 桌面图标 + .desktop ────────────────────────────────────────────────
say "写桌面启动器…"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/icons/hicolor/128x128/apps"
[ -f "$ROOT/assets/icon.png" ] && cp "$ROOT/assets/icon.png" "$STAGE/usr/share/icons/hicolor/128x128/apps/$PKG_NAME.png"
cat > "$STAGE/usr/share/applications/$PKG_NAME.desktop" <<EOF
[Desktop Entry]
Name=DSH Thin Desktop
GenericName=DeepSeek Harness 薄壳
Comment=DeepSeek Harness agent 运行时桌面薄壳（首次启动会下载运行时）
Exec=bash /opt/$PKG_NAME/start-shell.sh
Terminal=false
Type=Application
Icon=$PKG_NAME
StartupWMClass=dsh-desktop-thin
Categories=Development;Utility;
EOF

# ── 打包 ───────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
DEB_FILE="$OUTPUT_DIR/dsh-desktop-thin-${VERSION}-${ARCH}.deb"
say "打包 $DEB_FILE …"
dpkg-deb --build -Zgzip --root-owner-group "$STAGE" "$DEB_FILE" || err "dpkg-deb 打包失败"

SIZE=$(du -h "$DEB_FILE" | cut -f1)
say ""
say "✅ 完成：$DEB_FILE"
say "   体积：$SIZE"
say ""
