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
    private var lastConfidence: MenuBarGeometry.Confidence = .estimated

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings are stored first, so `MenuBarMarquee --speed 50` works as a
        // control command even while a copy is already running.
        config.applyCommandLine()

        guard let screen = MenuBarGeometry.menuBarScreen else {
            NSLog("MenuBarMarquee: no screen available")
            NSApp.terminate(nil)
            return
        }

        // Before the single-instance guard: the whole point of --diagnose is to
        // interrogate a machine where a copy is already running.
        if CommandLine.arguments.contains("--diagnose") {
            print(MenuBarGeometry.diagnostics(for: screen, config: config))
            exit(0)
        }

        if isAlreadyRunning() {
            DistributedNotificationCenter.default().postNotificationName(
                Config.didChangeNotification, object: nil, userInfo: nil, deliverImmediately: true)
            // Give distnoted a turn of the run loop to hand the message over
            // before this process disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return
        }

        // Sized on the first measurement, which happens a few lines down.
        window = MarqueeBarWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1))
        marquee = MarqueeView(config: config)
        marquee.autoresizingMask = [.width, .height]
        window.contentView = marquee

        buildStatusItem()
        observeSystem()
        rescanApps()

        // Asking improves placement — the strip shows either way.
        if !MenuBarGeometry.hasAccessibilityPermission && config.leftOverride <= 0 {
            MenuBarGeometry.requestAccessibilityPermission()
        }
        reposition()

        rescanTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.rescanApps()
        }
        // The left edge tracks the frontmost app's menu titles, which also
        // change *within* an app (Safari gains menus with a page loaded, an
        // app's own menu widens when its window title changes). Polling covers
        // those; the activation hook covers app switches immediately.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

    /// Re-measures the free span and moves the strip into it. Always shows the
    /// strip, using whatever room the menu bar has — measured when possible,
    /// estimated otherwise, never hidden.
    private func reposition() {
        guard let screen = MenuBarGeometry.menuBarScreen else { return }

        // Publish our own status item's position first — it is the most
        // reliable right-hand boundary available.
        MenuBarGeometry.ourStatusItemLeftEdge = statusItem?.button?.window?.frame.minX

        let span = MenuBarGeometry.stripFrame(for: screen,
                                              config: config,
                                              excludingWindowNumber: window.windowNumber)
        lastConfidence = span.confidence

        if window.frame != span.frame {
            window.setFrame(span.frame, display: true)
        }
        if !window.isVisible { window.orderFrontRegardless() }
        updateStatusSummary()
    }

    /// An app's menu titles are not in place the instant it activates, so
    /// measure immediately *and* again once they have settled.
    private func scheduleRemeasure() {
        reposition()
        autoFitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reposition() }
        autoFitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func updateStatusSummary() {
        guard let item = menuItem(.status) else { return }
        item.title = "\(Int(window.frame.width))pt wide — \(lastConfidence.rawValue)"

        // Say plainly whether the permission is live. An ad-hoc signed app loses
        // its Accessibility grant every time the binary changes, so the checkbox
        // in System Settings can look ON while the permission is actually dead —
        // which silently degrades placement to an estimate.
        let trusted = MenuBarGeometry.hasAccessibilityPermission
        menuItem(.permission)?.isHidden = trusted || config.leftOverride > 0
        menuItem(.permission)?.title = "⚠︎ Accessibility is OFF — fix placement…"
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

        let pt: (Double) -> String = { "\(Int($0.rounded()))pt" }

        // Appearance — drag bars, live.
        let appearance = NSMenu()
        appearance.addItem(sliderRow("Icon size", range: 10...maxIconSize,
                                     value: Double(config.iconSize),
                                     slider: .iconSize, format: pt))
        appearance.addItem(sliderRow("Gap between apps", range: 4...160,
                                     value: Double(config.spacing),
                                     slider: .spacing, format: pt))
        appearance.addItem(sliderRow("Name text size", range: 7...18,
                                     value: Double(config.fontSize),
                                     slider: .fontSize, format: pt))
        appearance.addItem(sliderRow("Scroll speed", range: 5...120,
                                     value: Double(config.speed),
                                     slider: .speed, format: { "\(Int($0.rounded())) pt/s" }))
        appearance.addItem(sliderRow("Opacity", range: 0.1...1.0,
                                     value: Double(config.opacity),
                                     slider: .opacity,
                                     format: { "\(Int(($0 * 100).rounded()))%" }))
        appearance.addItem(.separator())
        let names = item("Show App Names", #selector(toggleNames), tag: .names)
        names.state = config.showNames ? .on : .off
        appearance.addItem(names)
        appearance.addItem(item("Reset Appearance", #selector(resetAppearance)))
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        menu.addItem(appearanceItem)

        // Size & position — drag bars for each edge, for when measurement is
        // wrong on a given Mac.
        let placement = NSMenu()
        let gap: (Double) -> String = { $0 < 0 ? "\(Int($0.rounded()))pt (tighter)"
                                              : "+\(Int($0.rounded()))pt" }
        placement.addItem(sliderRow("Gap after the app's menus", range: -60...300,
                                    value: Double(config.leftOffset),
                                    slider: .leftEdge, format: gap))
        placement.addItem(sliderRow("Gap before the status icons", range: -60...300,
                                    value: Double(config.rightOffset),
                                    slider: .rightEdge, format: gap))
        placement.addItem(.separator())
        placement.addItem(item("Slide Left", #selector(moveLeft)))
        placement.addItem(item("Slide Right", #selector(moveRight)))
        placement.addItem(.separator())
        placement.addItem(item("Re-measure Automatically", #selector(resetPlacement)))
        placement.addItem(item("Re-measure Now", #selector(remeasureNow)))
        let placementItem = NSMenuItem(title: "Size & Position", action: nil, keyEquivalent: "")
        placementItem.submenu = placement
        menu.addItem(placementItem)
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

    /// Recursive: several tagged items now live inside submenus, and a
    /// top-level-only search would silently stop updating them.
    private func menuItem(_ tag: MenuTag) -> NSMenuItem? {
        func search(_ menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for entry in menu.items {
                if entry.tag == tag.rawValue { return entry }
                if let hit = search(entry.submenu) { return hit }
            }
            return nil
        }
        return search(statusItem?.menu)
    }

    // MARK: - Actions

    @objc private func togglePause() {
        marquee.setManuallyPaused(!marquee.manuallyPaused)
        menuItem(.pause)?.title = marquee.manuallyPaused ? "Resume" : "Pause"
    }

    @objc private func rescanNow() { rescanApps() }

    @objc private func toggleNames() {
        config.showNames.toggle()
        menuItem(.names)?.state = config.showNames ? .on : .off
        marquee.rebuild()
    }

    @objc private func remeasureNow() { reposition() }

    // MARK: - Manual placement
    //
    // Measurement can be wrong on a given Mac, so these give direct control.
    // The first nudge converts the current frame into explicit pins, which is
    // predictable: from then on the strip stays exactly where it was put.

    private static let step: CGFloat = 24

    /// Slides the whole strip while keeping both edges tracking — the width
    /// is unchanged, only where it sits within the free span.
    private func slide(by delta: CGFloat) {
        config.leftOverride = 0
        config.rightOverride = 0
        config.leftOffset += delta
        config.rightOffset -= delta
        reposition()
    }

    @objc private func moveLeft()  { slide(by: -Self.step) }
    @objc private func moveRight() { slide(by:  Self.step) }

    @objc private func resetPlacement() {
        config.leftOverride = 0
        config.rightOverride = 0
        config.leftOffset = 0
        config.rightOffset = 0
        reposition()
    }

    // MARK: - Slider rows
    //
    // NSMenuItem accepts a custom view, so these are real drag bars living
    // inside the dropdown. The menu stays open while dragging and the marquee
    // updates live on every value change.

    private enum Slider: Int {
        case iconSize = 1000, spacing, fontSize, speed, opacity, leftEdge, rightEdge
    }

    private var sliderLabels: [Int: NSTextField] = [:]

    private func sliderRow(_ title: String,
                           range: ClosedRange<Double>,
                           value: Double,
                           slider tag: Slider,
                           format: @escaping (Double) -> String) -> NSMenuItem {
        let width: CGFloat = 250
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 44))

        let label = NSTextField(labelWithString: "\(title)  \(format(value))")
        label.frame = NSRect(x: 16, y: 24, width: width - 32, height: 15)
        label.font = .menuFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)
        sliderLabels[tag.rawValue] = label
        sliderTitles[tag.rawValue] = title
        sliderFormats[tag.rawValue] = format

        let bar = NSSlider(value: value,
                           minValue: range.lowerBound,
                           maxValue: range.upperBound,
                           target: self,
                           action: #selector(sliderChanged(_:)))
        bar.frame = NSRect(x: 14, y: 2, width: width - 28, height: 20)
        bar.isContinuous = true
        bar.controlSize = .small
        bar.tag = tag.rawValue
        container.addSubview(bar)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private var sliderTitles: [Int: String] = [:]
    private var sliderFormats: [Int: (Double) -> String] = [:]

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = sender.doubleValue

        switch Slider(rawValue: sender.tag) {
        case .iconSize:
            applyIconSize(CGFloat(v))
        case .spacing:
            config.spacing = CGFloat(v);   marquee.rebuild()
        case .fontSize:
            config.fontSize = CGFloat(v);  marquee.rebuild()
        case .speed:
            config.speed = CGFloat(v);     marquee.rebuild()
        case .opacity:
            config.opacity = CGFloat(v);   marquee.rebuild()
        case .leftEdge:
            // Clearing the pin is deliberate: adjusting the gap must not stop
            // the edge from following the frontmost app's menus.
            config.leftOverride = 0
            config.leftOffset = CGFloat(v)
            reposition()
        case .rightEdge:
            config.rightOverride = 0
            config.rightOffset = CGFloat(v)
            reposition()
        case .none:
            return
        }

        if let label = sliderLabels[sender.tag],
           let title = sliderTitles[sender.tag],
           let format = sliderFormats[sender.tag] {
            label.stringValue = "\(title)  \(format(v))"
        }
    }

    // MARK: - Icon size and spacing

    /// Icons may exceed the menu bar's height — the strip then hangs below the
    /// bar to fit them. Capped well short of absurd so the overhang stays a
    /// strip rather than a curtain.
    private var maxIconSize: CGFloat { 72 }

    /// Height changed, so the window has to be resized, not just redrawn.
    private func applyIconSize(_ value: CGFloat) {
        config.iconSize = value
        reposition()
        marquee.rebuild()
    }





    @objc private func resetAppearance() {
        config.iconSize = 17
        config.spacing = 26
        config.fontSize = 11
        marquee.rebuild()
    }



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
