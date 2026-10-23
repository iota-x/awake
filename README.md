# Awake

A menu bar app that keeps your Mac awake — a free, home-made take on WakeBee.

- **Timer** (1 min – 24 h, presets, +15 min while running), **Until** a clock time (within 24 h), or **Unlimited**
- Optionally keeps the **display** on too
- **Closed-lid mode** on MacBooks (up to 24 h): a one-time admin prompt installs
  `/etc/sudoers.d/awake-closed-lid`, which allows exactly `pmset -a disablesleep 1/0`.
  A watchdog puts lid sleep back if Awake quits or crashes, and after ~24 h no matter what
- **Rules:** needs the charger by default (unplugging ends the session; "Allow on battery" or
  Settings to change), battery cutoff %, time-on-battery limit, stops if the Mac runs hot,
  and asking the Mac to sleep ends the session
- Green dot + time left in the menu bar while active; notification when a rule stops it
- Launch at login. If the menu bar is full (notch), opening Awake shows its panel as a window

## Build

```bash
./build.sh            # → dist/Awake.app
./build.sh --install  # also copies it to /Applications
```

Built with `swiftc` from the Command Line Tools (no Xcode). SwiftPM's manifest
doesn't link with this CLT, and a stale `module.modulemap` in it duplicates
`SwiftBridging`; `build.sh` hides that file with a VFS overlay instead of
touching the system. `tools/selftest.swift` exercises the session engine
against real power assertions (`pmset -g assertions`).

To remove the closed-lid helper: Settings → Closed lid → Remove helper
(or `sudo rm /etc/sudoers.d/awake-closed-lid`).
