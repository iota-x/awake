import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// What the power supply looks like right now.
struct PowerSnapshot: Equatable {
    var onAC: Bool
    var hasBattery: Bool
    /// 0–100, nil on a Mac without a battery
    var percent: Int?
}

enum Power {
    static func snapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSnapshot(onAC: true, hasBattery: false, percent: nil)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        var hasBattery = false
        var percent: Int?
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                percent = cur * 100 / max
            }
        }
        // a desktop Mac has no battery and is always on mains
        return PowerSnapshot(onAC: !hasBattery || providing == kIOPSACPowerValue, hasBattery: hasBattery, percent: percent)
    }
}

/// An IOKit power assertion: while held, the Mac (and optionally the display) won't idle-sleep.
final class Assertion {
    private var id: IOPMAssertionID = 0

    init?(type: String, reason: String) {
        let ok = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if ok != kIOReturnSuccess { return nil }
    }

    deinit { IOPMAssertionRelease(id) }

    static let system = "PreventUserIdleSystemSleep"
    static let display = "PreventUserIdleDisplaySleep"
}

enum Machine {
    /// MacBooks report a clamshell state; desktops don't.
    static let hasLid: Bool = clamshellProperty("AppleClamshellState") != nil

    static var lidClosed: Bool { (clamshellProperty("AppleClamshellState") as? Bool) ?? false }

    private static func clamshellProperty(_ key: String) -> Any? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
