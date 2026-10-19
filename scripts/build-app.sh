#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bash scripts/build-icon.sh
binary_dir="$(swift build -c release --show-bin-path)"
app_path="$PWD/build/HerHis.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/HerHis" "$app_path/Contents/MacOS/HerHis"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp build/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
resource_bundle="$binary_dir/HerHis_CompanionApp.bundle"
test -d "$resource_bundle"
ditto "$resource_bundle" "$app_path/Contents/Resources/HerHis_CompanionApp.bundle"
bash scripts/sign-app.sh "$app_path"
printf '%s\n' "$app_path"
