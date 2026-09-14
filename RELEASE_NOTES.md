# Auto Center Windows 1.5.1

Auto Center Windows is a lightweight macOS menu-bar utility that automatically centers the first normal window when an app opens and newly created windows afterward.

## Highlights

- Fixes **Bootstrap failed: 5** when installing a downloaded release.
- Prevents macOS download quarantine metadata from reaching the installed launcher and LaunchAgent.
- Recovers cleanly after a partial or failed 1.5.0 installation.
- Automatically learns apps and enables centering by default.
- Pauses automatic centering for 15 minutes, 1 hour, or until manually resumed.
- Remembers a pause across restarts and automatically ends timed pauses.
- Dims the menu-bar icon and shows **Paused** in About while paused.
- Centers the front window on demand with **Control–Option–C**.
- Exports and imports app and window choices from the new **Settings** submenu.
- Includes a compact **Manage Apps…** window for per-app control.
- Adds optional per-window overrides beneath their parent apps.
- Finds focused child dialogs such as Xcode's Downloads panel in **Add Window…**.
- Supports explicitly added child sheets and dialogs, including reused dialogs.
- Uses clean chevrons for nested added windows.
- Keeps the Manage Apps explanation fully readable on two lines.
- Centers the utility's own **Manage Apps** and **About** windows.
- Keeps each window on the display where it appeared.
- Starts automatically at login using a native launcher.
- Avoids adding Terminal to Accessibility settings.
- Runs entirely locally with no networking, analytics, or data collection.
- Supports Apple silicon and Intel Macs running macOS 13 or later.
- Includes an MIT license and a reproducible GitHub build workflow.

## Installation

1. Download `Auto-Center-Windows-v1.5.1.zip` and unzip it.
2. Double-click **Install Auto Center Windows.command**.
3. Enable **Auto Center Windows** when macOS opens Accessibility settings.

Because this is a personal, non-notarized build, macOS may block the first opening attempt. If it does, open **System Settings → Privacy & Security**, scroll to **Security**, choose **Open Anyway**, and confirm with your Mac password.

## Integrity

The SHA-256 checksum for the downloadable ZIP is published with the release.
