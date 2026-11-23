#!/bin/bash
# 把 AskAI 打包成独立的 AskAI.app
# 产物可以直接双击 / open 启动。授权持久性取决于签名方式，见下方说明与 README。
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="AskAI.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AskAI "$APP/Contents/MacOS/AskAI"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>AskAI</string>
    <key>CFBundleDisplayName</key>        <string>AskAI</string>
    <key>CFBundleIdentifier</key>         <string>com.dsh.AskAI</string>
    <key>CFBundleExecutable</key>         <string>AskAI</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
EOF

# 签名策略（决定「辅助功能」授权能否跨重建保留）：
#   默认 ad-hoc：零配置，但每次重建签名（cdhash）都会变，macOS 视为新 App，
#               授权失效，需要到系统设置里重新勾选一次；
#   稳定签名：先在「钥匙串访问」创建自签署代码签名证书（步骤见 README），
#            然后 ASKAI_SIGN_ID="证书名" ./make-app.sh，重建不再丢授权。
SIGN_ID="${ASKAI_SIGN_ID:-}"
if [ -n "$SIGN_ID" ]; then
    # 先确认证书真实存在：拼错证书名时 codesign 仍会返回 0 但产物不可信，
    # 这里提前检查并回退，避免"看起来打包成功实际没签上"。
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
        echo "==> 稳定签名：${SIGN_ID}（首次会弹钥匙串访问确认，选『始终允许』）"
        codesign --force -s "${SIGN_ID}" "$APP"
    else
        echo "!! 找不到代码签名证书『${SIGN_ID}』，可用的证书有：" >&2
        security find-identity -v -p codesigning 2>/dev/null >&2 || echo "!!   （无）" >&2
        echo "!! 回退为 ad-hoc 签名：重建后需重新授权辅助功能" >&2
        codesign --force -s - "$APP"
    fi
else
    echo "==> ad-hoc 签名（注意：下次重建后需重新授权辅助功能，详见 README）"
    codesign --force -s - "$APP"
fi

echo "==> 验证签名"
codesign --verify --strict "$APP"          # 校验失败会直接中断脚本
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Authority=|Signature=" || true

echo "完成：$PWD/$APP"
echo "后续：defaults write com.dsh.AskAI apiKey sk-你的密钥 && open AskAI.app"
