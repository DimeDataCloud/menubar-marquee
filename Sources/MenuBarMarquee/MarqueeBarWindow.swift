import AppKit

/// A borderless, non-activating panel that sits one level above the system menu
/// bar and spans only the dead centre of it.
///
/// No app can draw *into* the real menu bar — that surface belongs to the window
/// server — so the marquee is layered over the empty middle instead. The visible
/// result is the same; the difference is that every app's File/Edit menus and
/// every status item keep working untouched.
final class MarqueeBarWindow: NSPanel {

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false

        // One above the menu bar. Deliberately not CGShieldingWindowLevel —
        // system alerts and the screen saver must still be able to cover us.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)

        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Keep it out of window lists, screenshots of "windows", and Exposé.
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
    }

    // Declaring a designated init above stops NSWindow's from being inherited,
    // and NSResponder's coder init is `required`.
    required init?(coder: NSCoder) { fatalError("not used") }

    // A menu-bar strip must never steal focus from the app the user is in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
