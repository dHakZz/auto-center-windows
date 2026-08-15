#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly UI_SCRIPT="$SCRIPT_DIR/payload/ui.js"
readonly APP_BUNDLE="$HOME/Applications/Auto Center Windows.app"
readonly LABEL="com.justin.auto-center-windows"

if [[ ! -f "$UI_SCRIPT" ]]; then
  /usr/bin/printf 'Keep the payload folder beside this configuration tool and try again.\n' >&2
  exit 1
fi
if [[ ! -d "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  /usr/bin/osascript -l JavaScript "$UI_SCRIPT" error "Auto Center Windows is not installed" "Run Install Auto Center Windows.command first."
  exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)" != "$LABEL" ]]; then
  /usr/bin/osascript -l JavaScript "$UI_SCRIPT" error "Installed app is invalid" "Run Install Auto Center Windows.command again to repair it."
  exit 1
fi

/usr/bin/open -g "$APP_BUNDLE"
/bin/sleep 1
/usr/bin/osascript -l JavaScript "$UI_SCRIPT" notify-settings
