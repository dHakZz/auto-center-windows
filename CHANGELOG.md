# Changelog

## 1.4.1

- Included focused and main child dialogs in **Add Window…**, including Xcode's Downloads panel.
- Remembered recently focused child dialogs briefly so they remain selectable after opening Manage Apps.
- Centered enabled specific-window rules immediately after saving Manage Apps.
- Watched focused child-window changes so reopened dialogs can be centered even when an app reuses them.
- Split the Manage Apps explanation across two readable lines.
- Replaced the nested-window disclosure controls with clean borderless chevrons.

## 1.4.0

- Added **Add Window…** for creating an override for a specific open window.
- Nested added windows beneath their parent apps with disclosure arrows.
- Added independent switches and remove buttons for per-window rules.
- Allowed explicitly added child sheets and dialogs to be centered.
- Preserved existing app preferences through an automatic state-file migration.
- Centered the **Manage Apps** and **About Auto Center Windows** windows on the display where the menu was opened.

## 1.3.13

- Replaced the shell launcher with a small universal native macOS executable.
- Prevented Terminal from appearing as an Accessibility permission entry.
- Preserved the friendly **Auto Center Windows** background-item name and custom icon.

## 1.3.12

- Restored the reliable LaunchAgent startup method used by earlier working releases.
- Avoided Service Management registration that was rejected by the personal build.

## 1.3.9

- Registered the installed app with Launch Services before requesting Accessibility.
- Refreshed the macOS icon service to prevent reuse of the generic blueprint icon.
- Explicitly assigned the packaged icon to the running helper.

## 1.3.8

- Added a Retina macOS app icon using the centered-window symbol.
- Added the proper icon beside the app's Accessibility entry in System Settings.

## 1.3.7

- Replaced the oversized system alert with a compact Manage Apps window.
- Matched the About window's size, symbol, typography, spacing, and footer.
- Added a two-line app list with rounded Cancel and Save buttons.
- Changed the About and Manage Apps symbols to neutral gray.

## 1.3.6

- Replaced the learned-app link with an About This Mac-style **Manage Apps…** button.
- Simplified the About footer.

## 1.3.5

- Corrected Retina scaling in the About window.

## 1.3.4

- Renamed the menu entry to **About Auto Center Windows**.
- Redesigned the About window to closely match Apple's About This Mac layout.
- Added a learned-app count and direct link to Manage Apps.
- Removed the technical Mode row.

## 1.3.3

- Brought installer, uninstaller, confirmation, completion, and error dialogs in front of Terminal.

## 1.3.2

- Added the `inset.filled.center.rectangle` menu-bar symbol.
- Used the same symbol in the Manage Apps window.

## 1.3.1

- Fixed stale Accessibility permission identities after upgrading.
- Repaired the startup job so it contains only the helper executable path.

## 1.3.0

- Limited the Accessibility request to the first launch instead of every restart.
- Replaced the long menu-bar app list with **Manage Apps…**.
- Added a clickable About window.
- Centered known enabled apps restored before the helper starts.
