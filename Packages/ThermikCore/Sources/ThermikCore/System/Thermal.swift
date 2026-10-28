// Thermal.swift — Thermik (MIT). OWNER: Unit 2.
// macOS thermal pressure (Darwin notify key, SDK libkern/OSThermalNotification.h) and ProcessInfo.thermalState (SYS §5).
// Public APIs, no root, sandbox-safe.
import Foundation
import notify

/// Reads `com.apple.system.thermalpressurelevel` (kOSThermalNotificationPressureLevelName). The notify token is
/// registered once and kept, so each read is a single `notify_get_state` (~26 µs → read on every tick).
/// macOS values are 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping; iOS uses 0/10/20… (never mix them).
/// Not thread-safe: owned by `SystemSampler`.
final class ThermalPressureReader {
    static let notifyName = "com.apple.system.thermalpressurelevel"
    private var token: Int32 = 0
    private var registered = false
    private var lastKnown: ThermalPressure = .nominal

    deinit { if registered { notify_cancel(token) } }

    /// The current level; the last known level when the read fails or reports a value outside 0…4.
    func current() -> ThermalPressure {
        if !registered {
            registered = notify_register_check(Self.notifyName, &token) == NOTIFY_STATUS_OK
            guard registered else { return lastKnown }
        }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK, let p = ThermalPressure(rawValue: state) else { return lastKnown }
        lastKnown = p
        return p
    }

    /// Foundation's coarser view (nominal / fair / serious / critical).
    static func processThermalState() -> ProcessThermalState {
        ProcessThermalState(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical
    }
}
