<div align="center">

# Menu Bar Marquee

Every installed app, scrolling in a seamless loop through the free space in the macOS menu bar. Click one to launch it.

[![Build release](https://github.com/DimeDataCloud/menubar-marquee/actions/workflows/release.yml/badge.svg)](https://github.com/DimeDataCloud/menubar-marquee/actions/workflows/release.yml)

</div>

No account, no AI, no dependencies, no subscription. Download the zip, run `install.sh`, and it starts itself at login and stays out of the way.

## Features

- Scrolls every app found in `/Applications`, `~/Applications` and `/System/Applications`, including the apps inside folders such as `Utilities`.
- Click an app to launch it.
- Measures the free space in the menu bar live, so the strip resizes when you switch apps or add status items.
- Pauses under the cursor on hover, so you can click what you want.
- Respects Reduce Motion: the strip renders but does not scroll.
- Settings from the status menu (grid icon) or from the command line. Values persist between runs.
- Runs as an agent app: no Dock icon, no app switcher entry.
- Installs and uninstalls cleanly. Uninstall removes the app, the login item and the saved settings.

## Who it is for

Mac users who want a quick launcher for installed apps in the empty part of the menu bar, without installing a launcher or signing up for anything.

## Requirements

- macOS 13 (Ventura) or later.
- Apple silicon or Intel. The prebuilt app is universal.
- Accessibility permission (see [Why it needs Accessibility permission](#why-it-needs-accessibility-permission)).
- Xcode Command Line Tools only if you build from source.

## Install

1. Download [MenuBarMarquee.zip](../../releases/latest) and unzip it.
2. Open Terminal, drag the unzipped folder onto the window, then run:

   ```bash
   ./install.sh
   ```

3. Approve the Accessibility prompt when it appears.

The app is prebuilt, so nothing needs to be compiled and no developer tools are required.

**Uninstall:** run `./uninstall.sh` from the same folder.

<details>
<summary>Building from source instead</summary>

Needs the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/DimeDataCloud/menubar-marquee
cd menubar-marquee
./install.sh          # builds with build.sh, then installs
```

`build.sh` tries a universal (arm64 and x86_64) build first and falls back to the host architecture when the full Xcode SDK is not available. It writes `build/MenuBarMarquee.app`.

</details>

## How it works

The scroll is the standard seamless-marquee technique. The app list is laid out end to end and duplicated, and the whole track moves left by exactly one copy width on a linear, infinite loop. Because the second copy is identical to the first, the wrap point is invisible.

The movement is a `CABasicAnimation` on `transform.translation.x`, so the render server animates it and the process uses almost no CPU while the strip scrolls.

App discovery walks the three application folders two levels deep. It runs every 5 minutes and on demand from the menu.

### The strip measures the free space

Both edges of the strip are read from the live system twice a second and on every app switch:

| Edge | Measured from | Permission |
|---|---|---|
| Left | The frontmost app's last menu title | Accessibility |
| Right | The leftmost status item | None (window bounds are public) |

The strip fills the space between the two edges, minus 16 pt of clearance on each side. Switching from Finder to Xcode shrinks the strip to fit Xcode's longer menu bar. Adding a status item pushes the strip's right edge back.

If either edge cannot be measured, the strip hides. It does not fall back to an assumed inset, because an assumed inset can end up on top of another app's menus.

On a notched MacBook the notch splits the free space in two, and the strip uses the wider side.

### Why it needs Accessibility permission

macOS only reveals where another app's menus end through the Accessibility API. Without the permission the app cannot tell which space is free, so it stays hidden. It reads one value, the right edge of the last menu title. It does not read menu contents, keystrokes or anything else.

If you prefer not to grant the permission, pin the edges by hand:

```bash
~/Applications/MenuBarMarquee.app/Contents/MacOS/MenuBarMarquee --left 420 --right 460
```

`--auto-edges` removes the pins and returns to measuring.

### Limitation

No app can draw inside the system menu bar, because Apple provides no API for placing arbitrary content there. Tools that appear to do this (for example SketchyBar or Ubersicht bars) hide the system menu bar and replace it, which removes the File and Edit menus of every app.

Menu Bar Marquee takes the other approach. It uses a borderless, non-activating window one level above the menu bar, sized to the measured empty span. It looks like part of the bar, and every app menu and status item keeps working unchanged.

## Configuration

Open the grid icon in the menu bar to see how much free space was found ("Fitted to 512pt of free bar") and to pause, rescan, re-measure, change the speed, toggle app names and launch at login, or quit.

Every setting is also a command-line flag. If an instance is already running, a flag applies to it live.

| Flag | Meaning | Default |
|---|---|---|
| `--speed <pts/sec>` | Scroll speed | `34` |
| `--icon-size <pt>` | App icon size | `17` |
| `--spacing <pt>` | Gap between items | `26` |
| `--font-size <pt>` | App name size | `11` |
| `--names` / `--no-names` | Show or hide app names | on |
| `--padding <pt>` | Clearance from menus and status items | `16` |
| `--left <pt>` | Pin the left edge (`0` = measure) | measure |
| `--right <pt>` | Pin the right edge (`0` = measure) | measure |
| `--auto-edges` | Drop both pins and measure again | |
| `--fade <pt>` | Width of the edge fade | `44` |
| `--opacity <0-1>` | Strip opacity | `0.85` |
| `--no-hover-pause` | Keep scrolling under the cursor | pause on hover |
| `--no-system-apps` | Skip `/System/Applications` | include |
| `--diagnose` | Print the placement inputs (screen and measured edges) and exit | |
| `--reset` | Clear all saved settings | |

Settings are stored in the `cloud.dimedata.menubarmarquee` defaults domain.

## Notes

- The app is ad-hoc signed, not notarized. `install.sh` removes the download quarantine flag for you. If you move the `.app` by hand, macOS may refuse to open it until you run `xattr -dr com.apple.quarantine ~/Applications/MenuBarMarquee.app`.
- Autostart is a per-user LaunchAgent at `~/Library/LaunchAgents/cloud.dimedata.menubarmarquee.plist`. It needs no helper tool and no administrator password, and nothing is installed system-wide.
- Multiple displays: the strip lives on the screen that has the menu bar and follows it when the display arrangement changes.

## Project structure

```
Package.swift
Sources/MenuBarMarquee/
  main.swift              entry point, accessory app with no Dock icon
  AppDelegate.swift       wiring, status menu, rescan timer, observers
  Config.swift            settings (UserDefaults and command-line flags)
  AppScanner.swift        finds installed apps
  MenuBarGeometry.swift   measures the free span (Accessibility and window list)
  MarqueeView.swift       the marquee: layout, Core Animation loop, hit testing
  MarqueeBarWindow.swift  the borderless panel above the menu bar
  LaunchAgent.swift       login item install and removal
build.sh                  builds build/MenuBarMarquee.app
install.sh                installs the app and the login item
uninstall.sh              removes the app, the login item and the settings
.github/workflows/release.yml   builds the universal app and publishes the release
```

## Tech stack

- Swift 5.9 (Swift Package Manager, tools version 5.9), AppKit and Core Animation
- Accessibility API (`AXUIElement`) for the menu bar measurement
- Shell scripts for build, install and uninstall
- GitHub Actions on `macos-14` for the release build

## Testing

The repository has no automated unit tests. The release workflow verifies that the built binary contains both `x86_64` and `arm64` slices, that the bundle's `Info.plist` sets `LSUIElement`, and that the code signature is valid. For a runtime check, run `MenuBarMarquee --diagnose` and compare the reported geometry with the menu bar.

## Releases

Every green build on `main` refreshes the rolling `latest` release, which is the stable download link used above. Tagged `v*` builds are published as versioned releases.

## Contributing

This is a small public project maintained by Dime Data. Bug reports and suggestions are welcome as GitHub issues.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 Dime Data.

---

Built and maintained by **[Dime Data](https://dimedata.cloud)**, a web and automation studio in Nashville, Tennessee. We publish the tools we make for our own work.

[dimedata.cloud](https://dimedata.cloud) · [What we've built](https://dimedata.cloud/what-we-built/) · help@dimedata.cloud
