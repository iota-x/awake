<p align="center"><img src="docs/icon.png" width="128" alt="Awake icon"></p>

<h1 align="center">Awake</h1>

<p align="center">Keep your Mac awake from the menu bar — timed sessions, closed-lid mode and battery rules. Free and open source.</p>

<p align="center"><a href="https://github.com/iota-x/awake/releases/latest"><b>⬇ Download the latest release</b></a> · <a href="https://iota-x.github.io/awake/">Website</a> · macOS 15+ · Apple silicon and Intel</p>

---

## What it does

- **Timer** — 1 minute to 24 hours, with presets, and **+15 min** while it runs
- **Until** — stay awake until a clock time (within the next 24 hours)
- **Unlimited** — until you stop it
- **Keep the display on too**, if you want
- **Closed-lid mode** (MacBooks) — keep working with the lid shut, up to 24 hours
- **Safety rules** — needs the charger by default (one click to allow battery), stops at a battery
  level you choose or after a time limit on battery, stops if the Mac runs hot, and choosing
  Sleep always ends the session. You get a notification when a rule stops it.
- A cup in the menu bar with a **green dot** while a session runs (time left optional)
- **Launch at login**
- Menu bar full, or the icon parked in Ice/Bartender's hidden section? Open Awake from
  Spotlight and the same panel opens as a window.

## Install

1. Download **Awake-x.y.z.dmg** (or the .zip) from [Releases](https://github.com/iota-x/awake/releases/latest).
2. Drag **Awake** into **Applications**.
3. Open it. Awake isn't signed with a paid Apple Developer ID, so the first time macOS says it
   can't verify the developer. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to Awake. You only do this once.

   Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Awake.app`

Awake lives in the menu bar — there's no Dock icon.

## Closed-lid mode

A MacBook sleeps when you close the lid no matter what an app asks, unless sleep is switched off
with `pmset -a disablesleep 1`, which only an administrator can run. So the first time, **Set up**
asks for your admin password and installs one file, `/etc/sudoers.d/awake-closed-lid`, that lets
your user run exactly two commands without a password:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

Nothing else. While a closed-lid session runs, a small watchdog process turns sleep back on if
Awake quits or crashes, and after 24 hours regardless — so your Mac can't get stuck awake in a bag.
Keep a closed MacBook on a hard, ventilated surface.

To remove it: **Settings → Closed lid → Remove helper** (or `sudo rm /etc/sudoers.d/awake-closed-lid`).

## Build from source

Needs Xcode or the Command Line Tools (Swift 6, macOS 15 SDK).

```bash
./build.sh            # → dist/Awake.app (universal)
./build.sh --install  # and copy it to /Applications
./build.sh --package  # and make dist/Awake-<version>.zip and .dmg
```

`build.sh` calls `swiftc` directly rather than SwiftPM. Some Command Line Tools installs ship a
stale `usr/include/swift/module.modulemap` that clashes with `SwiftBridging`; the script hides it
from the compiler with a VFS overlay instead of touching the system. `tools/selftest.swift`
exercises the session engine against the real power assertions (`pmset -g assertions`).

## Uninstall

Quit Awake, delete it from Applications, and remove the closed-lid helper if you installed it
(see above). Settings live in `~/Library/Preferences/com.iota.awake.plist`.

## License

[MIT](LICENSE)
