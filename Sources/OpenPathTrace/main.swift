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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var accessibilityItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private let pathStore = PathStore()
    private let overlay = OverlayPanelController()
    private let navigator = DialogNavigator()
    private let finder = FinderPathProvider()
    private let launchAtLogin = LaunchAtLoginController()
    private var monitor: AccessibilityMonitor!
    private var config = AppConfig()
    private var currentDialog: DetectedDialog?
    private var cachedFinderPaths: [String] = []
    private var finderRefreshInFlight = false
    private var jumpInFlight = false

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
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "打开配置文件", action: #selector(openConfigFile), keyEquivalent: ","))
        accessibilityItem = NSMenuItem(title: "辅助功能权限：检查中", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(accessibilityItem)
        launchAtLoginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        checkAccessibilityPermission(prompt: false)
        refreshLaunchAtLoginState()
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkAccessibilityPermission(prompt: false)
        refreshLaunchAtLoginState()
    }

    private func handle(dialog: DetectedDialog?) {
        guard OverlayUpdatePolicy.shouldRenderOverlay(hasDialog: dialog != nil, isJumping: jumpInFlight) else {
            if dialog == nil {
                currentDialog = nil
                overlay.hide()
            }
            return
        }

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
        refreshFinderPaths()
    }

    private func pathEntries() -> [PathEntry] {
        var entries: [PathEntry] = []
        let favorites = existing(config.favorites)
        let recent = existing(config.recent).filter { !favorites.contains($0) }
        let finderPaths = existing(cachedFinderPaths).filter { !favorites.contains($0) && !recent.contains($0) }

        entries += favorites.map { entry(group: "收藏", path: $0, favorite: true) }
        entries += recent.map { entry(group: "最近", path: $0, favorite: config.favorites.contains($0)) }
        entries += finderPaths.map { entry(group: "Finder", path: $0, favorite: config.favorites.contains($0)) }
        return entries
    }

    private func refreshFinderPaths() {
        guard !finderRefreshInFlight else { return }
        finderRefreshInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let paths = FinderPathProvider().openWindowPaths()
            Task { @MainActor in
                self.finderRefreshInFlight = false
                logger.info("Finder 路径刷新 count=\(paths.count) names=\(paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ","), privacy: .public)")
                guard self.cachedFinderPaths != paths else { return }
                self.cachedFinderPaths = paths
                if let currentDialog = self.currentDialog {
                    self.handle(dialog: currentDialog)
                }
            }
        }
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
        guard !jumpInFlight else { return }
        jumpInFlight = true
        overlay.hide()
        monitor.pauseScanning(for: 1.0)
        navigator.jump(to: path, in: dialog) { [weak self] in
            self?.finishJump()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.finishJump()
        }
        config.recordRecent(path)
        saveConfig()
        logger.info("已发送跳转路径 path=\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
    }

    private func finishJump() {
        guard jumpInFlight else { return }
        jumpInFlight = false
        if OverlayUpdatePolicy.shouldRenderAfterJump(hasDialog: currentDialog != nil),
           let currentDialog {
            handle(dialog: currentDialog)
        }
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
        accessibilityItem?.title = trusted ? "辅助功能已授权" : "辅助功能未授权 - 点击打开设置"
        accessibilityItem?.state = trusted ? .on : .off
        accessibilityItem?.toolTip = trusted ? "OpenPathTrace 可以监听标准文件弹窗" : "打开系统设置 > 隐私与安全性 > 辅助功能"
        if trusted {
            logger.info("辅助功能权限已授权")
        } else {
            logger.error("辅助功能未授权，文件弹窗监听不会生效")
        }
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
    private var scanPausedUntil = Date.distantPast

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
            timeInterval: 0.05,
            target: self,
            selector: #selector(timerTick),
            userInfo: nil,
            repeats: true
        )
    }

    func pauseScanning(for seconds: TimeInterval) {
        scanPausedUntil = Date().addingTimeInterval(seconds)
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
        guard Date() >= scanPausedUntil else { return }
        guard let currentApp else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let dialog = detector.findDialog(in: currentApp, pid: currentPID, reason: reason, deep: deep)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        let signature = dialog.map { "\($0.pid)|\(Int($0.frame.origin.x))|\(Int($0.frame.origin.y))|\($0.title)" } ?? "none"
        guard signature != lastSignature else { return }
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
        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let controlMatches = DialogHeuristic.shouldScanControlTitles(role: role, subrole: subrole, title: title)
            && containsAnyControlTitle(in: element, depth: 0)
        guard DialogHeuristic.acceptsWindow(role: role, subrole: subrole, title: title, hasControlTitleMatch: controlMatches) else { return nil }

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
final class SkeuoPanelView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedWhite: 0.90, alpha: 1),
            NSColor(calibratedWhite: 0.82, alpha: 1),
            NSColor(calibratedWhite: 0.76, alpha: 1)
        ])?.draw(in: bounds, angle: -90)
    }
}

@MainActor
final class SkeuoInsetView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGradient(colors: [
            NSColor(calibratedWhite: 0.70, alpha: 1),
            NSColor(calibratedWhite: 0.82, alpha: 1),
            NSColor(calibratedWhite: 0.92, alpha: 1)
        ])?.draw(in: path, angle: -90)
        NSColor(calibratedWhite: 0.50, alpha: 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()

        let inner = bounds.insetBy(dx: 4, dy: 4)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: 7, yRadius: 7)
        NSGradient(colors: [
            NSColor(calibratedWhite: 0.93, alpha: 1),
            NSColor(calibratedWhite: 0.98, alpha: 1),
            NSColor(calibratedWhite: 0.94, alpha: 1)
        ])?.draw(in: innerPath, angle: -90)
    }
}

@MainActor
final class OverlayPanelController: NSObject, NSSearchFieldDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
        styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
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
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        searchField.placeholderString = "搜索路径"
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 14)
        let searchWell = SkeuoInsetView()
        searchWell.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchWell.addSubview(searchField)
        root.addArrangedSubview(searchWell)
        NSLayoutConstraint.activate([
            searchWell.heightAnchor.constraint(equalToConstant: 38),
            searchWell.widthAnchor.constraint(equalToConstant: 276),
            searchField.leadingAnchor.constraint(equalTo: searchWell.leadingAnchor, constant: 7),
            searchField.trailingAnchor.constraint(equalTo: searchWell.trailingAnchor, constant: -7),
            searchField.centerYAnchor.constraint(equalTo: searchWell.centerYAnchor)
        ])

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 7
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentWell = SkeuoInsetView()
        contentWell.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentStack
        contentWell.addSubview(scrollView)
        root.addArrangedSubview(contentWell)
        NSLayoutConstraint.activate([
            contentWell.widthAnchor.constraint(equalToConstant: 276),
            contentWell.heightAnchor.constraint(equalToConstant: 260),
            scrollView.leadingAnchor.constraint(equalTo: contentWell.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: contentWell.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: contentWell.topAnchor, constant: 11),
            scrollView.bottomAnchor.constraint(equalTo: contentWell.bottomAnchor, constant: -11),
            contentStack.widthAnchor.constraint(equalToConstant: 248)
        ])

        let view = SkeuoPanelView(frame: panel.frame)
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
                label.textColor = NSColor(calibratedWhite: 0.32, alpha: 1)
                label.shadow = {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.white.withAlphaComponent(0.85)
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    return shadow
                }()
                contentStack.addArrangedSubview(label)
            }

            let button = PathButton(entry: entry)
            button.target = self
            button.action = #selector(pathClicked(_:))
            button.onToggleFavorite = { [weak self] path in self?.onToggleFavorite?(path) }
            button.widthAnchor.constraint(equalToConstant: 248).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
        title = ""
        isBordered = false
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

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let colors = isHighlighted
            ? [NSColor(calibratedWhite: 0.82, alpha: 1), NSColor(calibratedWhite: 0.94, alpha: 1)]
            : [NSColor.white, NSColor(calibratedWhite: 0.88, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: path, angle: -90)
        NSColor(calibratedWhite: 0.54, alpha: 0.75).setStroke()
        path.lineWidth = 1
        path.stroke()

        let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(isHighlighted ? 0.12 : 0.36).setFill()
        cap.fill()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.85)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let text = "\(entry.favorite ? "★ " : "")\(entry.title)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
            .shadow: shadow
        ]
        (text as NSString).draw(in: rect.insetBy(dx: 11, dy: 5), withAttributes: attributes)
    }
}

@MainActor
final class DialogNavigator {
    private let source = CGEventSource(stateID: .hidSystemState)

    func jump(to path: String, in dialog: DetectedDialog, completion: @escaping () -> Void) {
        logger.info("开始跳转 path=\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public)")
        NSRunningApplication(processIdentifier: dialog.pid)?.activate(options: [])
        AXUIElementPerformAction(dialog.element, kAXRaiseAction as CFString)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.postKey(5, flags: [.maskCommand, .maskShift])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if !self.setFocusedTextValue(path) {
                    logger.error("AX 焦点输入框写入失败，回退逐字符输入")
                    self.type(path)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.postKey(36)
                    logger.info("跳转按键序列已发送")
                    completion()
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

    private func setFocusedTextValue(_ value: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = elementAttribute(systemWide, kAXFocusedUIElementAttribute) else { return false }
        let role = stringAttribute(focused, kAXRoleAttribute) ?? ""
        guard role == "AXTextField" || role == "AXComboBox" else {
            logger.error("AX 当前焦点不是输入框 role=\(role, privacy: .public)")
            return false
        }
        let result = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, value as CFString)
        logger.info("AX 焦点输入框写入 result=\(result.rawValue)")
        return result == .success
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
            repeat with i from 1 to count of windows
                try
                    set output to output & POSIX path of ((target of window i) as alias) & linefeed
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
