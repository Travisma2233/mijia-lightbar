#!/bin/bash
# 卸载：停止并移除 App、命令行工具、开机自启。默认保留登录凭据；加 --purge 一并删除。
set -uo pipefail
LABEL="io.github.mijia-lightbar"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/挂灯.app" "$HOME/.local/share/mijia-lightbar"
rm -f "$HOME/.local/bin/lamp" "$HOME/.local/bin/lamp-serve" "$HOME/Library/Logs/lightbar.log" "$HOME/Library/Logs/lightbar.err"
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.config/mijia-api" "$HOME/.config/mijia-lamp.json" "$HOME/.config/lamp-calibration.json"
  defaults delete io.github.mijia-lightbar 2>/dev/null
  echo "已卸载，并删除登录凭据、设备信息和标定数据。"
else
  echo "已卸载。登录凭据（~/.config/mijia-api）、设备信息和标定数据已保留；加 --purge 可一并删除。"
fi
