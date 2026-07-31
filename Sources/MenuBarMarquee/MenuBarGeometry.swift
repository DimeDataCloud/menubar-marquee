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

    struct Span {
        let frame: NSRect
        /// Set when the user pinned an edge by hand instead of measuring.
        let manualEdges: Bool
    }

    /// 24pt on a normal display; the notch height on a notched one, which is
    /// also the menu bar height there.
    static func barHeight(for screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        return notch > 0 ? notch : NSStatusBar.system.thickness
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    // MARK: - The measurement

    static func stripFrame(for screen: NSScreen,
                           config: Config,
                           excludingWindowNumber ourWindow: Int) -> Span? {
        let bar = screen.frame
        let height = barHeight(for: screen)
        let pad = config.padding

        // Left: end of the frontmost app's menus, or a hand-pinned override.
        var left: CGFloat
        var manual = false
        if config.leftOverride > 0 {
            left = bar.minX + config.leftOverride
            manual = true
        } else if let menusEnd = appMenusRightEdge(on: screen) {
            left = menusEnd + pad
        } else {
            return nil   // no permission — refuse to guess
        }

        // Right: start of the status-item cluster, or a hand-pinned override.
        var right: CGFloat
        if config.rightOverride > 0 {
            right = bar.maxX - config.rightOverride
            manual = true
        } else if let statusStart = statusItemsLeftEdge(on: screen, excluding: ourWindow) {
            right = statusStart - pad
        } else {
            return nil
        }

        // A notch physically occupies the middle of the bar. Whatever is left
        // of the span has to sit entirely on one side of it.
        if let notch = notchRange(on: screen), notch.overlaps(left..<right) {
            let leftPiece = left..<min(right, notch.lowerBound)
            let rightPiece = max(left, notch.upperBound)..<right
            let leftWidth = max(0, leftPiece.upperBound - leftPiece.lowerBound)
            let rightWidth = max(0, rightPiece.upperBound - rightPiece.lowerBound)
            if rightWidth > leftWidth {
                left = rightPiece.lowerBound
                right = rightPiece.upperBound
            } else {
                left = leftPiece.lowerBound
                right = leftPiece.upperBound
            }
        }

        guard right - left >= config.minimumWidth else { return nil }

        return Span(frame: NSRect(x: left, y: bar.maxY - height,
                                  width: right - left, height: height),
                    manualEdges: manual)
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
