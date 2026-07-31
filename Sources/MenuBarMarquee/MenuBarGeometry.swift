import AppKit
import ApplicationServices

/// Finds the real empty span in the menu bar. Nothing here is a guess: the left
/// boundary is the frontmost app's last menu title, the right boundary is the
/// leftmost status item, and both are measured live.
///
/// - Left  — Accessibility API (`kAXMenuBarAttribute`). Needs permission.
/// - Right — `CGWindowListCopyWindowInfo`. Status items are real windows at the
///           status window level, so their bounds are readable with no
///           permission at all.
///
/// If a boundary cannot be measured, `stripFrame` returns nil and the caller
/// hides the strip. It never falls back to an assumed inset — an assumed inset
/// is exactly the thing that overlaps somebody's menus.
enum MenuBarGeometry {

    /// How much of the result came from real measurement. The strip always
    /// shows; this just tells the truth about how it was placed.
    enum Confidence: String {
        case measured   = "measured"          // both edges read from the system
        case partial    = "partly measured"   // one edge read, one estimated
        case estimated  = "estimated"         // neither edge readable
        case pinned     = "pinned by hand"    // user set --left/--right
        case squeezed   = "squeezed"          // free span was tiny; widened to fit
    }

    struct Span {
        let frame: NSRect
        let confidence: Confidence
    }

    /// Used only when a real measurement is impossible. Deliberately generous:
    /// the Apple menu plus a typical app's titles, and the clock plus a few
    /// status items.
    private static let fallbackLeftInset: CGFloat = 300
    private static let fallbackRightInset: CGFloat = 400
    /// Never render narrower than this — below it the marquee is unreadable.
    private static let absoluteMinimumWidth: CGFloat = 90

    /// 24pt on a normal display; the notch height on a notched one, which is
    /// also the menu bar height there.
    static func barHeight(for screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        return notch > 0 ? notch : NSStatusBar.system.thickness
    }

    /// The screen that actually owns the menu bar — always the first in the
    /// list. `NSScreen.main` is the screen with the *key window*, which for an
    /// accessory app with no key window is not reliably the menu-bar screen.
    static var menuBarScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// Left edge of *our own* status item. The system placed it within the
    /// status-item cluster, so this is a dependable right-hand boundary that
    /// needs no permission and no window scanning. Set by AppDelegate once the
    /// item exists.
    static var ourStatusItemLeftEdge: CGFloat?

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    // MARK: - The measurement

    /// Always returns a frame inside the menu bar. Measures both edges when it
    /// can, estimates when it cannot, and squeezes rather than vanishing when
    /// the free span is tiny — the strip is meant to be visible at all times.
    static func stripFrame(for screen: NSScreen,
                           config: Config,
                           excludingWindowNumber ourWindow: Int) -> Span {
        let bar = screen.frame
        let height = barHeight(for: screen)
        let pad = config.padding

        var measuredLeft = false
        var measuredRight = false
        var pinned = false

        // Left: end of the frontmost app's menus.
        var left: CGFloat
        if config.leftOverride > 0 {
            left = bar.minX + config.leftOverride
            pinned = true
        } else if let menusEnd = appMenusRightEdge(on: screen) {
            left = menusEnd + pad
            measuredLeft = true
        } else {
            left = bar.minX + fallbackLeftInset
        }

        // Right: start of the status-item cluster.
        var right: CGFloat
        if config.rightOverride > 0 {
            right = bar.maxX - config.rightOverride
            pinned = true
        } else if let statusStart = statusItemsLeftEdge(on: screen, excluding: ourWindow) {
            right = statusStart - pad
            measuredRight = true
        } else {
            right = bar.maxX - fallbackRightInset
        }

        // Our own status item is a guaranteed anchor: the system placed it
        // inside the status cluster, so everything from its left edge rightward
        // is occupied. Clamp to it even when the window scan already produced a
        // number — whichever is further left is the safe one.
        if let ourItem = ourStatusItemLeftEdge {
            let safe = ourItem - pad
            if safe < right { right = safe; measuredRight = true }
        }

        // A notch physically occupies the middle of the bar, so the strip has
        // to sit entirely on one side of it. Take the wider side.
        if let notch = notchRange(on: screen), notch.overlaps(left..<right) {
            let leftWidth = max(0, min(right, notch.lowerBound) - left)
            let rightWidth = max(0, right - max(left, notch.upperBound))
            if rightWidth >= leftWidth {
                left = max(left, notch.upperBound)
            } else {
                right = min(right, notch.lowerBound)
            }
        }

        var confidence: Confidence
        switch (pinned, measuredLeft, measuredRight) {
        case (true, _, _):      confidence = .pinned
        case (_, true, true):   confidence = .measured
        case (_, false, false): confidence = .estimated
        default:                confidence = .partial
        }

        // Never disappear. If the free span came out unusably narrow, widen it
        // around its own midpoint and clamp it inside the bar — a slightly
        // overlapping strip is what was asked for over an invisible one.
        var width = right - left
        if width < absoluteMinimumWidth {
            let wanted = max(absoluteMinimumWidth, min(config.minimumWidth, bar.width * 0.5))
            let centre = width > 0 ? (left + right) / 2 : bar.midX
            left = centre - wanted / 2
            right = centre + wanted / 2
            confidence = .squeezed
        }

        // Keep it on screen no matter what the arithmetic produced.
        width = min(right - left, bar.width)
        left = min(max(left, bar.minX), bar.maxX - width)

        return Span(frame: NSRect(x: left, y: bar.maxY - height,
                                  width: width, height: height),
                    confidence: confidence)
    }

    // MARK: - Left boundary

    /// Right edge of the frontmost app's last menu title, in global x.
    static func appMenusRightEdge(on screen: NSScreen) -> CGFloat? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarValue = menuBarRef,
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarValue as! AXUIElement

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        // Walk from the end: trailing items are occasionally zero-width.
        for element in children.reversed() {
            guard let frame = axFrame(of: element), frame.width > 0 else { continue }
            let edge = frame.maxX
            guard edge > screen.frame.minX, edge < screen.frame.maxX else { return nil }
            return edge
        }
        return nil
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // AX uses a top-left origin, but x is identical in both conventions and
        // x is all this needs.
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Right boundary

    /// Left edge of the leftmost status item, in global x. No permission needed
    /// — window bounds and owner PIDs are public; only window *contents* are
    /// gated behind Screen Recording.
    static func statusItemsLeftEdge(on screen: NSScreen, excluding ourWindow: Int) -> CGFloat? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let height = barHeight(for: screen)
        var leftmost = CGFloat.greatestFiniteMagnitude

        for window in list {
            // Our own marquee panel sits at the same level; skip it. Our status
            // item is NOT skipped — we have to avoid overlapping that too.
            if let number = window[kCGWindowNumber as String] as? Int, number == ourWindow { continue }

            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= statusLayer,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            // Must actually sit in the menu bar strip. CG bounds are top-left
            // origin, so the strip is y ≈ 0.
            guard bounds.minY <= 1, bounds.height <= height + 2 else { continue }
            // A full-width window at this level is a bar, not an item.
            guard bounds.width > 0, bounds.width < screen.frame.width * 0.5 else { continue }

            leftmost = min(leftmost, bounds.minX)
        }

        return leftmost == .greatestFiniteMagnitude ? nil : leftmost
    }

    // MARK: - Notch

    /// x range physically covered by the camera housing, if there is one.
    private static func notchRange(on screen: NSScreen) -> Range<CGFloat>? {
        guard let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea,
              leftArea.maxX < rightArea.minX else { return nil }
        return leftArea.maxX..<rightArea.minX
    }

    // MARK: - Diagnostics

    /// Human-readable dump of every input the placement depends on. `--diagnose`
    /// prints this and exits, so a placement problem can be read rather than
    /// guessed at.
    static func diagnostics(for screen: NSScreen, config: Config) -> String {
        var out = ["MenuBarMarquee — placement diagnostics", String(repeating: "=", count: 38)]

        out.append("screen.frame          \(screen.frame)")
        out.append("menu bar height       \(barHeight(for: screen))")
        out.append("safeAreaInsets.top    \(screen.safeAreaInsets.top)")
        out.append("screens attached      \(NSScreen.screens.count)")
        if let notch = notchRange(on: screen) {
            out.append("notch spans x         \(notch.lowerBound) … \(notch.upperBound)")
        } else {
            out.append("notch                 none")
        }

        out.append("")
        out.append("Accessibility trusted \(AXIsProcessTrusted())")
        let front = NSWorkspace.shared.frontmostApplication
        out.append("frontmost app         \(front?.localizedName ?? "nil") (pid \(front?.processIdentifier ?? -1))")
        if let edge = appMenusRightEdge(on: screen) {
            out.append("app menus end at x    \(edge)   <- LEFT edge measured")
        } else {
            out.append("app menus end at x    UNREADABLE -> falling back to \(fallbackLeftInset)pt inset")
        }

        out.append("")
        out.append("status-level windows sitting in the menu bar strip:")
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        let height = barHeight(for: screen)
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            var rows = 0
            for window in list {
                guard let layer = window[kCGWindowLayer as String] as? Int,
                      let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                guard bounds.minY <= 1, bounds.height <= height + 2 else { continue }
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                let kept = layer >= statusLayer && bounds.width > 0
                    && bounds.width < screen.frame.width * 0.5
                out.append(String(format: "  %@ layer=%d x=%.0f w=%.0f h=%.0f  owner=%@",
                                  kept ? "USE " : "skip", layer,
                                  bounds.minX, bounds.width, bounds.height, owner))
                rows += 1
            }
            if rows == 0 { out.append("  (none reported in the bar strip)") }
        } else {
            out.append("  CGWindowListCopyWindowInfo returned nothing")
        }

        if let edge = statusItemsLeftEdge(on: screen, excluding: -1) {
            out.append("status items start at \(edge)   <- RIGHT edge measured")
        } else {
            out.append("status items start at UNREADABLE -> falling back to \(fallbackRightInset)pt inset")
        }

        let span = stripFrame(for: screen, config: config, excludingWindowNumber: -1)
        out.append("")
        out.append("RESULT  \(span.frame)")
        out.append("        width \(Int(span.frame.width))pt, confidence: \(span.confidence.rawValue)")
        return out.joined(separator: "\n")
    }

    // MARK: - Permission

    /// Prompts once, and opens the settings pane so the user is not left
    /// hunting for it. Only ever called from an explicit user action or first run.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
