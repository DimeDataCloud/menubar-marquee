import AppKit

// .accessory = no Dock icon, no app menu of our own — a background agent.
// This is the entire "install footprint": one binary, no bundle, no Info.plist.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
