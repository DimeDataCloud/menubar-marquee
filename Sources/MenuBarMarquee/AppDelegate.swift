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

    /// Menu titles only exist a beat after an app activates, so measure late too.
    private func scheduleRemeasure() {
        autoFitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reposition() }
        autoFitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
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
        let barWidth = Double(MenuBarGeometry.menuBarScreen?.frame.width ?? 1440)
        let placement = NSMenu()
        placement.addItem(sliderRow("Left edge", range: 0...(barWidth * 0.6),
                                    value: Double(currentLeftInset()),
                                    slider: .leftEdge, format: pt))
        placement.addItem(sliderRow("Right edge", range: 0...(barWidth * 0.6),
                                    value: Double(currentRightInset()),
                                    slider: .rightEdge, format: pt))
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

    /// The sliders show where the strip actually is, whether that came from a
    /// pin or from measurement.
    private func currentLeftInset() -> CGFloat {
        if config.leftOverride > 0 { return config.leftOverride }
        guard let bar = MenuBarGeometry.menuBarScreen?.frame, window != nil else { return 300 }
        return max(0, window.frame.minX - bar.minX)
    }

    private func currentRightInset() -> CGFloat {
        if config.rightOverride > 0 { return config.rightOverride }
        guard let bar = MenuBarGeometry.menuBarScreen?.frame, window != nil else { return 400 }
        return max(0, bar.maxX - window.frame.maxX)
    }

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

    private func pinCurrentFrame(leftDelta: CGFloat, rightDelta: CGFloat) {
        guard let screen = MenuBarGeometry.menuBarScreen else { return }
        let bar = screen.frame
        let f = window.frame

        var newLeft = (f.minX - bar.minX) + leftDelta
        var newRight = (bar.maxX - f.maxX) + rightDelta

        // Keep at least a usable sliver, and stay on screen.
        newLeft = max(0, newLeft)
        newRight = max(0, newRight)
        if bar.width - newLeft - newRight < 60 { return }

        config.leftOverride = newLeft
        config.rightOverride = newRight
        reposition()
    }

    @objc private func moveLeft()   { pinCurrentFrame(leftDelta: -Self.step, rightDelta: Self.step) }
    @objc private func moveRight()  { pinCurrentFrame(leftDelta: Self.step, rightDelta: -Self.step) }

    @objc private func resetPlacement() {
        config.leftOverride = 0
        config.rightOverride = 0
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
            config.iconSize = CGFloat(v);  marquee.rebuild()
        case .spacing:
            config.spacing = CGFloat(v);   marquee.rebuild()
        case .fontSize:
            config.fontSize = CGFloat(v);  marquee.rebuild()
        case .speed:
            config.speed = CGFloat(v);     marquee.rebuild()
        case .opacity:
            config.opacity = CGFloat(v);   marquee.rebuild()
        case .leftEdge:
            config.leftOverride = max(1, CGFloat(v)); reposition()
        case .rightEdge:
            config.rightOverride = max(1, CGFloat(v)); reposition()
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

    /// Icons are clamped to the bar: bigger than the bar is tall just crops.
    private var maxIconSize: CGFloat {
        guard let screen = MenuBarGeometry.menuBarScreen else { return 22 }
        return max(10, MenuBarGeometry.barHeight(for: screen) - 4)
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
