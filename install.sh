#!/bin/bash
# 一键安装：Python 虚拟环境 + 命令行工具 + 米家登录 + 编译 App + 开机自启
set -euo pipefail
cd "$(dirname "$0")"

PYTHON="${PYTHON:-python3}"
VENV="$HOME/.local/share/mijia-lightbar/venv"
BIN="$HOME/.local/bin"
LABEL="io.github.mijia-lightbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "需要 Xcode 命令行工具：xcode-select --install"; exit 1; }
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 9))' || { echo "需要 Python 3.9+（可用 PYTHON=/path/to/python3 指定）"; exit 1; }

echo "==> 创建 Python 环境并安装 mijiaAPI"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip mijiaAPI

echo "==> 安装命令行工具到 $BIN"
mkdir -p "$BIN"
for f in lamp lamp-serve; do
  { echo "#!$VENV/bin/python"; tail -n +2 "scripts/$f"; } > "$BIN/$f"
  chmod +x "$BIN/$f"
done

if [ ! -f "$HOME/.config/mijia-lamp.json" ]; then
  echo "==> 登录米家（用米家 App 扫终端里的二维码）"
  "$VENV/bin/python" scripts/mijia_login.py
else
  echo "==> 已有 ~/.config/mijia-lamp.json，跳过登录（要重新登录请先删掉它和 ~/.config/mijia-api/auth.json）"
fi

echo "==> 编译并安装 App"
./build.sh "$HOME/Applications"

echo "==> 设置开机自启"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$HOME/Applications/挂灯.app/Contents/MacOS/LightBar</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>20</integer>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/lightbar.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "安装完成。菜单栏里会出现一个灯泡图标。试试： $BIN/lamp status"
echo "（把 $BIN 加入 PATH 后可直接用 lamp 命令）"
