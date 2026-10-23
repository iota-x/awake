import AppKit
import Foundation

/// Keeping a MacBook awake with the lid shut needs `pmset -a disablesleep 1`,
/// which only root may run. The one-time setup installs a sudoers rule that
/// lets this user run exactly two commands without a password:
///
///     /usr/bin/pmset -a disablesleep 1
///     /usr/bin/pmset -a disablesleep 0
///
/// Nothing else. While it's on, a detached watchdog shell puts sleep back if
/// Awake quits or crashes, and after a hard cap of a little over four hours —
/// so a Mac in a bag can never be left unable to sleep.
enum ClosedLid {
    static let sudoersPath = "/etc/sudoers.d/awake-closed-lid"
    static let maxHours = 4.0

    private static var support: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Awake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Exists while sleep is disabled by us; the watchdog stops when it's gone.
    private static var flag: URL { support.appendingPathComponent("closed-lid.on") }

    /// The helper rule is installed and usable without a password.
    static var isInstalled: Bool {
        run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]) == 0
    }

    static var isEngaged: Bool { FileManager.default.fileExists(atPath: flag.path) }

    /// Install the sudoers rule. macOS asks for an admin password once.
    static func install() -> String? {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return "Unexpected user name."
        }
        let rule = """
        # Awake: lets \(user) switch lid sleep off and back on, nothing else.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0

        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("awake-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // visudo checks the syntax before anything lands in /etc/sudoers.d
        let script = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' '\(sudoersPath)'"
        return admin(script)
    }

    static func uninstall() -> String? {
        disengage()
        return admin("/bin/rm -f '\(sudoersPath)'")
    }

    /// Switch lid sleep off and start the watchdog.
    @discardableResult
    static func engage() -> Bool {
        guard run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]) == 0 else { return false }
        FileManager.default.createFile(atPath: flag.path, contents: Data())
        let pid = ProcessInfo.processInfo.processIdentifier
        let checks = Int(maxHours * 3600 / 30) + 10 // 30 s per check, a few minutes' grace
        // runs on after Awake exits; restores sleep when Awake is gone, the flag is gone, or time is up
        let watchdog = """
        n=0
        while kill -0 \(pid) 2>/dev/null && [ -e "$1" ] && [ $n -lt \(checks) ]; do sleep 30; n=$((n+1)); done
        [ -e "$1" ] && rm -f "$1"
        /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog, "awake-watchdog", flag.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return true
    }

    /// Put lid sleep back. Safe to call any time.
    static func disengage() {
        try? FileManager.default.removeItem(at: flag)
        _ = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    /// After a crash the flag is still there: put sleep back before anything else.
    static func recoverIfNeeded() {
        if isEngaged { disengage() }
    }

    // MARK: -

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Run a shell line as root through the standard macOS password prompt. nil = success.
    private static func admin(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            return code == -128 ? "Cancelled." : (error[NSAppleScript.errorMessage] as? String ?? "Failed.")
        }
        return nil
    }
}
