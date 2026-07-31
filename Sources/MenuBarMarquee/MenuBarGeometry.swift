import AppKit
import ApplicationServices

/// Works out which slice of the menu bar is actually dead space.
///
/// macOS gives no public API for "where do the app's menu titles end" or "where
/// does the status-item cluster begin", so the default is a pair of fixed insets
/// tuned to be safe for typical apps. `--auto-fit` upgrades the left edge to a
/// real measurement via the Accessibility API when the user has granted it.
enum MenuBarGeometry {

    /// 24pt on a normal display; the notch height (~37pt) on a notched one,
    /// which is also the menu bar height there.
    static func barHeight(for screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        return notch > 0 ? notch : NSStatusBar.system.thickness
    }

    static func stripFrame(for screen: NSScreen, config: Config) -> NSRect {
        let bar = screen.frame
        let height = barHeight(for: screen)

        var left = bar.minX + config.leftInset
        let right = bar.maxX - config.rightInset

        if config.autoFit, let menusEnd = frontmostMenuRightEdge(on: screen) {
            left = max(bar.minX + 200, menusEnd + 28)
        }

        // If the reserved zones overlap (small display, huge insets), fall back
        // to a modest centered strip rather than a negative-width window.
        var width = right - left
        if width < 160 {
            width = min(360, bar.width * 0.3)
            left = bar.midX - width / 2
        }

        return NSRect(x: left, y: bar.maxY - height, width: width, height: height)
    }

    /// Right edge of the frontmost app's last menu title, in global x.
    /// Returns nil when Accessibility permission has not been granted — the
    /// caller then keeps the static inset. Never prompts.
    static func frontmostMenuRightEdge(on screen: NSScreen) -> CGFloat? {
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
              let children = childrenRef as? [AXUIElement],
              let last = children.last else { return nil }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(last, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(last, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        // AX reports a top-left origin, but x is identical in both conventions.
        let edge = origin.x + size.width
        guard edge > screen.frame.minX, edge < screen.frame.maxX else { return nil }
        return edge
    }

    /// One-time, user-initiated permission prompt for --auto-fit.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
