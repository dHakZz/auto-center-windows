#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly UI_SCRIPT="$SCRIPT_DIR/payload/ui.js"
readonly INSTALL_DIR="$HOME/Library/Application Support/Auto Center Windows"
readonly LAUNCHER_PATH="$INSTALL_DIR/Auto Center Windows"
readonly STATE_PATH="$INSTALL_DIR/apps.plist"
readonly PERMISSION_PROMPT_MARKER="$INSTALL_DIR/accessibility-prompted"
readonly LEGACY_CONFIG_PATH="$INSTALL_DIR/apps.conf"
readonly APP_BUNDLE="$HOME/Applications/Auto Center Windows.app"
readonly LEGACY_APP="$INSTALL_DIR/Auto Center Windows.app"
readonly LEGACY_SETTINGS_APP="$HOME/Applications/Auto Center Apps.app"
readonly AGENT_PATH="$HOME/Library/LaunchAgents/com.justin.auto-center-windows.plist"
readonly OUT_LOG="$HOME/Library/Logs/Auto Center Windows.log"
readonly ERROR_LOG="$HOME/Library/Logs/Auto Center Windows.error.log"
readonly INSTALL_LOG="$HOME/Library/Logs/Auto Center Windows Installer.log"
readonly LABEL="com.justin.auto-center-windows"
readonly LEGACY_SETTINGS_LABEL="com.justin.auto-center-windows.settings"
readonly GUI_DOMAIN="gui/$(/usr/bin/id -u)"

if [[ ! -f "$UI_SCRIPT" ]]; then
  /usr/bin/printf 'Keep the payload folder beside this uninstaller and try again.\n' >&2
  exit 1
fi
if [[ -L "$INSTALL_DIR" || -L "$LAUNCHER_PATH" || -L "$STATE_PATH" || -L "$PERMISSION_PROMPT_MARKER" || -L "$APP_BUNDLE" || -L "$LEGACY_APP" || -L "$LEGACY_SETTINGS_APP" || -L "$AGENT_PATH" ]]; then
  /usr/bin/osascript -l JavaScript "$UI_SCRIPT" error "Uninstall stopped" "An expected installation path is a symbolic link. Remove the Auto Center Windows files manually."
  exit 1
fi

confirmation="$(/usr/bin/osascript -l JavaScript "$UI_SCRIPT" confirm "Uninstall Auto Center Windows" "Remove Auto Center Windows and its learned-app list from this Mac?" "Uninstall")"
if [[ "$confirmation" == "__AUTO_CENTER_CANCELLED__" ]]; then exit 0; fi

/bin/launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "$GUI_DOMAIN" "$AGENT_PATH" >/dev/null 2>&1 || true

if [[ -e "$APP_BUNDLE" ]]; then
  installed_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_id" == "$LABEL" ]]; then
    [[ "$APP_BUNDLE" == "$HOME/Applications/Auto Center Windows.app" ]] || exit 1
    /bin/rm -rf -- "$APP_BUNDLE"
  fi
fi
if [[ -e "$LEGACY_APP" ]]; then
  [[ "$LEGACY_APP" == "$INSTALL_DIR/Auto Center Windows.app" ]] || exit 1
  /bin/rm -rf -- "$LEGACY_APP"
fi
if [[ -e "$LEGACY_SETTINGS_APP" ]]; then
  legacy_settings_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$LEGACY_SETTINGS_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$legacy_settings_id" == "$LEGACY_SETTINGS_LABEL" ]]; then
    /bin/rm -rf -- "$LEGACY_SETTINGS_APP"
  fi
fi

/bin/rm -f -- "$LAUNCHER_PATH" "$STATE_PATH" "$PERMISSION_PROMPT_MARKER" "$LEGACY_CONFIG_PATH" "$AGENT_PATH" "$OUT_LOG" "$ERROR_LOG" "$INSTALL_LOG"
/bin/rmdir "$INSTALL_DIR" 2>/dev/null || true
/usr/bin/tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
/usr/bin/tccutil reset AppleEvents "$LABEL" >/dev/null 2>&1 || true

/usr/bin/osascript -l JavaScript "$UI_SCRIPT" info "Uninstall complete" "Auto Center Windows was removed. It will no longer run at login or move app windows."
