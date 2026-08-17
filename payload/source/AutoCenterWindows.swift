import AppKit
import ApplicationServices
import Foundation

private let watcherBundleID = "com.justin.auto-center-windows"
private let showSettingsNotification = Notification.Name("com.justin.auto-center-windows.show-settings")
private let autoCenterSymbolName = "inset.filled.center.rectangle"

private struct WindowPreference: Codable {
    var name: String
    var identifier: String
    var title: String
    var role: String
    var subrole: String
    var enabled: Bool

    func matches(_ identity: WindowIdentity) -> Bool {
        if !title.isEmpty {
            return title.caseInsensitiveCompare(identity.title) == .orderedSame
                && (role.isEmpty || role == identity.role)
                && (subrole.isEmpty || subrole == identity.subrole)
        }
        if !identifier.isEmpty {
            return identifier.caseInsensitiveCompare(identity.identifier) == .orderedSame
        }
        return !role.isEmpty
            && role == identity.role
            && (subrole.isEmpty || subrole == identity.subrole)
    }
}

private struct AppPreference: Codable {
    var name: String
    var bundleID: String
    var enabled: Bool
    var windows: [String: WindowPreference]

    init(name: String, bundleID: String, enabled: Bool, windows: [String: WindowPreference] = [:]) {
        self.name = name
        self.bundleID = bundleID
        self.enabled = enabled
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case name, bundleID, enabled, windows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        windows = try container.decodeIfPresent([String: WindowPreference].self, forKey: .windows) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(windows, forKey: .windows)
    }
}

private struct WindowIdentity {
    let title: String
    let identifier: String
    let role: String
    let subrole: String

    var key: String {
        if !title.isEmpty {
            return "title:" + title.lowercased() + "|role:" + role.lowercased() + "|subrole:" + subrole.lowercased()
        }
        if !identifier.isEmpty { return "identifier:" + identifier.lowercased() }
        return "role:" + role.lowercased() + "|subrole:" + subrole.lowercased()
    }

    var displayName: String {
        if !title.isEmpty { return title }
        if role == kAXSheetRole { return "Sheet" }
        if subrole == kAXDialogSubrole { return "Dialog" }
        if subrole == kAXSystemDialogSubrole { return "System Dialog" }
        if subrole == kAXFloatingWindowSubrole { return "Floating Window" }
        return "Untitled Window"
    }
}

private struct WindowSnapshot {
    let id: CGWindowID
    let ownerPID: pid_t
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class PreferenceButton: NSButton {
    var appKey = ""
    var windowKey = ""
}

private final class WindowChoice: NSObject {
    let appKey: String
    let appName: String
    let bundleID: String
    let identity: WindowIdentity

    init(appKey: String, appName: String, bundleID: String, identity: WindowIdentity) {
        self.appKey = appKey
        self.appName = appName
        self.bundleID = bundleID
        self.identity = identity
    }
}

private enum CenterAttempt {
    case centered
    case explicitlyDisabled
    case disabledByApp
    case ineligible
    case failed
}

private enum CenterSearchResult {
    case centered
    case done
    case retry
}

private func axAttribute<T>(_ element: AXUIElement, _ attribute: CFString, as type: T.Type = T.self) -> T? {
    var rawValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success else { return nil }
    return rawValue as? T
}

private func trimmedAXString(_ element: AXUIElement, _ attribute: CFString) -> String {
    let value: String = axAttribute(element, attribute) ?? ""
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func windowIdentity(_ window: AXUIElement) -> WindowIdentity {
    WindowIdentity(
        title: trimmedAXString(window, kAXTitleAttribute as CFString),
        identifier: trimmedAXString(window, "AXIdentifier" as CFString),
        role: trimmedAXString(window, kAXRoleAttribute as CFString),
        subrole: trimmedAXString(window, kAXSubroleAttribute as CFString)
    )
}

private func isWindowLikeRole(_ role: String) -> Bool {
    role == kAXWindowRole || role == kAXSheetRole
}

private func accessibleWindows(_ application: AXUIElement) -> [AXUIElement] {
    let topLevel: [AXUIElement] = axAttribute(application, kAXWindowsAttribute as CFString) ?? []
    var result: [AXUIElement] = []
    var queue = topLevel
    var seen: Set<CFHashCode> = []

    while !queue.isEmpty, result.count < 100 {
        let window = queue.removeFirst()
        let hash = CFHash(window)
        guard seen.insert(hash).inserted else { continue }
        let role = trimmedAXString(window, kAXRoleAttribute as CFString)
        guard isWindowLikeRole(role) else { continue }
        result.append(window)

        let sheets: [AXUIElement] = axAttribute(window, "AXSheets" as CFString) ?? []
        let children: [AXUIElement] = axAttribute(window, kAXChildrenAttribute as CFString) ?? []
        queue.append(contentsOf: sheets)
        queue.append(contentsOf: children.filter {
            isWindowLikeRole(trimmedAXString($0, kAXRoleAttribute as CFString))
        })
    }
    return result
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
    private var settingsDraft: [String: AppPreference] = [:]
    private var settingsControls: [String: NSButton] = [:]
    private var settingsWindowControls: [String: [String: NSButton]] = [:]
    private var expandedAppKeys: Set<String> = []

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
            for pid in pending { scheduleCenterBestWindow(pid: pid, attempts: 12) }
            centerKnownEnabledRunningApps()
        }
        wasAccessibilityTrusted = trusted

        let snapshots = windowSnapshots()
        let currentIDs = Set(snapshots.map(\.id))
        let newIDs = currentIDs.subtracting(knownWindowIDs)
        knownWindowIDs = currentIDs

        for snapshot in snapshots where newIDs.contains(snapshot.id) {
            guard let app = NSRunningApplication(processIdentifier: snapshot.ownerPID), isManageable(app) else { continue }
            _ = ensurePreference(for: app)
            guard hasEnabledCentering(for: app) else { continue }
            if trusted {
                let elapsed = Date().timeIntervalSince(lastCenteredAt[snapshot.ownerPID] ?? .distantPast)
                if elapsed > 0.6 { scheduleCenterBestWindow(pid: snapshot.ownerPID, attempts: 6) }
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
            _ = self.ensurePreference(for: app)
            if AXIsProcessTrusted() { self.observe(app) }
            guard self.hasEnabledCentering(for: app) else { return }
            if AXIsProcessTrusted() {
                self.scheduleCenterBestWindow(pid: app.processIdentifier, attempts: 16)
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
            guard hasEnabledCentering(for: app) else { continue }
            observe(app)
            scheduleCenterBestWindow(pid: app.processIdentifier, attempts: 12)
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
        _ = ensurePreference(for: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            switch self.center(window: window, for: app) {
            case .centered:
                self.lastCenteredAt[pid] = Date()
            case .failed:
                self.scheduleCenter(window: window, pid: pid, attempts: 5)
            case .explicitlyDisabled, .disabledByApp, .ineligible:
                break
            }
        }
    }

    private func scheduleCenter(window: AXUIElement, pid: pid_t, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: pid),
                  self.isManageable(app)
            else { return }
            switch self.center(window: window, for: app) {
            case .centered:
                self.lastCenteredAt[pid] = Date()
            case .failed:
                self.scheduleCenter(window: window, pid: pid, attempts: attempts - 1)
            case .explicitlyDisabled, .disabledByApp, .ineligible:
                break
            }
        }
    }

    private func scheduleCenterBestWindow(pid: pid_t, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: pid),
                  self.isManageable(app),
                  self.hasEnabledCentering(for: app)
            else { return }
            switch self.centerBestWindow(pid: pid, app: app) {
            case .centered:
                self.lastCenteredAt[pid] = Date()
            case .done:
                break
            case .retry:
                self.scheduleCenterBestWindow(pid: pid, attempts: attempts - 1)
            }
        }
    }

    private func centerBestWindow(pid: pid_t, app: NSRunningApplication) -> CenterSearchResult {
        guard AXIsProcessTrusted() else { return .retry }
        let application = AXUIElementCreateApplication(pid)
        var candidates: [AXUIElement] = []
        if let focused: AXUIElement = axAttribute(application, kAXFocusedWindowAttribute as CFString) {
            candidates.append(focused)
        }
        if let main: AXUIElement = axAttribute(application, kAXMainWindowAttribute as CFString) {
            candidates.append(main)
        }
        candidates.append(contentsOf: accessibleWindows(application))

        var sawFailure = false
        for (index, window) in candidates.enumerated() {
            switch center(window: window, for: app) {
            case .centered:
                return .centered
            case .explicitlyDisabled:
                if index == 0 { return .done }
            case .failed:
                sawFailure = true
            case .ineligible:
                if index == 0 { return .done }
            case .disabledByApp:
                break
            }
        }
        return sawFailure || candidates.isEmpty ? .retry : .done
    }

    private func center(window: AXUIElement, for app: NSRunningApplication) -> CenterAttempt {
        guard AXIsProcessTrusted() else { return .failed }
        let appKey = ensurePreference(for: app)
        guard let preference = preferences[appKey] else { return .failed }
        let identity = windowIdentity(window)
        let explicitRule = preference.windows[identity.key] ?? preference.windows.values.first(where: { $0.matches(identity) })

        if let explicitRule {
            guard explicitRule.enabled else { return .explicitlyDisabled }
            guard isWindowLikeRole(identity.role) else { return .ineligible }
        } else {
            guard preference.enabled else { return .disabledByApp }
            guard identity.role == kAXWindowRole,
                  identity.subrole == kAXStandardWindowSubrole
            else { return .ineligible }
        }

        if let minimized: NSNumber = axAttribute(window, kAXMinimizedAttribute as CFString), minimized.boolValue { return .ineligible }
        if let fullscreen: NSNumber = axAttribute(window, "AXFullScreen" as CFString), fullscreen.boolValue { return .ineligible }
        guard
            let positionValue: AXValue = axAttribute(window, kAXPositionAttribute as CFString),
            let sizeValue: AXValue = axAttribute(window, kAXSizeAttribute as CFString)
        else { return .failed }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0
        else { return .failed }

        let windowRect = CGRect(origin: position, size: size)
        guard var newPosition = centeredOrigin(windowRect: windowRect, screens: screenFramesInAXCoordinates()) else { return .failed }
        newPosition.x.round()
        newPosition.y.round()
        guard let newValue = AXValueCreate(.cgPoint, &newPosition) else { return .failed }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, newValue) == .success ? .centered : .failed
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

    private func hasEnabledCentering(for app: NSRunningApplication) -> Bool {
        let key = ensurePreference(for: app)
        guard let preference = preferences[key] else { return false }
        return preference.enabled || preference.windows.values.contains(where: \.enabled)
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

    private func centerUtilityWindow(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        var origin = CGPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        )
        origin.x.round()
        origin.y.round()
        window.setFrameOrigin(origin)
    }

    private func bringForwardCentered(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        centerUtilityWindow(window)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.centerUtilityWindow(window)
        }
    }

    @objc private func showAbout() {
        if let aboutWindow, aboutWindow.isVisible {
            bringForwardCentered(aboutWindow)
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
        bringForwardCentered(window)
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
            bringForwardCentered(settingsWindow)
            return
        }

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
        settingsDraft = preferences
        settingsWindow = window
        rebuildSettingsContent(in: window)
        bringForwardCentered(window)
        NSApp.runModal(for: window)

        if settingsWindow === window {
            window.orderOut(nil)
            settingsWindow = nil
            settingsControls.removeAll()
            settingsWindowControls.removeAll()
            settingsDraft.removeAll()
        }
    }

    private func rebuildSettingsContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        settingsControls.removeAll()
        settingsWindowControls.removeAll()

        let sorted = settingsDraft.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
        let windowRuleCount = settingsDraft.values.reduce(0) { $0 + $1.windows.count }

        let imageView = NSImageView(frame: NSRect(x: 90, y: 348, width: 100, height: 72))
        let symbol = NSImage(systemSymbolName: autoCenterSymbolName, accessibilityDescription: "Manage centered apps and windows")
        imageView.image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 56, weight: .regular))
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)

        content.addSubview(infoText("Manage Apps", frame: NSRect(x: 15, y: 310, width: 250, height: 30), size: 20, weight: .bold, alignment: .center))
        content.addSubview(infoText("Apps set the default. Added windows override it.", frame: NSRect(x: 15, y: 284, width: 250, height: 18), size: 10.5, weight: .regular, alignment: .center, color: .secondaryLabelColor))
        content.addSubview(infoText("\(sorted.count) apps • \(windowRuleCount) added windows", frame: NSRect(x: 15, y: 264, width: 250, height: 16), size: 10.5, weight: .regular, alignment: .center, color: .tertiaryLabelColor))

        let addWindowButton = NSButton(title: "Add Window…", target: self, action: #selector(addWindowRule))
        addWindowButton.frame = NSRect(x: 85, y: 231, width: 110, height: 28)
        addWindowButton.bezelStyle = .rounded
        addWindowButton.controlSize = .small
        addWindowButton.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        addWindowButton.isEnabled = AXIsProcessTrusted()
        addWindowButton.toolTip = AXIsProcessTrusted()
            ? "Add one of the windows that is currently open"
            : "Enable Accessibility before adding a window"
        content.addSubview(addWindowButton)

        if sorted.isEmpty {
            let emptyBox = NSBox(frame: NSRect(x: 20, y: 88, width: 240, height: 136))
            emptyBox.boxType = .custom
            emptyBox.borderWidth = 1
            emptyBox.borderColor = .separatorColor
            emptyBox.fillColor = .textBackgroundColor
            emptyBox.titlePosition = .noTitle
            content.addSubview(emptyBox)
            content.addSubview(infoText("No apps learned yet", frame: NSRect(x: 35, y: 151, width: 210, height: 22), size: 13, weight: .medium, alignment: .center))
            content.addSubview(infoText("Open an app or use Add Window…", frame: NSRect(x: 35, y: 128, width: 210, height: 18), size: 10.5, weight: .regular, alignment: .center, color: .secondaryLabelColor))
        } else {
            let appRowHeight: CGFloat = 40
            let windowRowHeight: CGFloat = 36
            var documentHeight: CGFloat = 6
            for pair in sorted {
                documentHeight += appRowHeight
                if expandedAppKeys.contains(pair.key) {
                    documentHeight += CGFloat(pair.value.windows.count) * windowRowHeight
                }
            }
            documentHeight = max(136, documentHeight)
            let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 224, height: documentHeight))
            var rowY: CGFloat = 3

            for pair in sorted {
                let preference = pair.value
                let hasWindowRules = !preference.windows.isEmpty
                if hasWindowRules {
                    let disclosure = PreferenceButton(frame: NSRect(x: 4, y: rowY + 2, width: 20, height: 20))
                    disclosure.appKey = pair.key
                    disclosure.bezelStyle = .disclosure
                    disclosure.setButtonType(.onOff)
                    disclosure.state = expandedAppKeys.contains(pair.key) ? .on : .off
                    disclosure.target = self
                    disclosure.action = #selector(toggleAppDisclosure(_:))
                    disclosure.toolTip = expandedAppKeys.contains(pair.key) ? "Hide added windows" : "Show added windows"
                    documentView.addSubview(disclosure)
                }

                let checkbox = NSButton(checkboxWithTitle: preference.name, target: nil, action: nil)
                checkbox.frame = NSRect(x: hasWindowRules ? 25 : 8, y: rowY, width: hasWindowRules ? 190 : 207, height: 22)
                checkbox.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
                checkbox.state = preference.enabled ? .on : .off
                checkbox.toolTip = preference.bundleID.isEmpty ? preference.name : "\(preference.name) — \(preference.bundleID)"
                documentView.addSubview(checkbox)

                if !preference.bundleID.isEmpty {
                    let identifierX: CGFloat = hasWindowRules ? 46 : 29
                    let identifier = infoText(preference.bundleID, frame: NSRect(x: identifierX, y: rowY + 21, width: 168, height: 14), size: 9.25, weight: .regular, alignment: .left, color: .secondaryLabelColor)
                    identifier.toolTip = preference.bundleID
                    documentView.addSubview(identifier)
                }
                settingsControls[pair.key] = checkbox
                rowY += appRowHeight

                guard hasWindowRules, expandedAppKeys.contains(pair.key) else { continue }
                settingsWindowControls[pair.key] = [:]
                let sortedWindows = preference.windows.sorted { $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending }
                for windowPair in sortedWindows {
                    let windowPreference = windowPair.value
                    let windowCheckbox = NSButton(checkboxWithTitle: windowPreference.name, target: nil, action: nil)
                    windowCheckbox.frame = NSRect(x: 42, y: rowY, width: 154, height: 21)
                    windowCheckbox.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
                    windowCheckbox.state = windowPreference.enabled ? .on : .off
                    windowCheckbox.toolTip = "This window overrides the \(preference.name) app setting"
                    documentView.addSubview(windowCheckbox)

                    let rawTypeName = windowPreference.subrole.isEmpty ? windowPreference.role : windowPreference.subrole
                    let typeName = rawTypeName.isEmpty ? "Window" : rawTypeName.replacingOccurrences(of: "AX", with: "")
                    documentView.addSubview(infoText(typeName, frame: NSRect(x: 63, y: rowY + 20, width: 130, height: 13), size: 9, weight: .regular, alignment: .left, color: .secondaryLabelColor))

                    let removeButton = PreferenceButton(frame: NSRect(x: 196, y: rowY + 2, width: 20, height: 20))
                    removeButton.appKey = pair.key
                    removeButton.windowKey = windowPair.key
                    removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove window")
                    removeButton.isBordered = false
                    removeButton.target = self
                    removeButton.action = #selector(removeWindowRule(_:))
                    removeButton.toolTip = "Remove this window rule"
                    documentView.addSubview(removeButton)

                    settingsWindowControls[pair.key]?[windowPair.key] = windowCheckbox
                    rowY += windowRowHeight
                }
            }

            let scrollView = NSScrollView(frame: NSRect(x: 20, y: 88, width: 240, height: 136))
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .bezelBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.documentView = documentView
            content.addSubview(scrollView)
        }

        let cancelButton = NSButton(title: settingsDraft.isEmpty ? "Done" : "Cancel", target: self, action: #selector(cancelSettingsWindow))
        cancelButton.frame = settingsDraft.isEmpty ? NSRect(x: 80, y: 44, width: 120, height: 32) : NSRect(x: 32, y: 44, width: 100, height: 32)
        cancelButton.bezelStyle = .rounded
        cancelButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        content.addSubview(cancelButton)

        if !settingsDraft.isEmpty {
            let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettingsWindow))
            saveButton.frame = NSRect(x: 148, y: 44, width: 100, height: 32)
            saveButton.bezelStyle = .rounded
            saveButton.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            saveButton.keyEquivalent = "\r"
            content.addSubview(saveButton)
        }

        content.addSubview(infoText("© 2026 Justin Chacon", frame: NSRect(x: 20, y: 12, width: 240, height: 16), size: 9.5, weight: .regular, alignment: .center, color: .tertiaryLabelColor))
    }

    private func captureSettingsControls() {
        for (key, checkbox) in settingsControls {
            guard var preference = settingsDraft[key] else { continue }
            preference.enabled = checkbox.state == .on
            if let windowControls = settingsWindowControls[key] {
                for (windowKey, windowCheckbox) in windowControls {
                    guard var windowPreference = preference.windows[windowKey] else { continue }
                    windowPreference.enabled = windowCheckbox.state == .on
                    preference.windows[windowKey] = windowPreference
                }
            }
            settingsDraft[key] = preference
        }
    }

    @objc private func toggleAppDisclosure(_ sender: PreferenceButton) {
        captureSettingsControls()
        if expandedAppKeys.contains(sender.appKey) {
            expandedAppKeys.remove(sender.appKey)
        } else {
            expandedAppKeys.insert(sender.appKey)
        }
        if let settingsWindow { rebuildSettingsContent(in: settingsWindow) }
    }

    @objc private func removeWindowRule(_ sender: PreferenceButton) {
        captureSettingsControls()
        guard var preference = settingsDraft[sender.appKey] else { return }
        preference.windows.removeValue(forKey: sender.windowKey)
        settingsDraft[sender.appKey] = preference
        if preference.windows.isEmpty { expandedAppKeys.remove(sender.appKey) }
        if let settingsWindow { rebuildSettingsContent(in: settingsWindow) }
    }

    private func availableWindowChoices() -> [WindowChoice] {
        guard AXIsProcessTrusted() else { return [] }
        var choices: [WindowChoice] = []
        var seen: Set<String> = []

        for app in workspace.runningApplications where isManageable(app) {
            let appKey = preferenceKey(for: app)
            let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown App"
            let bundleID = app.bundleIdentifier ?? ""
            let preference = settingsDraft[appKey] ?? AppPreference(name: appName, bundleID: bundleID, enabled: true)
            let appElement = AXUIElementCreateApplication(app.processIdentifier)

            for window in accessibleWindows(appElement) {
                let identity = windowIdentity(window)
                guard isWindowLikeRole(identity.role) else { continue }
                let uniqueKey = appKey + "|" + identity.key
                guard !seen.contains(uniqueKey),
                      preference.windows[identity.key] == nil,
                      !preference.windows.values.contains(where: { $0.matches(identity) })
                else { continue }
                seen.insert(uniqueKey)
                choices.append(WindowChoice(appKey: appKey, appName: appName, bundleID: bundleID, identity: identity))
            }
        }

        return choices.sorted {
            let appComparison = $0.appName.localizedCaseInsensitiveCompare($1.appName)
            if appComparison != .orderedSame { return appComparison == .orderedAscending }
            return $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending
        }
    }

    @objc private func addWindowRule() {
        captureSettingsControls()
        guard let settingsWindow else { return }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert()
            alert.messageText = "Accessibility is needed"
            alert.informativeText = "Enable Auto Center Windows in Accessibility settings before adding a specific window."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: settingsWindow)
            return
        }

        let choices = availableWindowChoices()
        guard !choices.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No new windows found"
            alert.informativeText = "Open the window you want to add, then try Add Window… again. Windows already added are not shown."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: settingsWindow)
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        popup.removeAllItems()
        for choice in choices {
            let item = NSMenuItem(title: "\(choice.appName) — \(choice.identity.displayName)", action: nil, keyEquivalent: "")
            item.representedObject = choice
            item.toolTip = choice.identity.identifier.isEmpty ? choice.identity.title : choice.identity.identifier
            popup.menu?.addItem(item)
        }

        let alert = NSAlert()
        alert.messageText = "Add a Specific Window"
        alert.informativeText = "This window will appear under its app and can override the app's default setting."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self, weak popup] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let choice = popup?.selectedItem?.representedObject as? WindowChoice
            else { return }

            let existing = self.settingsDraft[choice.appKey]
            var preference = existing ?? AppPreference(name: choice.appName, bundleID: choice.bundleID, enabled: false)
            preference.windows[choice.identity.key] = WindowPreference(
                name: choice.identity.displayName,
                identifier: choice.identity.identifier,
                title: choice.identity.title,
                role: choice.identity.role,
                subrole: choice.identity.subrole,
                enabled: true
            )
            self.settingsDraft[choice.appKey] = preference
            self.expandedAppKeys.insert(choice.appKey)
            self.rebuildSettingsContent(in: settingsWindow)
        }
    }

    @objc private func saveSettingsWindow() {
        captureSettingsControls()
        preferences = settingsDraft
        savePreferences()
        cancelSettingsWindow()
    }

    @objc private func cancelSettingsWindow() {
        NSApp.stopModal()
        settingsWindow?.orderOut(nil)
        settingsWindow = nil
        settingsControls.removeAll()
        settingsWindowControls.removeAll()
        settingsDraft.removeAll()
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

    let titleIdentity = WindowIdentity(
        title: "Downloads",
        identifier: "BrowserWindow",
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole
    )
    let titleRule = WindowPreference(
        name: "Downloads",
        identifier: "BrowserWindow",
        title: "Downloads",
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        enabled: true
    )
    let differentTitle = WindowIdentity(
        title: "Settings",
        identifier: "BrowserWindow",
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole
    )
    guard titleRule.matches(titleIdentity), !titleRule.matches(differentTitle) else { return false }

    let sample = [
        "com.apple.safari": AppPreference(
            name: "Safari",
            bundleID: "com.apple.Safari",
            enabled: false,
            windows: [titleIdentity.key: titleRule]
        )
    ]
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    guard let data = try? encoder.encode(sample),
          let decoded = try? PropertyListDecoder().decode([String: AppPreference].self, from: data),
          decoded["com.apple.safari"]?.enabled == false,
          decoded["com.apple.safari"]?.windows[titleIdentity.key]?.enabled == true
    else { return false }

    let legacyObject: [String: Any] = [
        "com.apple.finder": [
            "name": "Finder",
            "bundleID": "com.apple.finder",
            "enabled": true
        ]
    ]
    guard let legacyData = try? PropertyListSerialization.data(
        fromPropertyList: legacyObject,
        format: .xml,
        options: 0
    ),
    let migrated = try? PropertyListDecoder().decode([String: AppPreference].self, from: legacyData),
    migrated["com.apple.finder"]?.enabled == true,
    migrated["com.apple.finder"]?.windows.isEmpty == true
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
