// PowerSources.swift — Thermik (MIT). OWNER: Unit 2.
// IOPowerSources (public, sandbox-safe; SYS §2.4): providing source, time remaining, warning level, accessories (P2).
import Foundation
import IOKit.ps

/// A Bluetooth accessory battery (Magic Trackpad/Keyboard/Mouse, AirPods). P2.
/// The accessory's NAME is deliberately not exposed: it often contains the owner's name ("Philipp's AirPods").
public struct AccessoryBattery: Sendable, Equatable {
    public var category: String?                   // "Trackpad", "Headset", "Keyboard", …
    public var percent: Int?
    public var isCharging: Bool
    public var transport: String?                  // "Bluetooth"
}

enum PowerSources {
    /// ~0.5–0.8 ms.
    static func summary() -> PowerSourceSummary {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let est = IOPSGetTimeRemainingEstimate()
        let remaining: TimeInterval? = est == kIOPSTimeRemainingUnlimited ? .infinity
            : (est == kIOPSTimeRemainingUnknown || est < 0 ? nil : est)
        return PowerSourceSummary(kind: kind(type),
                                  timeRemaining: remaining,
                                  batteryWarningLevel: Int(IOPSGetBatteryWarningLevel().rawValue),
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// kIOPMACPowerKey / kIOPMBatteryPowerKey / kIOPMUPSPowerKey (IOPMLib.h).
    static func kind(_ providingType: String?) -> PowerSourceKind {
        switch providingType {
        case "AC Power": .ac
        case "Battery Power": .battery
        case "UPS Power": .ups
        default: .unknown
        }
    }

    /// P2. `IOPSCopyPowerSourcesByType` is exported by IOKit but declared only in the open-source IOKitUser
    /// `IOPowerSourcesPrivate.h` (APSL 2.0) → resolved with dlsym; returns [] when the symbol disappears. ~1 ms.
    static func accessories() -> [AccessoryBattery] {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else { return [] }   // RTLD_DEFAULT
        let copyByType = unsafeBitCast(sym, to: ByType.self)
        guard let blob = copyByType(0 /* kIOPSSourceAll */)?.takeRetainedValue() else { return [] }
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .filter { ($0[kIOPSTypeKey] as? String) == "Accessory Source" }
            .map { d in
                AccessoryBattery(category: d["Accessory Category"] as? String,
                                 percent: (d[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue,
                                 isCharging: (d[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false,
                                 transport: d[kIOPSTransportTypeKey] as? String)
            }
    }
}
