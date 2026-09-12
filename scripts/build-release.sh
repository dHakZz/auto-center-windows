#!/bin/zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPO_DIR="${SCRIPT_DIR:h}"
readonly VERSION="${1:-1.5.0}"
readonly BUILD_NUMBER="${2:-1}"
readonly SOURCE="$REPO_DIR/payload/source/AutoCenterWindows.swift"
readonly LAUNCHER_SOURCE="$REPO_DIR/payload/source/AutoCenterWindowsLauncher.c"
readonly INFO_TEMPLATE="$REPO_DIR/payload/AutoCenterWindows-Info.plist"
readonly ICON_SOURCE="$REPO_DIR/assets/AutoCenterWindows.icns"
readonly OUTPUT_DIR="$REPO_DIR/build"
readonly RELEASE_ARCHIVE="$OUTPUT_DIR/Auto-Center-Windows-v$VERSION.zip"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || ! "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  /usr/bin/printf 'Usage: %s [version] [numeric-build-number]\n' "$0" >&2
  exit 2
fi

for required in "$SOURCE" "$LAUNCHER_SOURCE" "$INFO_TEMPLATE" "$ICON_SOURCE"; do
  if [[ ! -f "$required" || -L "$required" ]]; then
    /usr/bin/printf 'Missing or unsafe build input: %s\n' "$required" >&2
    exit 1
  fi
done

temp_root="$(/usr/bin/mktemp -d "${TMPDIR%/}/auto-center-build.XXXXXX")"
if [[ -z "$temp_root" || "$temp_root" != "${TMPDIR%/}/auto-center-build."* || ! -d "$temp_root" ]]; then
  /usr/bin/printf 'Could not create a safe temporary build folder.\n' >&2
  exit 1
fi
trap '/bin/rm -rf -- "$temp_root"' EXIT

app_path="$temp_root/Auto Center Windows.app"
/bin/mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/ditto "$INFO_TEMPLATE" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app_path/Contents/Info.plist"
/usr/bin/ditto "$ICON_SOURCE" "$app_path/Contents/Resources/AutoCenterWindows.icns"

for architecture in arm64 x86_64; do
  module_cache="$temp_root/module-cache-$architecture"
  /bin/mkdir -p "$module_cache"
  CLANG_MODULE_CACHE_PATH="$module_cache" SWIFT_MODULECACHE_PATH="$module_cache" \
    /usr/bin/xcrun --sdk macosx swiftc \
      -module-cache-path "$module_cache" \
      -target "$architecture-apple-macos13.0" \
      -O -warnings-as-errors \
      -framework AppKit \
      -framework ApplicationServices \
      -framework Carbon \
      -o "$temp_root/AutoCenterWindows-$architecture" \
      "$SOURCE"

  /usr/bin/xcrun --sdk macosx clang \
    -target "$architecture-apple-macos13.0" \
    -Os \
    -o "$temp_root/AutoCenterWindowsLauncher-$architecture" \
    "$LAUNCHER_SOURCE"
done

/usr/bin/lipo -create \
  "$temp_root/AutoCenterWindows-arm64" \
  "$temp_root/AutoCenterWindows-x86_64" \
  -output "$app_path/Contents/MacOS/AutoCenterWindows"
/bin/chmod 755 "$app_path/Contents/MacOS/AutoCenterWindows"

/usr/bin/lipo -create \
  "$temp_root/AutoCenterWindowsLauncher-arm64" \
  "$temp_root/AutoCenterWindowsLauncher-x86_64" \
  -output "$temp_root/AutoCenterWindowsLauncher"
/bin/chmod 755 "$temp_root/AutoCenterWindowsLauncher"

/usr/bin/codesign --force --sign - --identifier com.justin.auto-center-windows "$app_path/Contents/MacOS/AutoCenterWindows"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --force --sign - --identifier com.justin.auto-center-windows.launcher "$temp_root/AutoCenterWindowsLauncher"
/usr/bin/codesign --verify --deep --strict "$app_path"
"$app_path/Contents/MacOS/AutoCenterWindows" --self-test

app_archive="$temp_root/AutoCenterWindows.app.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$app_archive"
/usr/bin/unzip -t "$app_archive" >/dev/null

release_folder="$temp_root/release/Auto Center Windows"
/bin/mkdir -p "$release_folder/payload/native"
for item in \
  "Install Auto Center Windows.command" \
  "Configure Auto Center Windows.command" \
  "Uninstall Auto Center Windows.command" \
  "README.txt" \
  "RELEASE_NOTES.md" \
  "LICENSE"; do
  /usr/bin/ditto "$REPO_DIR/$item" "$release_folder/$item"
done
/usr/bin/ditto "$REPO_DIR/payload/source" "$release_folder/payload/source"
/usr/bin/ditto "$REPO_DIR/payload/ui.js" "$release_folder/payload/ui.js"
/usr/bin/ditto "$REPO_DIR/payload/com.justin.auto-center-windows.plist" "$release_folder/payload/com.justin.auto-center-windows.plist"
/usr/bin/ditto "$app_archive" "$release_folder/payload/native/AutoCenterWindows.app.zip"
/usr/bin/ditto "$temp_root/AutoCenterWindowsLauncher" "$release_folder/payload/native/AutoCenterWindowsLauncher"

/bin/mkdir -p "$OUTPUT_DIR"
if [[ -e "$RELEASE_ARCHIVE" && ! -f "$RELEASE_ARCHIVE" ]]; then
  /usr/bin/printf 'Refusing to replace a non-file output path: %s\n' "$RELEASE_ARCHIVE" >&2
  exit 1
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$release_folder" "$temp_root/release.zip"
/usr/bin/unzip -t "$temp_root/release.zip" >/dev/null
/usr/bin/ditto "$temp_root/release.zip" "$RELEASE_ARCHIVE"

/usr/bin/printf 'Built %s\n' "$RELEASE_ARCHIVE"
/usr/bin/shasum -a 256 "$RELEASE_ARCHIVE"
