# Menu Bar Marquee

Every app you have installed, scrolling in a seamless loop through the dead
space in the middle of your macOS menu bar. Click one to launch it.

No account, no AI, no dependencies, no subscription. Download, run `install.sh`,
done. It starts itself at login and stays out of the way.

---

## Install

**Option A — the download (no developer tools needed)**

1. Grab `MenuBarMarquee.zip` from [Releases](../../releases) and unzip it.
2. `cd` into the folder and run:

   ```bash
   ./install.sh
   ```

**Option B — from source** (needs Xcode Command Line Tools, `xcode-select --install`)

```bash
git clone <this repo>
cd menubar-marquee
./install.sh          # builds, then installs
```

Requires macOS 13 (Ventura) or later. Universal — Apple silicon and Intel.

**Uninstall:** `./uninstall.sh`. It removes the app, the login item, and the
saved settings. Nothing is left behind.

---

## How it works

The animation is the standard seamless-marquee trick: the app list is laid out
end to end, duplicated, and the whole track is translated left by exactly one
copy width on a linear infinite loop. Because copy two is identical to copy one,
the wrap point is invisible — there is no jump cut to hide.

The translation runs as a `CABasicAnimation` on `transform.translation.x`, which
means the render server animates it and this process burns effectively no CPU
while it scrolls. That is the whole reason it is safe to leave running all day.

App discovery is a plain directory walk of `/Applications`,
`~/Applications`, and `/System/Applications` (two levels deep, so `Utilities`
and vendor folders are included), re-run every 5 minutes and on demand.

---

## The one honest caveat

**No app can draw inside the real menu bar.** That surface belongs to the window
server, and Apple exposes no API for putting arbitrary content in it. Apps that
appear to do this (SketchyBar, Übersicht bars) actually hide the system menu bar
and replace it wholesale, which costs you every app's File/Edit menus.

This does the opposite. It is a borderless, non-activating window sitting one
level above the menu bar, spanning only the empty centre strip. Visually it
reads as part of the bar. Functionally, every app menu and every status item
keeps working, untouched.

The consequence: the app has to guess where the dead space starts and ends.
Defaults reserve 340pt on the left for menu titles and 430pt on the right for
status items. If an app with a lot of menus (Xcode, Photoshop) runs into the
strip, you have two fixes:

- **Auto-Fit to App Menus** in the status menu — measures the frontmost app's
  menu titles for real and starts the strip after them. Needs a one-time
  Accessibility permission grant, and it is off by default so nothing prompts
  you unasked.
- **Fixed gaps** — run the binary once with `--left` / `--right`; the values are
  saved.

---

## Settings

Click the grid icon in your menu bar: pause, rescan, speed, app names on/off,
auto-fit, launch at login, quit.

Everything is also a flag. Values persist, so run it once and quit:

```
--speed <pts/sec>     scroll speed          (default 34)
--icon-size <pt>      app icon size         (default 17)
--spacing <pt>        gap between items     (default 26)
--font-size <pt>      app name size         (default 11)
--names | --no-names  show app names        (default on)
--left <pt>           space reserved for app menu titles  (default 340)
--right <pt>          space reserved for status items     (default 430)
--auto-fit            measure app menus via Accessibility (default off)
--fade <pt>           edge fade width       (default 44)
--opacity <0-1>       strip opacity         (default 0.85)
--no-hover-pause      keep scrolling under the cursor
--no-system-apps      skip /System/Applications
--reset               clear all saved settings
```

It also respects **Reduce Motion** — if that is on in Accessibility settings,
the strip renders but does not scroll.

---

## Notes

- The app is **ad-hoc signed, not notarized.** `install.sh` strips the download
  quarantine flag for you. If you move the `.app` by hand instead, macOS will
  refuse to open it until you run
  `xattr -dr com.apple.quarantine ~/Applications/MenuBarMarquee.app`.
- Persistence is a per-user LaunchAgent at
  `~/Library/LaunchAgents/cloud.dimedata.menubarmarquee.plist`. No helper tool,
  no admin password, nothing installed system-wide.
- Multi-monitor: the strip lives on the screen with the menu bar and follows it
  when the display arrangement changes.

## Layout

```
Package.swift
Sources/MenuBarMarquee/
  main.swift              entry point — accessory app, no Dock icon
  AppDelegate.swift       wiring, status menu, rescan timer, observers
  Config.swift            settings (UserDefaults + CLI flags)
  AppScanner.swift        finds installed apps
  MarqueeView.swift       the marquee — layout, Core Animation loop, hit testing
  MarqueeBarWindow.swift  the borderless above-the-menu-bar panel
  MenuBarGeometry.swift   where the dead space is (insets, optional AX auto-fit)
  LaunchAgent.swift       login-item install/remove
build.sh / install.sh / uninstall.sh
```
