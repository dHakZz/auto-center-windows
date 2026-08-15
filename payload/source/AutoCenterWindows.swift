import AppKit
import ApplicationServices
import Foundation

private let watcherBundleID = "com.justin.auto-center-windows"
private let showSettingsNotification = Notification.Name("com.justin.auto-center-windows.show-settings")
private let autoCenterSymbolName = "inset.filled.center.rectangle"

private struct AppPreference: Codable {
    var name: String
    var bundleID: String
    var enabled: Bool
}

private struct WindowSnapshot {
    let id: CGWindowID
    let ownerPID: pid_t
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private func axAttribute<T>(_ element: AXUIElement, _ attribute: CFString, as type: T.Type = T.self) -> T? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else { return nil }
    return rawValue as? T
}

private func screenFramesInAXCoordinates() -> [(full: CGRect, visible: CGRect)] {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return [] }
    let primary = screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) ?? NSScreen.main ?? screens[0]
    let primaryTop = primary.frame.maxY

    func axRect(_ cocoaRect: CGRect) -> CGRect {
        CGRect(x: cocoaRect.minX, y: primaryTop - cocoaRect.maxY, width: cocoaRect.width, height: cocoaRect.height)
    }

    return screens.map { (full: axRect($0.frame), visible: axRect($0.visibleFrame)) }
}

private func centeredOrigin(windowRect: CGRect, screens: [(full: CGRect, visible: CGRect)]) -> CGPoint? {
    guard !screens.isEmpty else { return nil }
    let selected = screens.max { lhs, rhs in
        lhs.full.intersection(windowRect).area < rhs.full.intersection(windowRect).area
    } ?? screens[0]
    return CGPoint(
        x: selected.visible.midX - windowRect.width / 2,
        y: selected.visible.midY - windowRect.height / 2
    )
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, width > 0, height > 0 else { return 0 }
        return width * height
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let owner = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        owner.handleCreatedWindow(element)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let workspace = NSWorkspace.shared
    private let stateURL: URL
    private let permissionPromptMarkerURL: URL
    private var preferences: [String: AppPreference] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var knownWindowIDs: Set<CGWindowID> = []
    private var pendingPIDs: Set<pid_t> = []
    private var lastCenteredAt: [pid_t: Date] = [:]
    private var pollTimer: Timer?
    private var wasAccessibilityTrusted = false
    private var aboutWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsControls: [String: NSButton] = [:]

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Auto Center Windows", isDirectory: true)
        stateURL = support.appendingPathComponent("apps.plist")
        permissionPromptMarkerURL = support.appendingPathComponent("accessibility-prompted")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()
        configureApplicationIcon()
        configureStatusItem()
        registerNotifications()
        knownWindowIDs = Set(windowSnapshots().map(\.id))
        wasAccessibilityTrusted = AXIsProcessTrusted()
        requestAccessibilityIfNeeded()
        if wasAccessibilityTrusted {
            observeAllRunningApps()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.centerKnownEnabledRunningApps()
            }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        let accessibilityStatus = AXIsProcessTrusted() ? "enabled" : "needed"
        print("Auto Center Windows started; accessibility: \(accessibilityStatus); learned apps: \(preferences.count)")
    }

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AutoCenterWindows", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApp.applicationIconImage = icon
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        workspace.notificationCenter.removeObserver(self)
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: autoCenterSymbolName, accessibilityDescription: "Auto Center Windows")
            button.image?.isTemplate = true
            if button.image == nil { button.title = "⌗" }
            button.toolTip = "Auto Center Windows"
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    private func registerNotifications() {
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettingsFromNotification(_:)),
            name: showSettingsNotification,
            object: nil
        )
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        guard !FileManager.default.fileExists(atPath: permissionPromptMarkerURL.path) else { return }
        do {
            try FileManager.default.createDirectory(at: permissionPromptMarkerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: permissionPromptMarkerURL, options: .atomic)
        } catch {
            fputs("Could not record the one-time Accessibility request: \(error)\n", stderr)
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        if trusted && !wasAccessibilityTrusted {
            observeAllRunningApps()
            let pending = pendingPIDs
            pendingPIDs.removeAll()
            for pid in pending { scheduleCenterMainWindow(pid: pid, attempts: 12) }
            centerKnownEnabledRunningApps()
        }
        wasAccessibilityTrusted = trusted

        let snapshots = windowSnapshots()
        let currentIDs = Set(snapshots.map(\.id))
        let newIDs = currentIDs.subtracting(knownWindowIDs)
        knownWindowIDs = currentIDs

        for snapshot in snapshots where newIDs.contains(snapshot.id) {
            guard let app = NSRunningApplication(processIdentifier: snapshot.ownerPID), isManageable(app) else { continue }
            let key = ensurePreference(for: app)
            guard preferences[key]?.enabled == true else { continue }
            if trusted {
                let elapsed = Date().timeIntervalSince(lastCenteredAt[snapshot.ownerPID] ?? .distantPast)
                if elapsed > 0.6 { scheduleCenterMainWindow(pid: snapshot.ownerPID, attempts: 6) }
            } else {
                pendingPIDs.insert(snapshot.ownerPID)
            }
        }
    }

    private func windowSnapshots() -> [WindowSnapshot] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { item in
            guard
                let number = item[kCGWindowNumber as String] as? NSNumber,
                let owner = item[kCGWindowOwnerPID as String] as? NSNumber,
                let layer = item[kCGWindowLayer as String] as? NSNumber,
                layer.intValue == 0,
                let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 80,
                bounds.height >= 50
            else { return nil }
            return WindowSnapshot(id: CGWindowID(number.uint32Value), ownerPID: pid_t(owner.int32Value))
        }
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isManageable(app) else { return }
            let key = self.ensurePreference(for: app)
            if AXIsProcessTrusted() { self.observe(app) }
            guard self.preferences[key]?.enabled == true else { return }
            if AXIsProcessTrusted() {
                self.scheduleCenterMainWindow(pid: app.processIdentifier, attempts: 16)
            } else {
                self.pendingPIDs.insert(app.processIdentifier)
            }
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        pendingPIDs.remove(pid)
        lastCenteredAt.removeValue(forKey: pid)
    }

    private func observeAllRunningApps() {
        for app in workspace.runningApplications where isManageable(app) { observe(app) }
    }

    private func centerKnownEnabledRunningApps() {
        guard AXIsProcessTrusted() else { return }
        for app in workspace.runningApplications where isManageable(app) {
            let key = preferenceKey(for: app)
            guard preferences[key]?.enabled == true else { continue }
            observe(app)
            scheduleCenterMainWindow(pid: app.processIdentifier, attempts: 12)
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, AXIsProcessTrusted() else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func handleCreatedWindow(_ window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              isManageable(app)
        else { return }
        let key = ensurePreference(for: app)
        guard preferences[key]?.enabled == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if self.center(window: window) {
                self.lastCenteredAt[pid] = Date()
            } else {
                self.scheduleCenterMainWindow(pid: pid, attempts: 5)
            }
        }
    }

    private func scheduleCenterMainWindow(pid: pid_t, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: pid),
                  self.isManageable(app),
                  self.preferenceEnabled(for: app)
            else { return }
            if self.centerMainWindow(pid: pid) {
                self.lastCenteredAt[pid] = Date()
            } else {
                self.scheduleCenterMainWindow(pid: pid, attempts: attempts - 1)
            }
        }
    }

    private func centerMainWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        if let focused: AXUIElement = axAttribute(application, kAXFocusedWindowAttribute as CFString), center(window: focused) {
            return true
        }
        if let main: AXUIElement = axAttribute(application, kAXMainWindowAttribute as CFString), center(window: main) {
            return true
        }
        if let windows: [AXUIElement] = axAttribute(application, kAXWindowsAttribute as CFString) {
            for window in windows where center(window: window) { return true }
        }
        return false
    }

    private func center(window: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let role: String = axAttribute(window, kAXRoleAttribute as CFString), role != (kAXWindowRole as String) { return false }
        if let subrole: String = axAttribute(window, kAXSubroleAttribute as CFString), subrole != (kAXStandardWindowSubrole as String) { return false }
        if let minimized: NSNumber = axAttribute(window, kAXMinimizedAttribute as CFString), minimized.boolValue { return false }
        if let fullscreen: NSNumber = axAttribute(window, "AXFullScreen" as CFString), fullscreen.boolValue { return false }
        guard
            let positionValue: AXValue = axAttribute(window, kAXPositionAttribute as CFString),
            let sizeValue: AXValue = axAttribute(window, kAXSizeAttribute as CFString)
        else { return false }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0
        else { return false }

        let windowRect = CGRect(origin: position, size: size)
        guard var newPosition = centeredOrigin(windowRect: windowRect, screens: screenFramesInAXCoordinates()) else { return false }
        newPosition.x.round()
        newPosition.y.round()
        guard let newValue = AXValueCreate(.cgPoint, &newPosition) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, newValue) == .success
    }

    private func isManageable(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular
        else { return false }
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        if bundleID == watcherBundleID || bundleID == "com.justin.auto-center-windows.settings" { return false }
        if bundleID == "com.apple.osascript" { return false }
        return !(app.localizedName ?? "").isEmpty || !bundleID.isEmpty
    }

    private func preferenceKey(for app: NSRunningApplication) -> String {
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty { return bundleID.lowercased() }
        return "name:" + (app.localizedName ?? "unknown").lowercased()
    }

    @discardableResult
    private func ensurePreference(for app: NSRunningApplication) -> String {
        let key = preferenceKey(for: app)
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown App"
        let bundleID = app.bundleIdentifier ?? ""
        if var existing = preferences[key] {
            if existing.name != name || existing.bundleID != bundleID {
                existing.name = name
                existing.bundleID = bundleID
                preferences[key] = existing
                savePreferences()
            }
        } else {
            preferences[key] = AppPreference(name: name, bundleID: bundleID, enabled: true)
            savePreferences()
            print("Learned app: \(name) [enabled]")
        }
        return key
    }

    private func preferenceEnabled(for app: NSRunningApplication) -> Bool {
        let key = ensurePreference(for: app)
        return preferences[key]?.enabled == true
    }

    private func loadPreferences() {
        guard let data = try? Data(contentsOf: stateURL),
              let loaded = try? PropertyListDecoder().decode([String: AppPreference].self, from: data)
        else { return }
        preferences = loaded
    }

    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(preferences)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            fputs("Could not save learned apps: \(error)\n", stderr)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = NSMenuItem(title: AXIsProcessTrusted() ? "Accessibility: Enabled" : "Accessibility: Needed", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(withTitle: "Manage Apps…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())

        if preferences.isEmpty {
            let empty = NSMenuItem(title: "No apps learned yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "About Auto Center Windows", action: #selector(showAbout), keyEquivalent: "")
        versionItem.target = self
        menu.addItem(versionItem)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            workspace.open(url)
        }
    }

    @objc private func showSettingsFromNotification(_ notification: Notification) {
        showSettings()
    }

    @objc private func showAbout() {
        if let aboutWindow, aboutWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 458),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Auto Center Windows"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        guard let content = window.contentView else { return }

        let imageView = NSImageView(frame: NSRect(x: 70, y: 310, width: 140, height: 100))
        let symbol = NSImage(systemSymbolName: autoCenterSymbolName, accessibilityDescription: "Centered window")
        imageView.image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 76, weight: .regular))
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)

        let title = infoText("Auto Center Windows", frame: NSRect(x: 10, y: 258, width: 260, height: 36), size: 22, weight: .bold, alignment: .center)
        content.addSubview(title)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let details: [(String, String)] = [
            ("Version", version),
            ("Status", "Running"),
            ("Accessibility", AXIsProcessTrusted() ? "Enabled" : "Needed")
        ]
        var y: CGFloat = 210
        for (label, value) in details {
            content.addSubview(infoText(label, frame: NSRect(x: 20, y: y, width: 110, height: 20), size: 13, weight: .regular, alignment: .right))
            content.addSubview(infoText(value, frame: NSRect(x: 145, y: y, width: 115, height: 20), size: 13, weight: .regular, alignment: .left, color: .secondaryLabelColor))
            y -= 26
        }

        content.addSubview(infoText("Learned apps", frame: NSRect(x: 20, y: y, width: 110, height: 20), size: 13, weight: .regular, alignment: .right))
        content.addSubview(infoText("\(preferences.count)", frame: NSRect(x: 145, y: y, width: 115, height: 20), size: 13, weight: .regular, alignment: .left, color: .secondaryLabelColor))

        let manageButton = NSButton(title: "Manage Apps…", target: self, action: #selector(showSettingsFromAbout))
        manageButton.frame = NSRect(x: 80, y: 76, width: 120, height: 32)
        manageButton.bezelStyle = .rounded
        manageButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        manageButton.keyEquivalent = "\r"
        manageButton.toolTip = "Open the learned-app list"
        content.addSubview(manageButton)

        content.addSubview(infoText("© 2026 Justin Chacon", frame: NSRect(x: 20, y: 22, width: 240, height: 16), size: 10.5, weight: .regular, alignment: .center, color: .tertiaryLabelColor))

        aboutWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func infoText(
        _ string: String,
        frame: NSRect,
        size: CGFloat,
        weight: NSFont.Weight,
        alignment: NSTextAlignment,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.frame = frame
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.alignment = alignment
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    @objc private func showSettingsFromAbout() {
        aboutWindow?.orderOut(nil)
        showSettings()
    }

    @objc private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let sorted = preferences.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 458),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Apps"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.closeButton)?.target = self
        window.standardWindowButton(.closeButton)?.action = #selector(cancelSettingsWindow)
        guard let content = window.contentView else { return }

        let imageView = NSImageView(frame: NSRect(x: 90, y: 348, width: 100, height: 72))
        let symbol = NSImage(systemSymbolName: autoCenterSymbolName, accessibilityDescription: "Manage centered apps")
        imageView.image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 56, weight: .regular))
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)

        content.addSubview(infoText("Manage Apps", frame: NSRect(x: 15, y: 310, width: 250, height: 30), size: 20, weight: .bold, alignment: .center))
        content.addSubview(infoText("Choose which apps are centered automatically.", frame: NSRect(x: 15, y: 284, width: 250, height: 18), size: 10.5, weight: .regular, alignment: .center, color: .secondaryLabelColor))
        content.addSubview(infoText("\(sorted.count) learned apps", frame: NSRect(x: 15, y: 264, width: 250, height: 16), size: 10.5, weight: .regular, alignment: .center, color: .tertiaryLabelColor))

        settingsControls.removeAll()
        if sorted.isEmpty {
            let emptyBox = NSBox(frame: NSRect(x: 20, y: 96, width: 240, height: 158))
            emptyBox.boxType = .custom
            emptyBox.borderWidth = 1
            emptyBox.borderColor = .separatorColor
            emptyBox.fillColor = .textBackgroundColor
            emptyBox.titlePosition = .noTitle
            content.addSubview(emptyBox)
            content.addSubview(infoText("No apps learned yet", frame: NSRect(x: 35, y: 172, width: 210, height: 22), size: 13, weight: .medium, alignment: .center))
            content.addSubview(infoText("Open an app or create a new window.", frame: NSRect(x: 35, y: 149, width: 210, height: 18), size: 10.5, weight: .regular, alignment: .center, color: .secondaryLabelColor))
        } else {
            let rowHeight: CGFloat = 42
            let documentHeight = max(158, CGFloat(sorted.count) * rowHeight + 6)
            let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 224, height: documentHeight))

            for (index, pair) in sorted.enumerated() {
                let preference = pair.value
                let rowY = CGFloat(index) * rowHeight + 3
                let checkbox = NSButton(checkboxWithTitle: preference.name, target: nil, action: nil)
                checkbox.frame = NSRect(x: 8, y: rowY, width: 208, height: 22)
                checkbox.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
                checkbox.state = preference.enabled ? .on : .off
                checkbox.toolTip = preference.bundleID.isEmpty ? preference.name : "\(preference.name) — \(preference.bundleID)"
                documentView.addSubview(checkbox)

                if !preference.bundleID.isEmpty {
                    let identifier = infoText(preference.bundleID, frame: NSRect(x: 29, y: rowY + 22, width: 186, height: 14), size: 9.5, weight: .regular, alignment: .left, color: .secondaryLabelColor)
                    identifier.toolTip = preference.bundleID
                    documentView.addSubview(identifier)
                }
                settingsControls[pair.key] = checkbox
            }

            let scrollView = NSScrollView(frame: NSRect(x: 20, y: 96, width: 240, height: 158))
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .bezelBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.documentView = documentView
            content.addSubview(scrollView)
        }

        let cancelButton = NSButton(title: sorted.isEmpty ? "Done" : "Cancel", target: self, action: #selector(cancelSettingsWindow))
        cancelButton.frame = sorted.isEmpty ? NSRect(x: 80, y: 48, width: 120, height: 32) : NSRect(x: 32, y: 48, width: 100, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        content.addSubview(cancelButton)

        if !sorted.isEmpty {
            let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettingsWindow))
            saveButton.frame = NSRect(x: 148, y: 48, width: 100, height: 32)
            saveButton.bezelStyle = .rounded
            saveButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            saveButton.keyEquivalent = "\r"
            content.addSubview(saveButton)
        }

        content.addSubview(infoText("© 2026 Justin Chacon", frame: NSRect(x: 20, y: 16, width: 240, height: 16), size: 9.5, weight: .regular, alignment: .center, color: .tertiaryLabelColor))

        settingsWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)

        if settingsWindow === window {
            window.orderOut(nil)
            settingsWindow = nil
            settingsControls.removeAll()
        }
    }

    @objc private func saveSettingsWindow() {
        for (key, checkbox) in settingsControls {
            guard var preference = preferences[key] else { continue }
            preference.enabled = checkbox.state == .on
            preferences[key] = preference
        }
        savePreferences()
        cancelSettingsWindow()
    }

    @objc private func cancelSettingsWindow() {
        NSApp.stopModal()
        settingsWindow?.orderOut(nil)
        settingsWindow = nil
        settingsControls.removeAll()
    }
}

private func runSelfTests() -> Bool {
    let screens = [
        (full: CGRect(x: 0, y: 0, width: 1000, height: 800), visible: CGRect(x: 0, y: 24, width: 1000, height: 736)),
        (full: CGRect(x: 1000, y: 0, width: 800, height: 600), visible: CGRect(x: 1000, y: 24, width: 800, height: 576))
    ]
    let first = centeredOrigin(windowRect: CGRect(x: 50, y: 50, width: 400, height: 300), screens: screens)
    let second = centeredOrigin(windowRect: CGRect(x: 1200, y: 80, width: 400, height: 300), screens: screens)
    guard first == CGPoint(x: 300, y: 242), second == CGPoint(x: 1200, y: 162) else { return false }

    let sample = ["com.apple.safari": AppPreference(name: "Safari", bundleID: "com.apple.Safari", enabled: false)]
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    guard let data = try? encoder.encode(sample),
          let decoded = try? PropertyListDecoder().decode([String: AppPreference].self, from: data),
          decoded["com.apple.safari"]?.enabled == false
    else { return false }
    return true
}

private func setFileIcon(iconPath: String, targetPath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: targetPath),
          let icon = NSImage(contentsOfFile: iconPath)
    else { return false }
    return NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: [])
}

if CommandLine.arguments.contains("--self-test") {
    if runSelfTests() {
        print("Self-test passed")
        exit(EXIT_SUCCESS)
    } else {
        fputs("Self-test failed\n", stderr)
        exit(EXIT_FAILURE)
    }
}

if let iconOption = CommandLine.arguments.firstIndex(of: "--set-file-icon") {
    guard CommandLine.arguments.count > iconOption + 2 else {
        fputs("--set-file-icon requires an icon path and target path.\n", stderr)
        exit(EXIT_FAILURE)
    }
    exit(setFileIcon(
        iconPath: CommandLine.arguments[iconOption + 1],
        targetPath: CommandLine.arguments[iconOption + 2]
    ) ? EXIT_SUCCESS : EXIT_FAILURE)
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
