// FanControlling.swift — Thermik (MIT). HELPER ONLY. Frozen contract between the helper's XPC/lifecycle
// layer (Unit 4: HelperService) and the SMC write layer (Unit 3: SMCFanController / FanWriteSequencer).
// Every call happens on the helper's single serial state queue → implementations need not be thread-safe.
import Foundation
import ThermikSMC
import ThermikHelperShared

/// Read + write access. Only ThermikSMCWriter (helper) adds `writeRaw` to SMCConnection.
public protocol SMCReadWriting: SMCReading {
    func writeRaw(_ key: FourCC, _ bytes: [UInt8]) throws
}

public enum SafetyVerdict: Sendable, Equatable {
    case normal(hottestC: Double?)
    case override(hottestC: Double, top4MeanC: Double)    // force every fan to Mx (I8)
    case sensorFailure                                     // no readable die sensor for N ticks → System (I9)
}

public protocol FanControlling: AnyObject {
    var profile: FanHardwareProfile { get }
    /// True while Thermik owns any fan or has set Ftst.
    var isControlling: Bool { get }
    var ownedFans: Set<Int> { get }
    var ftstSetByUs: Bool { get }
    var appliedRPM: [Int: Double] { get }

    /// Live state of every fan (reads only).
    func fanStates() -> [HelperFanState]
    /// Live Ftst value (nil if absent).
    func ftstValue() -> Int?

    /// Enter manual mode if needed (Ftst unlock on M3/M4 — may block ≤ 12 s) and write the target clamped to
    /// [Mn, Mx]. Returns the rpm actually written. Throws `FanWriteError`.
    func setManual(_ index: Int, targetRPM: Double) throws -> Double
    /// One fan back to System; clears Ftst when the last owned fan is released and we set it.
    func setAutomatic(_ index: Int) throws
    /// Never throws; retries each write. `force` also clears state Thermik did not record (startup recovery
    /// after a crash, explicit user "Reset to System"). Returns human-readable failures (empty = restored).
    @discardableResult func restoreAll(force: Bool, reason: String) -> [String]
    /// Restore bookkeeping from the recovery marker after a helper restart.
    func adoptPersistedState(ftstSetByUs: Bool)
    /// Fans we believe we own whose live mode is no longer manual (macOS reclaimed them: wake, Siri, dictation).
    func reclaimedFans() -> [Int]
    /// SMC state shows forcing (Ftst == 1, any mode == 1, FS! != 0) that Thermik does not own (I10).
    func foreignControlSuspected() -> Bool
    /// Last-resort thermal check over die sensors (call once per watchdog tick, 1 Hz).
    func evaluateSafety() -> SafetyVerdict
}

/// Errors thrown by the write layer; mapped to HelperErrorCode on the wire.
public enum FanWriteError: Error, Sendable, CustomStringConvertible {
    case notAllowed(FourCC)
    case invalidFan(Int)
    case notControllable
    case unlockTimeout(fan: Int, elapsed: Double, lastError: String)
    case reclaimedTooSoon(fan: Int)
    case verificationFailed(key: FourCC, expected: String, actual: String)
    case smc(SMCError)

    public var helperErrorCode: HelperErrorCode {
        switch self {
        case .notAllowed, .smc: return .hardwareFailure
        case .invalidFan: return .fanNotFound
        case .notControllable: return .notControllable
        case .unlockTimeout, .reclaimedTooSoon: return .unlockTimeout
        case .verificationFailed: return .verificationFailed
        }
    }
    public var description: String {
        switch self {
        case .notAllowed(let k): return "write to \(k) is not allow-listed"
        case .invalidFan(let i): return "no fan \(i)"
        case .notControllable: return "fans are not controllable on this Mac"
        case let .unlockTimeout(f, e, l): return String(format: "fan %d: manual mode not accepted after %.1fs (%@)", f, e, l)
        case .reclaimedTooSoon(let f): return "fan \(f) was reclaimed by macOS; re-assert throttled"
        case let .verificationFailed(k, e, a): return "read-back of \(k): expected \(e), got \(a)"
        case .smc(let e): return e.description
        }
    }
}
