#!/bin/bash
# 编译菜单栏 App「挂灯」并打包为 .app。需要 Xcode 命令行工具（xcode-select --install）。
# 用法: ./build.sh [输出目录，默认 ~/Applications]
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Applications}"
APP="$OUT/挂灯.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "编译 LightBar…"
# 命令行 swiftc 不带 SwiftUI 宏插件，所以源码里不使用 @State 等宏（用 @StateObject 代替）
swiftc -O -parse-as-library -swift-version 5 LightBar/LightBar.swift -o "$TMP/LightBar"

echo "生成图标…"
swiftc LightBar/make_icon.swift -o "$TMP/make_icon"
(cd "$TMP" && ./make_icon && mkdir AppIcon.iconset &&
  for s in 16 32 128 256 512; do
    sips -z $s $s icon1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) icon1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done && iconutil -c icns AppIcon.iconset -o AppIcon.icns)

echo "打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/LightBar" "$APP/Contents/MacOS/LightBar"
cp "$TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.mijia-lightbar</string>
<key>CFBundleName</key><string>挂灯</string>
<key>CFBundleDisplayName</key><string>挂灯</string>
<key>CFBundleExecutable</key><string>LightBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "完成：$APP"
