import AppKit
import Combine
import Foundation
import UserNotifications

enum Mode: String, CaseIterable, Identifiable {
    case timer = "Timer", until = "Until", unlimited = "Unlimited"
    var id: String { rawValue }
}

/// Every preference, in UserDefaults.
enum Pref {
    static let requireAdapter = "requireAdapter"        // lid-open sessions need the charger
    static let keepDisplayOn = "keepDisplayOn"
    static let batteryCutoffOn = "batteryCutoffOn"
    static let batteryCutoff = "batteryCutoff"          // %
    static let batteryLimitOn = "batteryLimitOn"
    static let batteryLimitMinutes = "batteryLimitMinutes"
    static let closedLidOnBattery = "closedLidOnBattery"
    static let showTimeInMenuBar = "showTimeInMenuBar"
    static let lastMinutes = "lastMinutes"

    static func register() {
        UserDefaults.standard.register(defaults: [
            requireAdapter: true, keepDisplayOn: false,
            batteryCutoffOn: true, batteryCutoff: 20,
            batteryLimitOn: false, batteryLimitMinutes: 60,
            closedLidOnBattery: false, showTimeInMenuBar: true,
            lastMinutes: 60,
        ])
    }

    static var d: UserDefaults { .standard }
}

@MainActor
final class Session: ObservableObject {
    // what the popover is set to
    @Published var mode: Mode = .timer
    @Published var minutes: Int = UserDefaults.standard.integer(forKey: Pref.lastMinutes) {
        didSet { Pref.d.set(minutes, forKey: Pref.lastMinutes) }
    }
    @Published var untilTime: Date = Calendar.current.date(byAdding: .hour, value: 2, to: .now)!
    @Published var closedLid = false
    /// cached: checking means running sudo, which mustn't happen on every redraw
    @Published private(set) var helperInstalled = false

    // what's running
    @Published private(set) var active = false
    @Published private(set) var endsAt: Date?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lidEngaged = false
    @Published private(set) var lastStop: String?
    @Published private(set) var power = Power.snapshot()
    @Published private(set) var now = Date()

    private var systemAssertion: Assertion?
    private var displayAssertion: Assertion?
    private var ticker: Timer?
    private var onBatterySince: Date?
    private var observers: [NSObjectProtocol] = []

    static let maxMinutes = 24 * 60

    init() {
        ClosedLid.recoverIfNeeded()
        let ws = NSWorkspace.shared.notificationCenter
        // asking the Mac to sleep ends the session; it doesn't come back on wake
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(because: "Your Mac went to sleep.") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        // a setting changed (here or in Settings): redraw, and apply the display option live
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        refreshHelper()
        // keep power readings fresh for the popover even when idle
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - what the UI shows

    var remaining: TimeInterval? { endsAt.map { max(0, $0.timeIntervalSince(now)) } }

    var statusLine: String {
        guard active else { return lastStop ?? "Your Mac sleeps normally." }
        if let r = remaining { return "Awake for \(Format.clock(r)) more" }
        return "Awake until you stop it"
    }

    /// What's in the way of starting, or nil.
    var blocker: String? {
        if mode == .until, untilDate.timeIntervalSince(now) < 60 { return "Pick a time at least a minute away." }
        if closedLid && !helperInstalled { return "Set up closed-lid mode first." }
        return powerProblem(closedLid: closedLid)
    }

    var untilDate: Date {
        // the picked clock time today, or tomorrow if it's already gone; the
        // current minute stays today, so it reads as "too soon" rather than 24 h
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: untilTime)
        let today = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: now) ?? untilTime
        if today > now || now.timeIntervalSince(today) < 60 { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Closed-lid: the lid can go down once this is true.
    var readyToCloseLid: Bool { active && lidEngaged && powerProblem(closedLid: true) == nil }

    // MARK: - control

    func start() {
        guard !active, blocker == nil else { return }
        guard let sys = Assertion(type: Assertion.system, reason: "Awake session") else {
            lastStop = "macOS refused to keep the Mac awake."
            return
        }
        systemAssertion = sys
        if Pref.d.bool(forKey: Pref.keepDisplayOn) {
            displayAssertion = Assertion(type: Assertion.display, reason: "Awake session (display)")
        }
        if closedLid {
            lidEngaged = ClosedLid.engage()
            if !lidEngaged { lastStop = "Couldn't switch lid sleep off — set up closed-lid mode again." }
        }
        startedAt = .now
        switch mode {
        case .timer: endsAt = Date.now.addingTimeInterval(TimeInterval(min(max(minutes, 1), Self.maxMinutes) * 60))
        case .until: endsAt = untilDate
        case .unlimited: endsAt = nil
        }
        // closed-lid sessions never outlast the cap
        if lidEngaged {
            let cap = Date.now.addingTimeInterval(ClosedLid.maxHours * 3600)
            if endsAt == nil || endsAt! > cap { endsAt = cap }
        }
        onBatterySince = power.onAC ? nil : .now
        active = true
        lastStop = nil
    }

    func extend() {
        guard active, let end = endsAt else { return }
        var next = end.addingTimeInterval(15 * 60)
        let limit = (startedAt ?? .now).addingTimeInterval(TimeInterval(Self.maxMinutes * 60))
        if next > limit { next = limit }
        if lidEngaged { next = min(next, (startedAt ?? .now).addingTimeInterval(ClosedLid.maxHours * 3600)) }
        endsAt = next
    }

    func stop(because reason: String? = nil) {
        guard active else { return }
        systemAssertion = nil
        displayAssertion = nil
        if lidEngaged { ClosedLid.disengage() }
        lidEngaged = false
        active = false
        endsAt = nil
        startedAt = nil
        onBatterySince = nil
        lastStop = reason.map { "Stopped: \($0)" }
        if let reason { Notify.post("Awake stopped", reason) }
    }

    /// Quitting always puts things back.
    func shutdown() {
        stop()
        ClosedLid.disengage()
    }

    func refreshHelper() {
        Task.detached {
            let installed = ClosedLid.isInstalled
            await MainActor.run { if self.helperInstalled != installed { self.helperInstalled = installed } }
        }
    }

    private func settingsChanged() {
        objectWillChange.send()
        guard active else { return }
        let want = Pref.d.bool(forKey: Pref.keepDisplayOn)
        if want && displayAssertion == nil {
            displayAssertion = Assertion(type: Assertion.display, reason: "Awake session (display)")
        } else if !want && displayAssertion != nil {
            displayAssertion = nil
        }
        check()
    }

    // MARK: - rules

    private func tick() {
        now = .now
        let p = Power.snapshot()
        if p != power { power = p }
        if active { check() }
    }

    private func check() {
        guard active else { return }
        if let end = endsAt, now >= end { stop(because: "time's up."); return }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical || (lidEngaged && thermal == .serious) {
            stop(because: "your Mac is running hot."); return
        }
        if let problem = powerProblem(closedLid: lidEngaged) { stop(because: problem); return }
        if power.onAC { onBatterySince = nil } else if onBatterySince == nil { onBatterySince = now }
        if Pref.d.bool(forKey: Pref.batteryLimitOn), let since = onBatterySince,
           now.timeIntervalSince(since) >= Double(Pref.d.integer(forKey: Pref.batteryLimitMinutes) * 60) {
            stop(because: "battery time limit reached."); return
        }
    }

    /// The charger and battery rules, for a lid-open or closed-lid session.
    private func powerProblem(closedLid: Bool) -> String? {
        guard power.hasBattery else { return nil }
        let needsAdapter = closedLid ? !Pref.d.bool(forKey: Pref.closedLidOnBattery) : Pref.d.bool(forKey: Pref.requireAdapter)
        if needsAdapter && !power.onAC { return "the power adapter isn't connected." }
        if !power.onAC, Pref.d.bool(forKey: Pref.batteryCutoffOn), let pct = power.percent,
           pct <= Pref.d.integer(forKey: Pref.batteryCutoff) {
            return "battery is at \(pct)%."
        }
        return nil
    }
}

enum Format {
    /// 1:05:09 / 4:07
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 1h 30m / 45m — for the menu bar
    static func short(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

enum Notify {
    static func post(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body.prefix(1).uppercased() + body.dropFirst()
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
