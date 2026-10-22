#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Run build.sh and build-grammars.py first. This probe uses the actual signed XPC worker.
configuration=${TCODE_CONFIGURATION:-release}
bin_path=${TCODE_BIN_PATH:-$(swift build -c "$configuration" --arch arm64 --show-bin-path)}
probe_app="$PWD/dist/tCodeSyntaxProbe.app"
service_path="$probe_app/Contents/XPCServices/dev.tufariello.tCode.SyntaxService.xpc"
mkdir -p "$probe_app/Contents/MacOS" "$service_path/Contents/MacOS" artifacts/syntax
cp "$bin_path/TCodeSyntaxProbe" "$probe_app/Contents/MacOS/TCodeSyntaxProbe"
if [[ "$configuration" == release ]]; then
  # Exercise the exact signed helper shipped in the finished application.
  packaged_service="$PWD/dist/tCode.app/Contents/XPCServices/dev.tufariello.tCode.SyntaxService.xpc"
  test -d "$packaged_service" || { print -u2 'Build the release app first.'; exit 1; }
  ditto "$packaged_service" "$service_path"
else
  cp "$bin_path/TCodeSyntaxService" "$service_path/Contents/MacOS/TCodeSyntaxService"
  cp packaging/SyntaxService-Info.plist "$service_path/Contents/Info.plist"
  codesign --force --options runtime --sign - --entitlements packaging/SyntaxService.entitlements "$service_path"
fi
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.tufariello.tCode.SyntaxProbe</string><key>CFBundleExecutable</key><string>TCodeSyntaxProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>27.0</string></dict></plist>
PLIST
codesign --force --sign - "$probe_app"
codesign --verify --deep --strict "$probe_app"
for language in python c cpp swift rust; do
  extra=()
  [[ "$language" == python ]] && extra=(--crash-check)
  "$probe_app/Contents/MacOS/TCodeSyntaxProbe" "$PWD/dist/grammar-artifacts/$language" "$PWD/Package.swift" "$PWD/artifacts/syntax/$language.json" "${extra[@]}"
done
print 'All packaged grammar, incremental, sandbox and crash-isolation probes passed.'
