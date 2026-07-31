import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = Config()
    private var window: MarqueeBarWindow!
    private var marquee: MarqueeView!
    private var statusItem: NSStatusItem!
    private var rescanTimer: Timer?
    private var autoFitWork: DispatchWorkItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings are stored first, so `MenuBarMarquee --speed 50` works as a
        // control command even while a copy is already running.
        config.applyCommandLine()

        if isAlreadyRunning() {
            DistributedNotificationCenter.default().postNotificationName(
                Config.didChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
            // Give distnoted a turn of the run loop to hand the message over
            // before this process disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return
        }

        guard let screen = NSScreen.main else {
            NSLog("MenuBarMarquee: no screen available")
            NSApp.terminate(nil)
            return
        }

        let frame = MenuBarGeometry.stripFrame(for: screen, config: config)
        window = MarqueeBarWindow(contentRect: frame)
        marquee = MarqueeView(config: config)
        marquee.frame = NSRect(origin: .zero, size: frame.size)
        marquee.autoresizingMask = [.width, .height]
        window.contentView = marquee
        window.orderFrontRegardless()

        buildStatusItem()
        observeSystem()
        rescanApps()

        rescanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.rescanApps()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rescanTimer?.invalidate()
    }

    /// Two marquees on one menu bar would draw on top of each other, and the
    /// login item plus a manual launch is an easy way to end up with two.
    private func isAlreadyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != mine }
    }

    // MARK: - Apps

    private func rescanApps() {
        let includeSystem = config.includeSystemApps
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = AppScanner.scan(includeSystemApps: includeSystem)
            DispatchQueue.main.async {
                guard let self else { return }
                self.marquee.update(entries: entries)
                self.statusItem.menu?.item(withTag: MenuTag.appCount.rawValue)?
                    .title = "\(entries.count) apps"
            }
        }
    }

    // MARK: - Position

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        window.setFrame(MenuBarGeometry.stripFrame(for: screen, config: config), display: true)
    }

    /// Menu titles only exist a beat after an app activates, so measure late.
    private func scheduleAutoFit() {
        guard config.autoFit else { return }
        autoFitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reposition() }
        autoFitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func observeSystem() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleAutoFit() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.marquee.rebuild() }

        // A second launch carrying CLI flags stores them and pings us.
        DistributedNotificationCenter.default().addObserver(
            forName: Config.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.config.reload()
            self.syncMenuState()
            self.reposition()
            self.marquee.rebuild()
        }
    }

    private func syncMenuState() {
        menuItem(.names)?.state = config.showNames ? .on : .off
        menuItem(.autoFit)?.state = config.autoFit ? .on : .off
        menuItem(.login)?.state = LaunchAgent.isInstalled ? .on : .off
    }

    // MARK: - Status item

    private enum MenuTag: Int {
        case pause = 1
        case appCount = 2
        case names = 3
        case autoFit = 4
        case login = 5
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill",
                                          accessibilityDescription: "MenuBarMarquee")
        statusItem.button?.toolTip = "MenuBarMarquee"

        let menu = NSMenu()

        let count = NSMenuItem(title: "Scanning…", action: nil, keyEquivalent: "")
        count.tag = MenuTag.appCount.rawValue
        count.isEnabled = false
        menu.addItem(count)
        menu.addItem(.separator())

        let pause = item("Pause", #selector(togglePause), tag: .pause)
        menu.addItem(pause)
        menu.addItem(item("Rescan Apps", #selector(rescanNow)))
        menu.addItem(.separator())

        let speed = NSMenu()
        speed.addItem(item("Slow", #selector(setSlow)))
        speed.addItem(item("Normal", #selector(setNormal)))
        speed.addItem(item("Fast", #selector(setFast)))
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speed
        menu.addItem(speedItem)

        let names = item("Show App Names", #selector(toggleNames), tag: .names)
        names.state = config.showNames ? .on : .off
        menu.addItem(names)

        let autoFit = item("Auto-Fit to App Menus", #selector(toggleAutoFit), tag: .autoFit)
        autoFit.state = config.autoFit ? .on : .off
        autoFit.toolTip = "Measure the frontmost app's menu titles and start the strip after them. Requires Accessibility permission."
        menu.addItem(autoFit)
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin), tag: .login)
        login.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit MenuBarMarquee",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, tag: MenuTag? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        if let tag { menuItem.tag = tag.rawValue }
        return menuItem
    }

    private func menuItem(_ tag: MenuTag) -> NSMenuItem? {
        statusItem.menu?.items.first { $0.tag == tag.rawValue }
    }

    // MARK: - Actions

    @objc private func togglePause() {
        marquee.setManuallyPaused(!marquee.manuallyPaused)
        menuItem(.pause)?.title = marquee.manuallyPaused ? "Resume" : "Pause"
    }

    @objc private func rescanNow() { rescanApps() }

    @objc private func setSlow() { setSpeed(20) }
    @objc private func setNormal() { setSpeed(34) }
    @objc private func setFast() { setSpeed(55) }

    private func setSpeed(_ value: CGFloat) {
        config.speed = value
        marquee.rebuild()
    }

    @objc private func toggleNames() {
        config.showNames.toggle()
        menuItem(.names)?.state = config.showNames ? .on : .off
        marquee.rebuild()
    }

    @objc private func toggleAutoFit() {
        config.autoFit.toggle()
        menuItem(.autoFit)?.state = config.autoFit ? .on : .off
        if config.autoFit && !AXIsProcessTrusted() {
            MenuBarGeometry.requestAccessibilityPermission()
        }
        reposition()
    }

    @objc private func toggleLaunchAtLogin() {
        if LaunchAgent.isInstalled {
            LaunchAgent.uninstall()
        } else {
            LaunchAgent.install()
        }
        menuItem(.login)?.state = LaunchAgent.isInstalled ? .on : .off
    }
}
