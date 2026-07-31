// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuBarMarquee",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MenuBarMarquee",
            path: "Sources/MenuBarMarquee"
        )
    ]
)
