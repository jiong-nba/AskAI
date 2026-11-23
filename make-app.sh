#!/bin/bash
# 把 AskAI 打包成独立的 AskAI.app
# 产物可以直接双击 / open 启动。授权持久性取决于签名方式，见下方说明与 README。
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="AskAI.app"
APP_VERSION="1.1.1"
STAGE_DIR=$(mktemp -d "./.AskAI-build.XXXXXX")
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGED_APP="${STAGE_DIR}/${APP}"
echo "==> 组装 ${APP}"
mkdir -p "${STAGED_APP}/Contents/MacOS"
cp .build/release/AskAI "${STAGED_APP}/Contents/MacOS/AskAI"

cat > "${STAGED_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>AskAI</string>
    <key>CFBundleDisplayName</key>        <string>AskAI</string>
    <key>CFBundleIdentifier</key>         <string>com.dsh.AskAI</string>
    <key>CFBundleExecutable</key>         <string>AskAI</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>            <string>${APP_VERSION}</string>
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
SIGN_ID="${ASKAI_SIGN_ID:--}"
if [[ "${SIGN_ID}" == "-" ]]; then
    echo "==> ad-hoc 签名（注意：下次重建后需重新授权辅助功能，详见 README）"
else
    echo "==> 稳定签名：${SIGN_ID}"
fi
codesign --force --sign "${SIGN_ID}" "${STAGED_APP}"

echo "==> 验证签名"
codesign --verify --strict "${STAGED_APP}"
codesign -dv "${STAGED_APP}" 2>&1 | grep -E "Identifier=|Authority=|Signature=" || true

# 同一文件系统内交换目录。旧 bundle 在交换成功后才由 EXIT trap 清理。
swift - "${STAGED_APP}" "${APP}" <<'SWIFT'
import Darwin

let staged = CommandLine.arguments[1], destination = CommandLine.arguments[2]
if renamex_np(staged, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(staged, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("install AskAI.app")
        exit(EXIT_FAILURE)
    }
}
SWIFT

echo "完成：${PWD}/${APP}"
echo "后续：defaults write com.dsh.AskAI apiKey sk-你的密钥 && open AskAI.app"
