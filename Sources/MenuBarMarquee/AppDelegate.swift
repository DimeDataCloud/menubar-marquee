import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config = Config()
    private var window: MarqueeBarWindow!
    private var marquee: MarqueeView!
    private var statusItem: NSStatusItem!
    private var rescanTimer: Timer?
    private var geometryTimer: Timer?
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

        guard NSScreen.main != nil else {
            NSLog("MenuBarMarquee: no screen available")
            NSApp.terminate(nil)
            return
        }

        // Start hidden and zero-sized; the first measurement decides where and
        // whether it appears.
        window = MarqueeBarWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1))
        marquee = MarqueeView(config: config)
        marquee.autoresizingMask = [.width, .height]
        window.contentView = marquee

        buildStatusItem()
        observeSystem()
        rescanApps()

        if !MenuBarGeometry.hasAccessibilityPermission {
            // The left edge is unknowable without this, and guessing it is the
            // one thing this app must not do.
            MenuBarGeometry.requestAccessibilityPermission()
        }
        reposition()

        rescanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.rescanApps()
        }
        // Menus change with the frontmost app, status items come and go, and the
        // clock changes width. Re-measure continuously; it is two cheap reads.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reposition()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        rescanTimer?.invalidate()
        geometryTimer?.invalidate()
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

    /// Re-measures the empty span and moves the strip into it. Hides the strip
    /// outright when either boundary is unknown — never falls back to a guess.
    private func reposition() {
        guard let screen = NSScreen.main else { return }

        guard let span = MenuBarGeometry.stripFrame(for: screen,
                                                    config: config,
                                                    excludingWindowNumber: window.windowNumber) else {
            if window.isVisible { window.orderOut(nil) }
            updateStatusSummary()
            return
        }

        if window.frame != span.frame {
            window.setFrame(span.frame, display: true)
        }
        if !window.isVisible { window.orderFrontRegardless() }
        updateStatusSummary()
    }

    /// Menu titles only exist a beat after an app activates, so measure late too.
    private func scheduleRemeasure() {
        autoFitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reposition() }
        autoFitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateStatusSummary() {
        guard let item = menuItem(.status) else { return }
        if !MenuBarGeometry.hasAccessibilityPermission {
            item.title = "Needs Accessibility permission"
        } else if !window.isVisible {
            item.title = "No room in the menu bar right now"
        } else {
            item.title = "Fitted to \(Int(window.frame.width))pt of free bar"
        }
        menuItem(.permission)?.isHidden = MenuBarGeometry.hasAccessibilityPermission
    }

    private func observeSystem() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRemeasure() }

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
        menuItem(.login)?.state = LaunchAgent.isInstalled ? .on : .off
    }

    // MARK: - Status item

    private enum MenuTag: Int {
        case pause = 1
        case appCount = 2
        case names = 3
        case status = 4
        case login = 5
        case permission = 6
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

        let status = NSMenuItem(title: "Measuring…", action: nil, keyEquivalent: "")
        status.tag = MenuTag.status.rawValue
        status.isEnabled = false
        menu.addItem(status)

        let permission = item("Grant Accessibility Permission…", #selector(grantPermission),
                              tag: .permission)
        permission.toolTip = "Required to find where the frontmost app's menus end."
        permission.isHidden = MenuBarGeometry.hasAccessibilityPermission
        menu.addItem(permission)
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

        menu.addItem(item("Re-measure Now", #selector(remeasureNow)))
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

    @objc private func remeasureNow() { reposition() }

    @objc private func grantPermission() {
        MenuBarGeometry.requestAccessibilityPermission()
        MenuBarGeometry.openAccessibilitySettings()
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
