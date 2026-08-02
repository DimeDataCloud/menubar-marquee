# Menu Bar Marquee

Every app you have installed, scrolling in a seamless loop through the dead
space in the middle of your macOS menu bar. Click one to launch it.

No account, no AI, no dependencies, no subscription. Download, run `install.sh`,
done. It starts itself at login and stays out of the way.

---

## Install — no Xcode, no developer tools

1. Download **[MenuBarMarquee.zip](../../releases/latest)** and unzip it.
2. Open Terminal, drag the unzipped folder onto it, then run:

   ```bash
   ./install.sh
   ```

3. Approve the Accessibility prompt when it appears (see below for why).

That's it. The app is prebuilt and universal — Apple silicon and Intel, macOS 13
(Ventura) or later. Nothing to compile, nothing else to download.

**Uninstall:** `./uninstall.sh`. Removes the app, the login item, and the saved
settings. Nothing left behind.

<details>
<summary>Building from source instead</summary>

Needs Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/DimeDataCloud/menubar-marquee
cd menubar-marquee
./install.sh          # builds, then installs
```
</details>

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

## It measures the free space — it never guesses

The strip's two edges are both read from the live system, every 1.5 seconds and
on every app switch:

| Edge | Measured from | Permission |
|---|---|---|
| Left | The frontmost app's **last menu title** | Accessibility |
| Right | The **leftmost status item** | none — window bounds are public |

It then fills what's between them, minus 16pt of clearance on each side. Switch
from Finder to Xcode and the strip shrinks to match Xcode's longer menu bar;
add a status item and it pulls back from the right.

**If either edge can't be measured, the strip hides.** It does not fall back to
an assumed inset, because an assumed inset is exactly what ends up sitting on
top of somebody's menus.

On a notched MacBook the notch splits the free space in two; the strip takes
whichever side is wider.

### Why it needs Accessibility permission

That is the only way macOS will tell an app where another app's menus end.
Without it there is no way to know what space is free, so the app stays hidden
rather than guess. It reads one number — the right edge of the last menu title.
It does not read menu contents, keystrokes, or anything else.

If you'd rather not grant it, you can pin the edges by hand instead:

```bash
~/Applications/MenuBarMarquee.app/Contents/MacOS/MenuBarMarquee --left 420 --right 460
```

`--auto-edges` drops the pins and goes back to measuring.

## The one honest caveat

**No app can draw inside the real menu bar.** That surface belongs to the window
server, and Apple exposes no API for putting arbitrary content in it. Apps that
appear to do this (SketchyBar, Übersicht bars) actually hide the system menu bar
and replace it wholesale, which costs you every app's File/Edit menus.

This does the opposite: a borderless, non-activating window one level above the
menu bar, spanning only the measured empty span. Visually it reads as part of
the bar. Functionally, every app menu and every status item keeps working,
untouched.

---

## Settings

Click the grid icon in your menu bar. It shows how much free bar it found
("Fitted to 512pt of free bar"), plus pause, rescan, re-measure, speed, app
names on/off, launch at login, and quit.

Everything is also a flag. Run it while a copy is already running and the change
applies live; values persist:

```
--speed <pts/sec>     scroll speed          (default 34)
--icon-size <pt>      app icon size         (default 17)
--spacing <pt>        gap between items     (default 26)
--font-size <pt>      app name size         (default 11)
--names | --no-names  show app names        (default on)
--padding <pt>        clearance from menus and status items (default 16)
--left <pt>           PIN the left edge, skipping measurement (0 = measure)
--right <pt>          PIN the right edge                      (0 = measure)
--auto-edges          drop both pins, go back to measuring
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
  MenuBarGeometry.swift   measures the free span (AX + window list)
  MarqueeView.swift       the marquee — layout, Core Animation loop, hit testing
  MarqueeBarWindow.swift  the borderless above-the-menu-bar panel
  LaunchAgent.swift       login-item install/remove
build.sh / install.sh / uninstall.sh
```


---

Built and maintained by **[Dime Data](https://dimedata.cloud)** — a web and automation studio in
Nashville, Tennessee. We build websites, AI receptionists, automation, CRM and custom apps, and we
publish the tools we make for our own work.

[dimedata.cloud](https://dimedata.cloud) · [What we've built](https://dimedata.cloud/what-we-built/) · help@dimedata.cloud
