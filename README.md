<p align="center">
  <img src="assets/AutoCenterWindows.png" width="128" height="128" alt="Auto Center Windows icon">
</p>

<h1 align="center">Auto Center Windows</h1>

<p align="center">
  A free, lightweight macOS menu-bar utility that automatically centers app windows.
</p>

## What it does

Auto Center Windows centers the first normal window when an app opens and centers new windows created afterward. Apps are learned automatically and enabled by default, while **Manage Apps…** gives you a simple on/off switch for each one.

- Centers windows on the display where they appeared
- Avoids the menu bar and Dock
- Ignores minimized, full-screen, and nonstandard utility windows
- Remembers which apps should or should not be centered
- Adds optional per-window overrides beneath their parent apps
- Supports explicitly added child sheets and dialogs
- Starts automatically when you log in
- Uses only built-in macOS frameworks—no Hammerspoon or other dependencies
- Runs entirely on your Mac with no networking, analytics, or data collection

## Download

[**Download the latest release**](../../releases/latest)

The downloadable ZIP contains the installer, app manager, uninstaller, and a detailed text guide.

## Install

1. Download and unzip the latest release.
2. Double-click **Install Auto Center Windows.command**.
3. Wait for the **Installation complete** message.
4. When macOS asks, enable **Auto Center Windows** in Accessibility settings.
5. Open an app or create a new window to test it.

If macOS blocks the installer, Control-click it, choose **Open**, then click **Open** again. This is a personal build and is not notarized through Apple's paid developer program.

## Manage apps

Click the centered-window icon in the menu bar and choose **Manage Apps…**. Checked apps are centered; unchecked apps keep their own window placement.

Choose **Add Window…** to select a window that is currently open. Added windows appear beneath their parent app behind a disclosure arrow. Their individual switches override the app switch, and the minus button removes an override. This also lets you opt in child sheets and dialogs that the app normally ignores.

The list starts empty and fills automatically as you open apps or create windows.

## Why Accessibility permission is required

macOS requires Accessibility permission before one app can reposition another app's windows. Auto Center Windows uses that access only to identify and move eligible windows. It does not record keystrokes, inspect documents, or send information anywhere.

The only saved information is:

- App names
- Bundle identifiers
- Your on/off choice for each app
- Names and accessibility identifiers for windows you explicitly add

## Compatibility

- macOS 13 Ventura or later
- Apple silicon and Intel Macs
- Version 1.4.0

Some apps deliberately prevent accessibility tools from moving their windows, so an occasional app may not center.

## Uninstall

Double-click **Uninstall Auto Center Windows.command** and confirm. No administrator password is needed. The uninstaller removes the app, startup item, learned-app list, logs, and Accessibility permission entry.

## Report a problem or share compatibility

Open the [GitHub issue page](https://github.com/dHakZz/auto-center-windows/issues/new/choose) and choose the form that fits:

- **Report a Bug** for something that is not working as expected
- **Compatibility / Device Report** to share your Mac model, macOS version, utility version, and tested apps—even when everything works perfectly

Before attaching a screenshot or log, remove serial numbers, names, file paths, and other personal information.

## Troubleshooting

- The window-shaped menu-bar icon confirms the utility is running.
- Open its menu to check whether Accessibility is **Enabled** or **Needed**.
- If an app is listed but unchecked, enable it and create a new window.
- Installation details are stored locally at `~/Library/Logs/Auto Center Windows Installer.log`.
- An update may require Accessibility to be enabled again because macOS can treat personal builds as a new app identity.

## Privacy

Auto Center Windows has no network code, analytics, advertising, accounts, or cloud service. Everything runs locally.

## Source

The Swift source for the menu-bar utility and the C source for its native launcher are included under [`payload/source`](payload/source). The packaged release binaries are included so the one-click installer works without developer tools.

## Copyright

Copyright © 2026 Justin Chacon. All rights reserved.
