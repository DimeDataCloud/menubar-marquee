import AppKit
import Foundation

struct AppEntry {
    let name: String
    let url: URL
    let icon: NSImage
}

/// Finds every installed .app the user can actually launch. No index, no
/// database, no AI — just the four directories macOS puts applications in.
enum AppScanner {

    private static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
    }

    private static var systemRoots: [URL] {
        [URL(fileURLWithPath: "/System/Applications")]
    }

    /// Blocking — call this off the main thread.
    static func scan(includeSystemApps: Bool) -> [AppEntry] {
        var searchRoots = roots
        if includeSystemApps { searchRoots += systemRoots }

        var seen = Set<String>()
        var found: [AppEntry] = []

        for root in searchRoots {
            for url in bundles(under: root, depth: 2) {
                // Dedupe on bundle id where there is one, path otherwise —
                // /Applications and ~/Applications routinely hold the same app.
                let bundle = Bundle(url: url)
                let key = bundle?.bundleIdentifier ?? url.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }
                found.append(AppEntry(name: displayName(for: url, bundle: bundle),
                                      url: url,
                                      icon: NSWorkspace.shared.icon(forFile: url.path)))
            }
        }

        return found.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Walks `root` looking for `.app` bundles, descending into plain folders
    /// (Utilities, Adobe, Microsoft…) but never into a bundle itself.
    private static func bundles(under root: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for item in items {
            if item.pathExtension == "app" {
                result.append(item)
                continue
            }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                result += bundles(under: item, depth: depth - 1)
            }
        }
        return result
    }

    private static func displayName(for url: URL, bundle: Bundle?) -> String {
        if let localized = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
           !localized.isEmpty { return localized }
        if let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty { return display }
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }
}
