import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import OpenPathTraceCore
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "dev.repairman.OpenPathTrace", category: "app")

struct DetectedDialog {
    let pid: pid_t
    let element: AXUIElement
    let frame: CGRect
    let title: String
    let reason: String
}

struct PathEntry {
    let group: String
    let title: String
    let path: String
    let favorite: Bool
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem!
    private let pathStore = PathStore()
    private let overlay = OverlayPanelController()
    private let navigator = DialogNavigator()
    private let finder = FinderPathProvider()
    private let launchAtLogin = LaunchAtLoginController()
    private var monitor: AccessibilityMonitor!
    private var config = AppConfig()
    private var currentDialog: DetectedDialog?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        NSApp.setActivationPolicy(.accessory)

        config = pathStore.load()
        seedFavoritesIfNeeded()
        setupStatusItem()
        checkAccessibilityPermission(prompt: true)

        monitor = AccessibilityMonitor { [weak self] dialog in
            self?.handle(dialog: dialog)
        }
        monitor.start()
        logger.info("OpenPathTrace 已启动")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "OPT"
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开配置文件", action: #selector(openConfigFile), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "打开辅助功能设置", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        launchAtLoginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        refreshLaunchAtLoginState()
        return menu
    }

    private func handle(dialog: DetectedDialog?) {
        guard let dialog else {
            currentDialog = nil
            overlay.hide()
            return
        }

        currentDialog = dialog
        overlay.show(
            dialog: dialog,
            entries: pathEntries(),
            onSelect: { [weak self] path in self?.jump(to: path) },
            onToggleFavorite: { [weak self] path in self?.toggleFavorite(path) }
        )
    }

    private func pathEntries() -> [PathEntry] {
        var entries: [PathEntry] = []
        let favorites = existing(config.favorites)
        let recent = existing(config.recent).filter { !favorites.contains($0) }
        let finderPaths = existing(finder.openWindowPaths()).filter { !favorites.contains($0) && !recent.contains($0) }

        entries += favorites.map { entry(group: "收藏", path: $0, favorite: true) }
        entries += recent.map { entry(group: "最近", path: $0, favorite: config.favorites.contains($0)) }
        entries += finderPaths.map { entry(group: "Finder", path: $0, favorite: config.favorites.contains($0)) }
        return entries
    }

    private func entry(group: String, path: String, favorite: Bool) -> PathEntry {
        let title = URL(fileURLWithPath: path).lastPathComponent
        return PathEntry(group: group, title: title.isEmpty ? path : title, path: path, favorite: favorite)
    }

    private func existing(_ paths: [String]) -> [String] {
        paths.reduce(into: []) { result, path in
            guard FileManager.default.fileExists(atPath: path), !result.contains(path) else { return }
            result.append(path)
        }
    }

    private func seedFavoritesIfNeeded() {
        guard config.favorites.isEmpty else { return }
        config.favorites = existing([
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Downloads",
            NSHomeDirectory() + "/Documents",
            "/Users/repairman/code"
        ])
        saveConfig()
    }

    private func jump(to path: String) {
        guard let dialog = currentDialog else { return }
        navigator.jump(to: path, in: dialog)
        config.recordRecent(path)
        saveConfig()
        logger.info("已发送跳转路径 path=\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
        handle(dialog: dialog)
    }

    private func toggleFavorite(_ path: String) {
        config.toggleFavorite(path)
        saveConfig()
        if let currentDialog {
            handle(dialog: currentDialog)
        }
    }

    private func saveConfig() {
        do {
            try pathStore.save(config)
        } catch {
            logger.error("保存配置失败 error=\(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let trusted = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        statusItem.button?.title = trusted ? "OPT" : "OPT!"
        logger.info("辅助功能权限 trusted=\(trusted)")
        return trusted
    }

    @objc private func openConfigFile() {
        saveConfig()
        NSWorkspace.shared.activateFileViewerSelecting([PathStore.defaultFileURL()])
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
            config.launchAtLogin = launchAtLogin.isEnabled
            saveConfig()
        } catch {
            NSAlert(error: error).runModal()
            logger.error("切换登录启动失败 error=\(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem?.state = launchAtLogin.isEnabled ? .on : .off
    }
}

@MainActor
final class AccessibilityMonitor {
    private let onChange: (DetectedDialog?) -> Void
    private let detector = FileDialogDetector()
    private var currentPID: pid_t = 0
    private var currentAppName = ""
    private var currentApp: AXUIElement?
    private var observer: AXObserver?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var lastSignature = ""

    init(onChange: @escaping (DetectedDialog?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frontmostAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        attach(to: NSWorkspace.shared.frontmostApplication)
        timer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(timerTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func timerTick() {
        refreshFrontmostAppIfNeeded()
        scan(reason: "poll", deep: false)
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        attach(to: notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func attach(to app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard app.processIdentifier != currentPID else { return }
        currentPID = app.processIdentifier
        currentAppName = app.localizedName ?? "unknown"
        currentApp = AXUIElementCreateApplication(app.processIdentifier)
        lastSignature = ""

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        observer = nil
        source = nil

        var newObserver: AXObserver?
        let error = AXObserverCreate(app.processIdentifier, { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                monitor.scan(reason: notification as String, deep: true)
            }
        }, &newObserver)

        guard error == .success, let newObserver, let currentApp else {
            logger.error("AX observer 挂载失败 app=\(self.currentAppName, privacy: .public) error=\(error.rawValue)")
            scan(reason: "attach-fallback", deep: true)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, currentApp, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(newObserver, currentApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        let runLoopSource = AXObserverGetRunLoopSource(newObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        observer = newObserver
        source = runLoopSource
        logger.info("开始监听前台应用 app=\(self.currentAppName, privacy: .public) pid=\(app.processIdentifier)")
        scan(reason: "attach", deep: true)
    }

    private func refreshFrontmostAppIfNeeded() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != currentPID else { return }
        logger.info("前台应用切换 from=\(self.currentAppName, privacy: .public) to=\(app.localizedName ?? "unknown", privacy: .public)")
        attach(to: app)
    }

    private func scan(reason: String, deep: Bool) {
        guard let currentApp else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let dialog = detector.findDialog(in: currentApp, pid: currentPID, reason: reason, deep: deep)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        let signature = dialog.map { "\($0.pid)|\(Int($0.frame.origin.x))|\(Int($0.frame.origin.y))|\($0.title)" } ?? "none"
        guard signature != lastSignature || reason != "poll" else { return }
        lastSignature = signature

        if let dialog {
            logger.info("识别到文件弹窗 app=\(self.currentAppName, privacy: .public) reason=\(reason, privacy: .public) scanMs=\(elapsed) title=\(dialog.title, privacy: .public)")
        } else if reason != "poll" {
            logger.debug("未识别文件弹窗 app=\(self.currentAppName, privacy: .public) reason=\(reason, privacy: .public) scanMs=\(elapsed)")
        }
        onChange(dialog)
    }
}

final class FileDialogDetector {
    func findDialog(in app: AXUIElement, pid: pid_t, reason: String, deep: Bool) -> DetectedDialog? {
        if let focused = elementAttribute(app, kAXFocusedWindowAttribute),
           let dialog = findDialog(in: focused, pid: pid, reason: reason, depth: 0, visited: 0) {
            return dialog
        }

        guard deep else { return nil }
        for window in arrayAttribute(app, kAXWindowsAttribute) {
            if let dialog = findDialog(in: window, pid: pid, reason: reason, depth: 0, visited: 0) {
                return dialog
            }
        }
        return nil
    }

    private func findDialog(in element: AXUIElement, pid: pid_t, reason: String, depth: Int, visited: Int) -> DetectedDialog? {
        guard depth <= 5, visited < 160 else { return nil }
        if let dialog = detect(element, pid: pid, reason: reason) {
            return dialog
        }

        var count = visited
        for child in arrayAttribute(element, kAXChildrenAttribute) {
            count += 1
            if let dialog = findDialog(in: child, pid: pid, reason: reason, depth: depth + 1, visited: count) {
                return dialog
            }
        }
        return nil
    }

    private func detect(_ element: AXUIElement, pid: pid_t, reason: String) -> DetectedDialog? {
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        guard role == kAXWindowRole as String || role == "AXSheet" || subrole == kAXDialogSubrole as String else {
            return nil
        }

        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let lower = title.lowercased()
        let titleMatches = ["open", "save", "export", "upload", "choose", "打开", "存储", "保存", "另存为", "导出", "上传", "选取", "选择"]
            .contains { lower.contains($0) }
        let controlMatches = containsAnyControlTitle(in: element, depth: 0)
        guard titleMatches || controlMatches else { return nil }

        guard let frame = frame(of: element), frame.width > 300, frame.height > 180 else { return nil }
        return DetectedDialog(pid: pid, element: element, frame: frame, title: title.isEmpty ? role : title, reason: reason)
    }

    private func containsAnyControlTitle(in element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 4 else { return false }
        let title = (stringAttribute(element, kAXTitleAttribute) ?? "").lowercased()
        if ["open", "save", "cancel", "choose", "打开", "存储", "保存", "取消", "选取", "选择"].contains(where: { title == $0 || title.contains($0) }) {
            return true
        }
        return arrayAttribute(element, kAXChildrenAttribute).contains { containsAnyControlTitle(in: $0, depth: depth + 1) }
    }
}

@MainActor
final class OverlayPanelController: NSObject, NSSearchFieldDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
        styleMask: [.titled, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    private let searchField = NSSearchField(frame: .zero)
    private let contentStack = NSStackView()
    private var entries: [PathEntry] = []
    private var onSelect: ((String) -> Void)?
    private var onToggleFavorite: ((String) -> Void)?

    override init() {
        super.init()
        panel.title = "OpenPathTrace"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        buildShell()
    }

    func show(
        dialog: DetectedDialog,
        entries: [PathEntry],
        onSelect: @escaping (String) -> Void,
        onToggleFavorite: @escaping (String) -> Void
    ) {
        let start = CFAbsoluteTimeGetCurrent()
        self.entries = entries
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        renderEntries()

        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(dialog.frame) } ?? NSScreen.main
        let origin = OverlayPlacement.origin(
            dialogFrame: dialog.frame,
            panelSize: panel.frame.size,
            visibleFrame: screen?.visibleFrame ?? .zero
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        logger.info("面板显示完成 elapsedMs=\(elapsed)")
    }

    func hide() {
        panel.orderOut(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        renderEntries()
    }

    private func buildShell() {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        searchField.placeholderString = "搜索路径"
        searchField.delegate = self
        root.addArrangedSubview(searchField)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6

        contentStack.widthAnchor.constraint(equalToConstant: 270).isActive = true
        root.addArrangedSubview(contentStack)

        let view = NSView(frame: panel.frame)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        panel.contentView = view
    }

    private func renderEntries() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let query = (searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
        let filtered = entries.filter { entry in
            query.isEmpty || entry.title.lowercased().contains(query) || entry.path.lowercased().contains(query)
        }

        if filtered.isEmpty {
            let empty = NSTextField(labelWithString: "没有可显示路径")
            empty.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(empty)
            return
        }

        var currentGroup = ""
        for entry in filtered {
            if entry.group != currentGroup {
                currentGroup = entry.group
                let label = NSTextField(labelWithString: entry.group)
                label.font = .boldSystemFont(ofSize: 12)
                label.textColor = .secondaryLabelColor
                contentStack.addArrangedSubview(label)
            }

            let button = PathButton(entry: entry)
            button.target = self
            button.action = #selector(pathClicked(_:))
            button.onToggleFavorite = { [weak self] path in self?.onToggleFavorite?(path) }
            button.widthAnchor.constraint(equalToConstant: 260).isActive = true
            contentStack.addArrangedSubview(button)
        }
    }

    @objc private func pathClicked(_ sender: PathButton) {
        onSelect?(sender.entry.path)
    }
}

@MainActor
final class PathButton: NSButton {
    let entry: PathEntry
    var onToggleFavorite: ((String) -> Void)?

    init(entry: PathEntry) {
        self.entry = entry
        super.init(frame: .zero)
        title = "\(entry.favorite ? "★ " : "")\(entry.title)"
        bezelStyle = .rounded
        alignment = .left
        toolTip = entry.path
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: entry.favorite ? "取消收藏" : "收藏", action: #selector(toggleFavorite), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleFavorite() {
        onToggleFavorite?(entry.path)
    }
}

@MainActor
final class DialogNavigator {
    private let source = CGEventSource(stateID: .hidSystemState)

    func jump(to path: String, in dialog: DetectedDialog) {
        logger.info("开始跳转 path=\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
        NSRunningApplication(processIdentifier: dialog.pid)?.activate(options: [])
        AXUIElementPerformAction(dialog.element, kAXRaiseAction as CFString)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.postKey(5, flags: [.maskCommand, .maskShift])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                self.type(path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.postKey(36)
                    logger.info("跳转按键序列已发送")
                }
            }
        }
    }

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        for codeUnit in text.utf16 {
            var unit = UniChar(codeUnit)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up?.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }
}

final class FinderPathProvider {
    func openWindowPaths() -> [String] {
        let source = """
        tell application "Finder"
            set output to ""
            repeat with w in windows
                try
                    set output to output & POSIX path of (target of w as alias) & linefeed
                end try
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error {
                logger.debug("Finder 路径读取失败 error=\(String(describing: error), privacy: .public)")
            }
            return []
        }
        return result
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

final class LaunchAtLoginController {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else { return nil }
    return (value as! AXUIElement)
}

private func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}

private func frame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue,
          let sizeValue else {
        return nil
    }

    let positionAX = positionValue as! AXValue
    let sizeAX = sizeValue as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionAX, .cgPoint, &position)
    AXValueGetValue(sizeAX, .cgSize, &size)
    return CGRect(origin: position, size: size)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
