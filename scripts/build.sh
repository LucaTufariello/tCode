#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test "$(uname -m)" = arm64 || { print -u2 'An Apple Silicon host is required.'; exit 1; }
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
[[ "$sdk_version" == 27.* ]] || { print -u2 "macOS 27 SDK required; found $sdk_version"; exit 1; }
swift build -c release --arch arm64
bin_path=$(swift build -c release --arch arm64 --show-bin-path)
app_path="$PWD/dist/tCode.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/tCode" "$app_path/Contents/MacOS/tCode"
for resource in "$bin_path"/*.bundle; do cp -R "$resource" "$app_path/Contents/Resources/"; done
cp packaging/Info.plist "$app_path/Contents/Info.plist"
if [[ -f packaging/tCode.icns ]]; then cp packaging/tCode.icns "$app_path/Contents/Resources/"; fi
cp docs/THIRD-PARTY.md "$app_path/Contents/Resources/"
cp -R docs/licenses "$app_path/Contents/Resources/"
codesign --force --deep --sign - "$app_path"
file "$app_path/Contents/MacOS/tCode"
codesign --verify --deep --strict "$app_path"
print "Built $app_path"
