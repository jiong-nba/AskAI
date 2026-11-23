#!/bin/bash
# Exercise the packager against a tiny Swift package without touching an installed AskAI.app.
set -euo pipefail
packager="$(cd "$(dirname "$0")/.." && pwd)/make-app.sh"
fixture=$(mktemp -d)
trap 'rm -rf "${fixture}"' EXIT
cd "${fixture}"
cp "${packager}" .
mkdir -p Sources/AskAI
cat > Package.swift <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "AskAI", targets: [.executableTarget(name: "AskAI")])
SWIFT
echo 'print("first")' > Sources/AskAI/main.swift

unset ASKAI_SIGN_ID
./make-app.sh
bundle_id=$(stat -f '%i' AskAI.app)
binary="AskAI.app/Contents/MacOS/AskAI"
[[ "$("${binary}")" == first ]]

# Change the input so that replacing the old bundle is observable.
echo 'print("second")' > Sources/AskAI/main.swift
if ASKAI_SIGN_ID="missing-signing-identity-$(uuidgen)" ./make-app.sh; then
    echo "Expected signing to fail" >&2
    exit 1
fi
[[ "$(stat -f '%i' AskAI.app)" == "${bundle_id}" && "$("${binary}")" == first ]]
codesign --verify --strict AskAI.app

# Inject a verification failure after a real signature has been applied.
mkdir bin
cat > bin/codesign <<'SH'
#!/bin/bash
if [[ "$1" == --verify ]]; then exit 42; fi
exec /usr/bin/codesign "$@"
SH
chmod +x bin/codesign
if PATH="${PWD}/bin:${PATH}" ./make-app.sh; then
    echo "Expected verification to fail" >&2
    exit 1
fi
[[ "$(stat -f '%i' AskAI.app)" == "${bundle_id}" && "$("${binary}")" == first ]]
codesign --verify --strict AskAI.app

./make-app.sh
[[ "$("${binary}")" == second ]]
codesign --verify --strict AskAI.app
echo "Signing failure, verification failure and bundle replacement passed."
