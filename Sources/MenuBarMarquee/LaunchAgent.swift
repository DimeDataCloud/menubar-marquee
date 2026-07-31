import AppKit
import Foundation

/// Persistence, the boring way that always works: a per-user LaunchAgent plist.
/// No login-item API, no helper bundle, no code signature required — which
/// matters because this ships unsigned.
enum LaunchAgent {

    static let label = "cloud.dimedata.menubarmarquee"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static var executablePath: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? CommandLine.arguments[0]
    }

    static func install() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // Deliberately not KeepAlive — otherwise launchd would fight the
            // Quit menu item and relaunch us immediately.
            "ProcessType": "Interactive",
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml,
                                                          options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            NSLog("MenuBarMarquee: could not install launch agent — \(error)")
        }
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}

// Note: neither of these calls `launchctl`.
//
// `bootstrap` on a plist with RunAtLoad would immediately start a *second*
// copy of the app that is doing the bootstrapping, and `bootout` would kill
// the copy the user is currently looking at. Writing and removing the plist is
// the whole job — it takes effect at the next login, which is exactly what
// "Launch at Login" promises. install.sh is the one place that runs launchctl,
// and it kills any running copy first.
