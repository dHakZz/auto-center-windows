AUTO CENTER WINDOWS 1.3.13 FOR MAC

What changed in 1.3.13
----------------------
• Replaces the shell-script launcher with a small native macOS executable.
• Prevents the startup chain from adding Terminal to Accessibility settings.
• Keeps the friendly “Auto Center Windows” background-item name and custom icon.

Also included from 1.3.12
------------------------
• Restores the reliable LaunchAgent startup method used by the working releases.
• Avoids the ServiceManagement registration rejected by this personal build.

Also included from 1.3.9
------------------------
• Registers the installed app with Launch Services before requesting Accessibility.
• Refreshes the user icon service so Finder and System Settings stop reusing the
  cached generic blueprint icon.
• Explicitly assigns the packaged icon to the running helper.

Also included from 1.3.8
------------------------
• Adds a real Retina macOS app icon using the centered-window symbol.
• System Settings can now display the proper icon beside the Accessibility entry.

Also included from 1.3.7
------------------------
• Replaces the oversized system alert with a custom Manage Apps window.
• Matches the About window’s size, symbol, typography, spacing, and footer.
• Uses a compact two-line app list with rounded Cancel and Save buttons.
• Uses a neutral gray symbol in both About and Manage Apps.

Also included from 1.3.6
------------------------
• Replaces the learned-app link with an About This Mac-style “Manage Apps…” button.
• Simplifies the About footer to one copyright line.

Also included from 1.3.5
------------------------
• Corrects the About window’s Retina scaling: the window, symbol, text, details,
  link, and footer are now approximately half the previous dimensions.

Also included from 1.3.4
------------------------
• Renames the menu entry to “About Auto Center Windows”.
• Redesigns the About window to closely match Apple’s About This Mac layout.
• Adds a “Click to view” link beside the learned-app count.
• Removes the technical “Mode” row and adds creator/copyright details.

Also included from 1.3.3
------------------------
• Installer, uninstaller, confirmation, completion, and error dialogs now bring
  themselves in front of Terminal.

Also included from 1.3.2
------------------------
• Uses the “inset.filled.center.rectangle” symbol in the menu bar.
• Shows that same symbol in the Manage Apps dialog instead of a missing icon.

Also included from 1.3.1
------------------------
• Fixes “Accessibility: Needed” when System Settings showed an enabled switch
  belonging to an older build.
• Upgrades now clear the stale permission identity and request one fresh grant.
• Repairs the startup job so it contains only the helper’s executable path.

Also included from 1.3.0
------------------------
• The Accessibility request appears only once instead of after every restart.
• The menu no longer lists every app; use “Manage Apps…” for the checkbox list.
• The version line is clickable and opens a native About window.
• Known enabled apps are centered at startup, including apps restored before the
  helper starts.

What it does
------------
• Centers the first normal window when an app opens.
• Centers newly created windows even when the app was already running.
• Learns each app automatically and enables it by default.
• Keeps a persistent list with an on/off switch for every learned app.
• Keeps windows on the display where they appeared and avoids the menu bar and Dock.
• Ignores minimized, full-screen, and nonstandard utility windows.
• Starts automatically when you log in.
• Uses only macOS frameworks and does not need Hammerspoon.

Install
-------
1. Double-click “Install Auto Center Windows.command”.
2. Wait for the “Installation complete” message. The installer starts the named
   background launcher and verifies that it is running.
3. When macOS asks, turn on the Auto Center Windows Accessibility entry.
   Reinstalling clears an old Accessibility grant because macOS ties it to a
   specific build identity.
4. Open an app or create a new window to test it.

If macOS blocks the installer, Control-click the installer, choose Open, then
click Open again.

After you approve the installer, it removes download quarantine only from its
own bundled helper so that the named background launcher can start without a second
Gatekeeper interruption. The helper is code-signed and checked before launch.

Turn individual apps on or off
------------------------------
Click the window icon in the menu bar, then choose “Manage Apps…”. Use the
checkbox list to turn centering on or off for each learned app. You can also double-click
“Configure Auto Center Windows.command” in this folder.

Choose the clickable “About Auto Center Windows…” menu item for version, running
status, Accessibility status, learned-app count, and centering mode.

The list begins empty. Apps are added when they launch or create a new window.

Uninstall
---------
Double-click “Uninstall Auto Center Windows.command” and confirm. No administrator
password is needed. The uninstaller removes the app, startup job, learned-app list,
logs, and Accessibility permission entry.

Troubleshooting
---------------
• The window-shaped menu bar icon confirms that the helper is running.
• Its menu shows whether Accessibility is Enabled or Needed.
• Installation details: ~/Library/Logs/Auto Center Windows Installer.log
• If an app is listed but unchecked, enable it and create a new window.
• Some apps deliberately prevent Accessibility tools from moving their windows.

Privacy
-------
Everything runs locally. There is no networking, analytics, or data collection.
The helper stores only app names, bundle identifiers, and each on/off choice.
