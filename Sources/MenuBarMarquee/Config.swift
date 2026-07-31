import AppKit
import Foundation

/// Every tunable lives here, backed by UserDefaults so the status-menu toggles
/// survive a relaunch. CLI flags override the stored value for one run.
final class Config {

    static let suite = "cloud.dimedata.menubarmarquee"

    private let d: UserDefaults

    init() {
        d = UserDefaults(suiteName: Config.suite) ?? .standard
        d.register(defaults: [
            K.speed: 34.0,            // points per second
            K.iconSize: 17.0,
            K.spacing: 26.0,
            K.showNames: true,
            K.fontSize: 11.0,
            // 0 = measure it. Anything else is a hand-pinned override.
            K.leftOverride: 0.0,
            K.rightOverride: 0.0,
            K.padding: 16.0,          // clearance from the menus / status items
            K.minimumWidth: 120.0,    // below this the strip is not worth showing
            K.fadeWidth: 44.0,
            K.pauseOnHover: true,
            K.opacity: 0.85,
            K.includeSystemApps: true,
        ])
    }

    private enum K {
        static let speed = "speed"
        static let iconSize = "iconSize"
        static let spacing = "spacing"
        static let showNames = "showNames"
        static let fontSize = "fontSize"
        static let leftOverride = "leftOverride"
        static let rightOverride = "rightOverride"
        static let padding = "padding"
        static let minimumWidth = "minimumWidth"
        static let fadeWidth = "fadeWidth"
        static let pauseOnHover = "pauseOnHover"
        static let opacity = "opacity"
        static let includeSystemApps = "includeSystemApps"
    }

    /// Pull in writes made by another process — a second launch with CLI flags
    /// stores its settings and then tells the running instance to re-read.
    func reload() {
        CFPreferencesAppSynchronize(Config.suite as CFString)
    }

    static let didChangeNotification = Notification.Name("\(Config.suite).didChange")

    private func f(_ key: String) -> CGFloat { CGFloat(d.double(forKey: key)) }
    private func set(_ v: CGFloat, _ key: String) { d.set(Double(v), forKey: key) }

    var speed: CGFloat { get { max(4, f(K.speed)) } set { set(newValue, K.speed) } }
    var iconSize: CGFloat { get { f(K.iconSize) } set { set(newValue, K.iconSize) } }
    var spacing: CGFloat { get { f(K.spacing) } set { set(newValue, K.spacing) } }
    var fontSize: CGFloat { get { f(K.fontSize) } set { set(newValue, K.fontSize) } }
    var leftOverride: CGFloat { get { f(K.leftOverride) } set { set(newValue, K.leftOverride) } }
    var rightOverride: CGFloat { get { f(K.rightOverride) } set { set(newValue, K.rightOverride) } }
    var padding: CGFloat { get { f(K.padding) } set { set(newValue, K.padding) } }
    var minimumWidth: CGFloat { get { f(K.minimumWidth) } set { set(newValue, K.minimumWidth) } }
    var fadeWidth: CGFloat { get { f(K.fadeWidth) } set { set(newValue, K.fadeWidth) } }
    var opacity: CGFloat { get { min(1, max(0.1, f(K.opacity))) } set { set(newValue, K.opacity) } }

    var showNames: Bool { get { d.bool(forKey: K.showNames) } set { d.set(newValue, forKey: K.showNames) } }
    var pauseOnHover: Bool { get { d.bool(forKey: K.pauseOnHover) } set { d.set(newValue, forKey: K.pauseOnHover) } }
    var includeSystemApps: Bool { get { d.bool(forKey: K.includeSystemApps) } set { d.set(newValue, forKey: K.includeSystemApps) } }

    /// `--flag value` / `--no-flag` overrides, applied on top of the stored values.
    func applyCommandLine(_ args: [String] = Array(CommandLine.arguments.dropFirst())) {
        var i = 0
        func next() -> CGFloat? {
            guard i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        while i < args.count {
            switch args[i] {
            case "--reset":
                for key in [K.speed, K.iconSize, K.spacing, K.showNames, K.fontSize, K.leftOverride,
                            K.rightOverride, K.padding, K.minimumWidth, K.fadeWidth, K.pauseOnHover,
                            K.opacity, K.includeSystemApps] {
                    d.removeObject(forKey: key)
                }
            case "--speed":       if let v = next() { speed = v }
            case "--icon-size":   if let v = next() { iconSize = v }
            case "--spacing":     if let v = next() { spacing = v }
            case "--font-size":   if let v = next() { fontSize = v }
            case "--left":        if let v = next() { leftOverride = v }
            case "--right":       if let v = next() { rightOverride = v }
            case "--auto-edges":  leftOverride = 0; rightOverride = 0
            case "--padding":     if let v = next() { padding = v }
            case "--fade":        if let v = next() { fadeWidth = v }
            case "--opacity":     if let v = next() { opacity = v }
            case "--names":       showNames = true
            case "--no-names":    showNames = false
            case "--hover-pause": pauseOnHover = true
            case "--no-hover-pause": pauseOnHover = false
            case "--no-system-apps": includeSystemApps = false
            case "--help", "-h":
                print(Config.usage)
                exit(0)
            default:
                break
            }
            i += 1
        }
    }

    static let usage = """
    MenuBarMarquee — a seamless scrolling strip of every app you have installed,
    filling the measured empty span in the middle of the macOS menu bar.

    The strip's edges are measured, not assumed: the left edge is the frontmost
    app's last menu title (Accessibility API), the right edge is the leftmost
    status item (window list). If either cannot be measured the strip hides
    rather than risk overlapping something.

    Usage: MenuBarMarquee [options]

      --speed <pts/sec>     scroll speed          (default 34)
      --icon-size <pt>      app icon size         (default 17)
      --spacing <pt>        gap between items     (default 26)
      --font-size <pt>      app name size         (default 11)
      --names | --no-names  show app names        (default on)
      --padding <pt>        clearance from the menus and status items (default 16)
      --left <pt>           PIN the left edge this far from the screen edge,
                            skipping measurement (default 0 = measure)
      --right <pt>          PIN the right edge this far from the screen edge
                            (default 0 = measure)
      --auto-edges          drop both pins and go back to measuring
      --fade <pt>           edge fade width       (default 44)
      --opacity <0-1>       strip opacity         (default 0.85)
      --no-hover-pause      keep scrolling under the cursor
      --no-system-apps      skip /System/Applications
      --reset               clear all saved settings
    """
}
