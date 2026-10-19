#!/bin/bash
set -euo pipefail
app_path="${1:?Usage: sign-app.sh app-path}"
identity="${HERHIS_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -f "$HOME/.config/herhis/signing-identity" ]]; then
    identity="$(tr -d '[:space:]' < "$HOME/.config/herhis/signing-identity")"
fi
if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo 'Configure a persistent code-signing certificate SHA-1 in HERHIS_SIGNING_IDENTITY or ~/.config/herhis/signing-identity. Refusing ad-hoc signing because it breaks update authorization.' >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fqi "$identity"; then
    echo 'The configured signing identity is unavailable. Keep the same certificate for updates; do not silently generate another identity.' >&2
    exit 1
fi
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Contents/Info.plist")"
[[ "$bundle_id" == 'com.huian.herhis' ]] || { echo 'Unexpected app identifier' >&2; exit 1; }
# Pin both certificate and bundle ID. An identifier-only requirement would allow impersonation.
requirement="designated => identifier \"com.huian.herhis\" and certificate leaf = H\"$identity\""
codesign --force --sign "$identity" --requirements "=$requirement" "$app_path"
codesign --verify --deep --strict "$app_path"
