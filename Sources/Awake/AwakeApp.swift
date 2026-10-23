import AppKit
import ServiceManagement
import SwiftUI

@main
struct AwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session: Session

    init() {
        Pref.register()
        let s = Session()
        _session = StateObject(wrappedValue: s)
        AppDelegate.session = s
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(session)
        } label: {
            MenuBarLabel().environmentObject(session)
        }
        .menuBarExtraStyle(.window)

        // the same panel as a window, for when the menu bar has no room for the icon
        Window("Awake", id: AppDelegate.panelID) {
            PopoverView(inPanel: true).environmentObject(session)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView().environmentObject(session)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var session: Session?
    static let panelID = "panel"
    /// set by the menu bar label, which has SwiftUI's openWindow
    @MainActor static var openPanel: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS places the item first and only then pushes it off a full bar, so look a few times
        for delay in [1.5, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    if !Self.panelVisible && Self.menuBarIconHidden() { Self.showPanel() }
                }
            }
        }
    }

    /// Opening Awake again from Spotlight or Applications shows its panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.showPanel() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.session?.shutdown() }
    }

    @MainActor static var panelWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(panelID) == true }
    }

    @MainActor static var panelVisible: Bool { panelWindow?.isVisible == true }

    @MainActor static func showPanel() {
        guard let openPanel else {
            // the label hasn't appeared yet; try again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { showPanel() } }
            return
        }
        openPanel()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let w = panelWindow else { return }
                // an accessory app isn't frontmost; float the window on whichever Space is showing
                w.level = .floating
                w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                w.orderFrontRegardless()
                w.makeKey()
                NSApp.activate()
            }
        }
    }

    /// Whether macOS has hidden our menu bar item (off-screen when the bar is full).
    @MainActor static func menuBarIconHidden() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let item = windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 25
        }
        guard let item, let b = item[kCGWindowBounds as String] as? [String: CGFloat] else { return true }
        return (b["X"] ?? 0) < 0 || !((item[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

/// The icon in the menu bar: a cup when idle; while awake, a filled cup with a
/// green dot, and the time left beside it if that's switched on.
struct MenuBarLabel: View {
    @EnvironmentObject var session: Session
    @AppStorage(Pref.showTimeInMenuBar) private var showTime = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if session.active {
                Image(nsImage: Icon.active())
                if showTime, let r = session.remaining { Text(Format.short(r)) }
            } else {
                Image(systemName: "cup.and.saucer")
            }
        }
        .onAppear { AppDelegate.openPanel = { openWindow(id: AppDelegate.panelID) } }
    }
}

enum Icon {
    /// The filled cup drawn in the menu bar's text colour, with a green dot.
    /// Drawn as a colour image (a template would turn the dot grey).
    static func active() -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [dark ? .white : .black]))
            if let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Awake")?
                .withSymbolConfiguration(config) {
                let s = cup.size
                cup.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - 6, y: rect.height - 7, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - popover

struct PopoverView: View {
    /// shown in its own window because the menu bar icon is hidden
    var inPanel = false
    @EnvironmentObject var s: Session
    @AppStorage(Pref.keepDisplayOn) private var keepDisplayOn = false
    @State private var lidMessage: String?
    @State private var settingUp = false

    private let presets = [15, 30, 60, 120, 240, 480]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if inPanel && AppDelegate.menuBarIconHidden() {
                Label("Your menu bar is full, so macOS is hiding Awake's cup. Hold ⌘ and drag other icons off the bar to make room — or just open Awake from Spotlight to get this window.",
                      systemImage: "menubar.rectangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if s.active { running } else { setup }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { s.refreshHelper() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: s.active ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 22))
                    .foregroundStyle(s.active ? Color.accentColor : .secondary)
                if s.active {
                    Circle().fill(.green).frame(width: 8, height: 8).offset(x: 3, y: -2)
                }
            }
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Awake").font(.headline)
                Text(s.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(s.lastStop != nil && !s.active ? .orange : .secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: idle

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $s.mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch s.mode {
            case .timer: timerControls
            case .until: untilControls
            case .unlimited:
                Text("Stays awake until you stop it, or a power, battery or sleep rule ends it.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Toggle("Keep the display on too", isOn: $keepDisplayOn).toggleStyle(.checkbox)

            if Machine.hasLid { lidCard }

            if let b = s.blocker {
                HStack(alignment: .firstTextBaseline) {
                    Label(b.prefix(1).uppercased() + b.dropFirst(), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if b.contains("power adapter") {
                        Button("Allow on battery") {
                            if s.closedLid {
                                UserDefaults.standard.set(true, forKey: Pref.closedLidOnBattery)
                            } else {
                                UserDefaults.standard.set(false, forKey: Pref.requireAdapter)
                            }
                            s.objectWillChange.send()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Button {
                s.start()
            } label: {
                Text("Start session").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(s.blocker != nil)
        }
    }

    private var timerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    if s.minutes == m {
                        Button(Format.duration(m)) { s.minutes = m }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button(Format.duration(m)) { s.minutes = m }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack {
                Text(Format.duration(s.minutes)).monospacedDigit()
                Spacer()
                Stepper("", value: $s.minutes, in: 1...Session.maxMinutes, step: s.minutes < 15 ? 1 : 15).labelsHidden()
            }
            Slider(value: Binding(get: { Double(s.minutes) }, set: { s.minutes = max(1, Int($0)) }),
                   in: 1...Double(Session.maxMinutes))
        }
    }

    private var untilControls: some View {
        HStack {
            Text("Stay awake until")
            Spacer()
            DatePicker("", selection: $s.untilTime, displayedComponents: .hourAndMinute).labelsHidden()
        }
        .help("The next time the clock shows this, within 24 hours")
    }

    private var lidCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Closed-lid mode", isOn: $s.closedLid).toggleStyle(.checkbox)
                Spacer()
                if !s.helperInstalled {
                    Button(settingUp ? "Setting up…" : "Set up") {
                        settingUp = true
                        let error = ClosedLid.install()
                        settingUp = false
                        s.refreshHelper()
                        lidMessage = error ?? "Ready. Turn on closed-lid mode and start a session."
                    }
                    .disabled(settingUp)
                }
            }
            Text(lidMessage ?? "Keeps your MacBook awake with the lid shut, up to 4 hours. Use a hard, ventilated surface.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: running

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = s.remaining {
                Text(Format.clock(r))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            } else {
                Text("∞").font(.system(size: 40, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity)
            }
            if s.lidEngaged {
                Label(s.readyToCloseLid ? "Ready to close the lid" : "Not ready to close the lid yet",
                      systemImage: s.readyToCloseLid ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(s.readyToCloseLid ? .green : .orange)
                    .font(.callout)
            }
            powerLine
            HStack {
                if s.endsAt != nil {
                    Button("+15 min") { s.extend() }.controlSize(.large)
                }
                Button {
                    s.stop()
                } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var powerLine: some View {
        let p = s.power
        let text: String
        if !p.hasBattery { text = "On mains power" }
        else if p.onAC { text = "Charging" + (p.percent.map { " · \($0)%" } ?? "") }
        else { text = "On battery" + (p.percent.map { " · \($0)%" } ?? "") }
        return Label(text, systemImage: p.onAC ? "powerplug" : "battery.50").font(.caption).foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - settings

struct SettingsView: View {
    @EnvironmentObject var s: Session
    @AppStorage(Pref.requireAdapter) private var requireAdapter = true
    @AppStorage(Pref.keepDisplayOn) private var keepDisplayOn = false
    @AppStorage(Pref.showTimeInMenuBar) private var showTime = true
    @AppStorage(Pref.batteryCutoffOn) private var cutoffOn = true
    @AppStorage(Pref.batteryCutoff) private var cutoff = 20
    @AppStorage(Pref.batteryLimitOn) private var limitOn = false
    @AppStorage(Pref.batteryLimitMinutes) private var limitMinutes = 60
    @AppStorage(Pref.closedLidOnBattery) private var lidOnBattery = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var helperMessage: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show time left in the menu bar", isOn: $showTime)
                Toggle("Keep the display on during sessions", isOn: $keepDisplayOn)
                Toggle("Require a power adapter", isOn: $requireAdapter)
                Text("When on, unplugging the charger ends a session. Plugging back in doesn't restart it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Battery") {
                Toggle("Stop when the battery drops to", isOn: $cutoffOn)
                Stepper("\(cutoff)%", value: $cutoff, in: 5...95, step: 5).disabled(!cutoffOn)
                Toggle("Limit time on battery", isOn: $limitOn)
                Stepper(Format.duration(limitMinutes), value: $limitMinutes, in: 15...720, step: 15).disabled(!limitOn)
            }
            if Machine.hasLid {
                Section("Closed lid") {
                    Toggle("Keep running on battery", isOn: $lidOnBattery)
                    Text("Closed-lid sessions stop after 4 hours, if the Mac runs hot, or by the battery rules above. Quitting Awake always lets the Mac sleep again.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(s.helperInstalled ? "Helper installed" : "Helper not installed")
                        Spacer()
                        Button(s.helperInstalled ? "Remove helper" : "Install helper") {
                            helperMessage = s.helperInstalled ? ClosedLid.uninstall() : ClosedLid.install()
                            s.refreshHelper()
                        }
                        .disabled(s.lidEngaged)
                    }
                    Text(helperMessage ?? "The helper is one rule in \(ClosedLid.sudoersPath) letting you run `pmset -a disablesleep 1/0`, and nothing else.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }
}
