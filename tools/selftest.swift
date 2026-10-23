// Exercises the session engine without the UI: start, assertion held, extend, stop, released.
import AppKit

func assertions() -> String {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "assertions"]; p.standardOutput = pipe
    try! p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok  " : "  FAIL", what); if !ok { exit(1) } }

@main
struct SelfTest {
    @MainActor static func main() {
        Pref.register()
        let p = Power.snapshot()
        print("power: onAC=\(p.onAC) battery=\(p.hasBattery) \(p.percent.map { "\($0)%" } ?? "-") · hasLid=\(Machine.hasLid) lidClosed=\(Machine.lidClosed) · helper=\(ClosedLid.isInstalled)")
        UserDefaults.standard.set(false, forKey: Pref.requireAdapter) // so the test runs on battery too
        let s = Session()
        s.mode = .timer; s.minutes = 1
        check(s.blocker == nil, "nothing blocks a 1-minute timer (\(s.blocker ?? "-"))")
        s.start()
        check(s.active, "session started")
        check(assertions().contains("Awake session"), "macOS shows the PreventUserIdleSystemSleep assertion")
        let before = s.endsAt!
        s.extend()
        check(Int(s.endsAt!.timeIntervalSince(before).rounded()) == 900, "+15 min extends by 15 minutes")
        s.minutes = 99999
        check(s.minutes == 99999, "(minutes field accepts input; start() clamps to 24 h)")
        s.stop()
        check(!s.active, "session stopped")
        check(!assertions().contains("Awake session"), "assertion released")
        s.mode = .unlimited; s.start()
        check(s.active && s.endsAt == nil, "unlimited session has no end")
        s.stop()
        s.mode = .until; s.untilTime = Date().addingTimeInterval(30)
        check(s.blocker != nil, "'until' less than a minute away is refused")
        s.untilTime = Date().addingTimeInterval(-3600)
        check(s.untilDate > Date() && s.untilDate.timeIntervalSinceNow < 86400, "'until' an earlier clock time means tomorrow, within 24 h")
        if !p.onAC && p.hasBattery {
            UserDefaults.standard.set(true, forKey: Pref.requireAdapter)
            s.mode = .timer
            check(s.blocker?.contains("power adapter") == true, "on battery, 'Require a power adapter' blocks starting")
            UserDefaults.standard.set(false, forKey: Pref.requireAdapter)
            UserDefaults.standard.set(95, forKey: Pref.batteryCutoff)
            check(s.blocker?.contains("battery is at") == true, "below the battery cutoff blocks starting")
            UserDefaults.standard.set(20, forKey: Pref.batteryCutoff)
        }
        print("all good")
    }
}
