#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PAYLOAD_DIR="$SCRIPT_DIR/payload"
readonly APP_ARCHIVE="$PAYLOAD_DIR/native/AutoCenterWindows.app.zip"
readonly LAUNCHER_SOURCE="$PAYLOAD_DIR/native/AutoCenterWindowsLauncher"
readonly UI_SCRIPT="$PAYLOAD_DIR/ui.js"
readonly INSTALL_DIR="$HOME/Library/Application Support/Auto Center Windows"
readonly LAUNCHER_PATH="$INSTALL_DIR/Auto Center Windows"
readonly STATE_PATH="$INSTALL_DIR/apps.plist"
readonly PERMISSION_PROMPT_MARKER="$INSTALL_DIR/accessibility-prompted"
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
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

show_message() {
  /usr/bin/osascript -l JavaScript "$UI_SCRIPT" "$1" "$2" "$3"
}

installation_failed() {
  local exit_status=$?
  local failed_line="$1"
  trap - ERR
  /usr/bin/printf '%s Installation failed at line %s with status %s.\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$failed_line" "$exit_status" >> "$INSTALL_LOG" 2>/dev/null || true
  show_message error "Installation failed" "Auto Center Windows was not installed successfully. The failure occurred at installer line $failed_line. Details are in ~/Library/Logs/Auto Center Windows Installer.log." >/dev/null 2>&1 || true
  exit "$exit_status"
}

if [[ ! -f "$APP_ARCHIVE" || ! -f "$LAUNCHER_SOURCE" || ! -f "$PAYLOAD_DIR/com.justin.auto-center-windows.plist" || ! -f "$UI_SCRIPT" ]]; then
  /usr/bin/printf 'Installer is incomplete. Keep the payload folder beside the installer and try again.\n' >&2
  exit 1
fi

/bin/mkdir -p "$HOME/Library/Logs"
/usr/bin/printf '%s Starting Auto Center Windows 1.4.1 installation.\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >> "$INSTALL_LOG"
trap 'installation_failed $LINENO' ERR

if [[ -L "$INSTALL_DIR" || -L "$LAUNCHER_PATH" || -L "$STATE_PATH" || -L "$PERMISSION_PROMPT_MARKER" || -L "$APP_BUNDLE" || -L "$LEGACY_APP" || -L "$LEGACY_SETTINGS_APP" || -L "$AGENT_PATH" ]]; then
  show_message error "Installation stopped" "An expected installation path is a symbolic link. Remove the existing Auto Center Windows files manually before installing."
  exit 1
fi

if [[ -e "$APP_BUNDLE" ]]; then
  existing_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_id" != "$LABEL" ]]; then
    show_message error "Installation stopped" "An unrelated app already exists at ~/Applications/Auto Center Windows.app. Move or rename that app, then run the installer again."
    exit 1
  fi
fi

/bin/launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "$GUI_DOMAIN" "$AGENT_PATH" >/dev/null 2>&1 || true
/bin/mkdir -p "$INSTALL_DIR" "$HOME/Applications"
/bin/rm -f -- "$AGENT_PATH"

if [[ -e "$APP_BUNDLE" ]]; then
  [[ "$APP_BUNDLE" == "$HOME/Applications/Auto Center Windows.app" ]] || exit 1
  /bin/rm -rf -- "$APP_BUNDLE"
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

temp_dir="$(/usr/bin/mktemp -d "${TMPDIR%/}/auto-center-install.XXXXXX")"
/usr/bin/ditto -x -k "$APP_ARCHIVE" "$temp_dir"
temp_app="$temp_dir/Auto Center Windows.app"
[[ -d "$temp_app" && ! -L "$temp_app" ]]
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$temp_app/Contents/Info.plist")" == "$LABEL" ]]
/usr/bin/codesign --verify --deep --strict "$temp_app"
/usr/bin/ditto "$temp_app" "$APP_BUNDLE"
/usr/bin/xattr -dr com.apple.quarantine "$APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" >/dev/null 2>&1 || true
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
"$APP_BUNDLE/Contents/MacOS/AutoCenterWindows" --self-test >> "$INSTALL_LOG" 2>&1

# macOS shows a personal background item using the executable's filename and
# file icon. This native launcher preserves the friendly app name and custom
# icon without routing startup or Accessibility responsibility through a shell.
/usr/bin/ditto "$LAUNCHER_SOURCE" "$LAUNCHER_PATH"
/bin/chmod 755 "$LAUNCHER_PATH"
/usr/bin/codesign --verify --strict "$LAUNCHER_PATH"
"$APP_BUNDLE/Contents/MacOS/AutoCenterWindows" --set-file-icon "$APP_BUNDLE/Contents/Resources/AutoCenterWindows.icns" "$LAUNCHER_PATH"
[[ -x "$LAUNCHER_PATH" && ! -L "$LAUNCHER_PATH" ]]

# Register the newly copied bundle before macOS creates its Accessibility entry.
# This refreshes Finder/System Settings metadata instead of reusing the old
# generic application icon cached for this path and bundle identifier.
/usr/bin/touch "$APP_BUNDLE"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >> "$INSTALL_LOG" 2>&1 || true
fi
/usr/bin/killall -u "$(/usr/bin/id -un)" iconservicesagent >> "$INSTALL_LOG" 2>&1 || true

# Ad-hoc signed personal builds receive a new macOS code identity when updated.
# Clear any grant tied to the previous build so System Settings cannot show an
# enabled-but-stale Accessibility switch for the newly installed helper.
/usr/bin/tccutil reset Accessibility "$LABEL" >> "$INSTALL_LOG" 2>&1
/bin/rm -f -- "$PERMISSION_PROMPT_MARKER"

if [[ ! -e "$STATE_PATH" ]]; then
  /usr/bin/plutil -create xml1 "$STATE_PATH"
fi
/usr/bin/plutil -lint "$STATE_PATH" >/dev/null
/bin/chmod 600 "$STATE_PATH"

/usr/bin/ditto "$PAYLOAD_DIR/com.justin.auto-center-windows.plist" "$AGENT_PATH"
/usr/bin/plutil -remove ProgramArguments "$AGENT_PATH"
/usr/bin/plutil -insert ProgramArguments -array "$AGENT_PATH"
/usr/bin/plutil -insert ProgramArguments.0 -string "$LAUNCHER_PATH" "$AGENT_PATH"
/usr/bin/plutil -replace StandardOutPath -string "$OUT_LOG" "$AGENT_PATH"
/usr/bin/plutil -replace StandardErrorPath -string "$ERROR_LOG" "$AGENT_PATH"
/usr/bin/plutil -lint "$AGENT_PATH" >/dev/null
[[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw "$AGENT_PATH")" == "$LAUNCHER_PATH" ]]
/bin/chmod 600 "$AGENT_PATH"

/bin/launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PATH"
/bin/launchctl kickstart -k "$GUI_DOMAIN/$LABEL"
/bin/sleep 2
/bin/launchctl print "$GUI_DOMAIN/$LABEL" | /usr/bin/grep -q 'state = running'

/usr/bin/printf '%s Installation completed with named background launcher verified running.\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" >> "$INSTALL_LOG"
trap - ERR
show_message info "Installation complete" "Auto Center Windows 1.4.1 is installed and verified running. Add Window… can now include focused child dialogs such as Xcode's Downloads panel. Approve the one-time Accessibility request."
