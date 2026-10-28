// FanHardware.swift — Thermik (MIT)
//
// Fan discovery and read-only snapshots. Used by the app (unprivileged) for
// monitoring and by the helper to build its write plan.
//
// Everything is decided from what the SMC exposes at runtime (key presence +
// key type), never from model tables, because the layout changed between
// generations: M1–M4 use `F%dMd`, M5 uses `F%dmd`; M3/M4 expose `Ftst`, M5
// does not; Intel pre-T2 uses the `FS! ` bitmask with `fpe2` values.

import Foundation
import Darwin

/// Host facts that do not depend on the SMC.
public enum HostInfo {
    /// True on Apple Silicon even when this process runs under Rosetta
    /// (`#if arch(arm64)` would be wrong for an x86_64 slice on an M-series Mac).
    public static let isAppleSilicon: Bool = {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }()

    /// e.g. "Mac16,5". Used for logs / bug reports only, never for logic.
    public static let modelIdentifier: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()
}

/// How fan "manual" mode is entered on this machine.
public enum FanControlScheme: Sendable, Equatable, CustomStringConvertible {
    /// Apple Silicon: per-fan ui8 mode key (`F%dMd` on M1–M4, `F%dmd` on M5),
    /// optionally gated by the global `Ftst` diagnostic unlock (M3/M4).
    case appleSilicon(modeKeyTemplate: String, hasFtst: Bool)
    /// Intel with T2: per-fan `F%dMd` (0 auto, 1 forced), targets in `flt`.
    case intelModeKey
    /// Intel pre-T2: global `FS! ` ui16 bitmask (bit n = fan n forced), targets `fpe2`.
    case intelForceBits
    /// No force mechanism (very old Intel): only raising `F%dMn` is possible.
    case intelMinimumOnly
    /// No controllable fans (fanless Mac, or unknown layout).
    case none

    public var description: String {
        switch self {
        case let .appleSilicon(t, f): return "appleSilicon(modeKey: \(t), Ftst: \(f))"
        case .intelModeKey: return "intelModeKey"
        case .intelForceBits: return "intelForceBits"
        case .intelMinimumOnly: return "intelMinimumOnly"
        case .none: return "none"
        }
    }

    /// On Ftst-gated hardware the unlock is global: once Ftst=1, fans that are
    /// *not* forced drop to firmware mode 0 (held at ~minimum, thermal ramping
    /// unverified) instead of being managed by thermalmonitord. The engine
    /// therefore drives ALL fans whenever ANY fan is under Thermik control.
    public var requiresAllOrNothing: Bool {
        if case .appleSilicon(_, true) = self { return true }
        return false
    }

    /// A forced fan may be stopped (target 0 rpm): Apple Silicon fans stop on their own at idle, so the firmware
    /// takes a zero target. Intel minimums are floors.
    public var allowsFanStop: Bool {
        if case .appleSilicon = self { return true }
        return false
    }
}

/// Raw meaning of the mode key value (informal names; not Apple API).
public enum FanModeValue: Sendable, Equatable, CustomStringConvertible {
    case auto            // 0: firmware auto
    case manual          // 1: forced; F%dTg is honoured
    case system          // 3: thermalmonitord holds the fan ("System Mode"); writes rejected with 0x82 until Ftst unlock
    case other(UInt8)

    public init(_ raw: UInt8) {
        switch raw { case 0: self = .auto; case 1: self = .manual; case 3: self = .system; default: self = .other(raw) }
    }
    public var raw: UInt8 {
        switch self { case .auto: return 0; case .manual: return 1; case .system: return 3; case .other(let r): return r }
    }
    /// For UI: 0 and 3 both mean "macOS is in charge".
    public var isSystemControlled: Bool { self == .auto || self == .system }
    public var description: String {
        switch self { case .auto: return "auto(0)"; case .manual: return "manual(1)"; case .system: return "system(3)"; case .other(let r): return "other(\(r))" }
    }
}

public struct FanDescriptor: Sendable, Equatable, Identifiable {
    public let index: Int
    public let name: String
    public let minRPM: Double       // F%dMn — minimum *spinning* speed (fans may still be OFF = 0 rpm in System mode)
    public let maxRPM: Double       // F%dMx — reported max (hardware can exceed it; we never do)
    public let targetType: SMCDataType
    public let modeKey: FourCC?     // nil on intelForceBits / intelMinimumOnly
    public var id: Int { index }
    public init(index: Int, name: String, minRPM: Double, maxRPM: Double, targetType: SMCDataType, modeKey: FourCC?) {
        self.index = index; self.name = name; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.targetType = targetType; self.modeKey = modeKey
    }
}

public struct FanHardwareProfile: Sendable, Equatable {
    public let fans: [FanDescriptor]
    public let scheme: FanControlScheme
    /// Key presence, cached at discovery so hot paths never probe missing keys
    /// (a keyInfo miss costs a full SMC round trip every time).
    public var hasFtstKey = false
    public var hasForceBitsKey = false
    /// Fans FNum counts whose keys exist but could not be read (even after retries): they are not in `fans`.
    public var unreadableFans: [Int] = []
    public init(fans: [FanDescriptor], scheme: FanControlScheme) { self.fans = fans; self.scheme = scheme }
    /// Fanless / not yet discovered.
    public static let none = FanHardwareProfile(fans: [], scheme: .none)
    /// Every fan FNum reports was discovered.
    public var isComplete: Bool { unreadableFans.isEmpty }
    /// On all-or-nothing (Ftst) hardware an incomplete profile is not controllable: the engine could never command
    /// the missing fan, which would sit in firmware mode 0 (near minimum, no thermal ramp) while Ftst is unlocked.
    public var isControllable: Bool {
        if case .none = scheme { return false }
        if scheme.requiresAllOrNothing && !isComplete { return false }
        return !fans.isEmpty
    }
    public func fan(_ index: Int) -> FanDescriptor? { fans.first { $0.index == index } }

    public static let modeUpper = "F%dMd"
    public static let modeLower = "F%dmd"
    /// Global "force test" unlock (ui8) on M3/M4; absent on M5 and Intel.
    public static let ftstKey: FourCC = "Ftst"
    /// Intel pre-T2 force bitmask (ui16 big-endian, bit n = fan n forced). Note the trailing space.
    public static let forceBitsKey: FourCC = "FS! "

    /// Probes the SMC. Read-only; works unprivileged.
    public static func discover(_ smc: SMCReading) -> FanHardwareProfile {
        discover(smc, appleSilicon: HostInfo.isAppleSilicon)
    }

    /// Same, with the CPU family given explicitly: the offline simulator (`thermik-probe fans sim`) runs the real
    /// discovery against fake Intel and Apple Silicon SMCs on any host. Production code uses `discover(_:)`.
    public static func discover(_ smc: SMCReading, appleSilicon: Bool) -> FanHardwareProfile {
        // Discovery runs once per process: a transient read error (the SMC settling after boot or wake) must not
        // become "passively cooled" or a missing fan for the whole session. Missing keys are final; others retry.
        guard case .value(let fnum) = read({ try smc.readUInt8("FNum") }), fnum > 0 else {
            return FanHardwareProfile(fans: [], scheme: .none)
        }
        let count = Int(fnum)

        func isUI8(_ k: FourCC) -> Bool {
            guard case .value(let i) = read({ try smc.keyInfo(k) }) else { return false }
            return i.size == 1 && (i.type == .ui8 || i.type == .flag || i.type == .hex)
        }
        let hasFtst = isUI8(ftstKey)
        let hasForceBits: Bool = { if case .value(let i) = read({ try smc.keyInfo(forceBitsKey) }) { return i.size == 2 }; return false }()
        let upper = isUI8(.fan(modeUpper, 0))
        let lower = isUI8(.fan(modeLower, 0))

        let scheme: FanControlScheme
        let template: String?
        if appleSilicon {
            // Prefer lowercase if both exist (M5 firmware); M1–M4 expose only uppercase.
            if lower { template = modeLower; scheme = .appleSilicon(modeKeyTemplate: modeLower, hasFtst: hasFtst) }
            else if upper { template = modeUpper; scheme = .appleSilicon(modeKeyTemplate: modeUpper, hasFtst: hasFtst) }
            else { template = nil; scheme = .none }
        } else {
            if upper { template = modeUpper; scheme = .intelModeKey }
            else if hasForceBits { template = nil; scheme = .intelForceBits }
            else { template = nil; scheme = .intelMinimumOnly }
        }

        var fans: [FanDescriptor] = []
        var unreadable: [Int] = []
        for i in 0..<min(count, 10) {
            let fan = read { () throws -> FanDescriptor in
                let mn = try smc.readNumber(.fan("F%dMn", i))
                let mx = try smc.readNumber(.fan("F%dMx", i))
                let tInfo = try smc.keyInfo(.fan("F%dTg", i))
                guard mn.isFinite, mx.isFinite, mn >= 0, mx > mn, mx < 20_000, tInfo.type == .flt || tInfo.type == .fpe2 else {
                    throw SMCError.invalidValue("fan \(i): Mn \(mn), Mx \(mx), Tg \(tInfo.type)")
                }
                return FanDescriptor(index: i, name: fanName(smc, index: i, count: count), minRPM: mn, maxRPM: mx,
                                     targetType: tInfo.type, modeKey: template.map { FourCC.fan($0, i) })
            }
            switch fan {
            case .value(let f): fans.append(f)
            case .missing: continue                        // FNum counts a slot without fan keys: no such fan
            case .failed: unreadable.append(i)             // the fan exists but its limits cannot be read
            }
        }
        var p = FanHardwareProfile(fans: fans, scheme: fans.isEmpty ? .none : scheme)
        p.hasFtstKey = hasFtst
        p.hasForceBitsKey = hasForceBits
        p.unreadableFans = unreadable
        return p
    }

    private enum ReadOutcome<T> { case value(T), missing, failed }

    /// Discovery reads: up to 3 attempts 20 ms apart. A missing key ends at once (`missing`); any other error
    /// (I/O, firmware busy, nonsense values) is retried and becomes `failed`.
    private static func read<T>(_ body: () throws -> T) -> ReadOutcome<T> {
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            do { return .value(try body()) }
            catch let e as SMCError where e.resultCode == .notFound { return .missing }
            catch { continue }
        }
        return .failed
    }

    private static func fanName(_ smc: SMCReading, index: Int, count: Int) -> String {
        // Intel exposes F%dID ({fds}: type, zone, location, pad, 12-char name); Apple Silicon does not.
        if case .fanDescriptor(_, _, _, let n)? = try? smc.value(.fan("F%dID", index)), !n.isEmpty { return n }
        // Apple Silicon: no name key. Localise in the UI layer; these are fallbacks.
        if count == 1 { return "Fan" }
        if count == 2 { return index == 0 ? "Left Fan" : "Right Fan" }  // MacBook Pro convention (unverified on desktops)
        return "Fan \(index + 1)"
    }
}

/// One read of a fan's live state.
public struct FanSnapshot: Sendable, Equatable {
    public let index: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let mode: FanModeValue?
    public let dutyCycle: Double?   // F%dDc (0...1) where present (Apple Silicon)
    public let timestamp: Date
    public init(index: Int, actualRPM: Double, targetRPM: Double, mode: FanModeValue?, dutyCycle: Double?, timestamp: Date) {
        self.index = index; self.actualRPM = actualRPM; self.targetRPM = targetRPM; self.mode = mode
        self.dutyCycle = dutyCycle; self.timestamp = timestamp
    }

    /// Apple Silicon laptops routinely park fans at 0 rpm when cool. This is
    /// NOT an error: render as "Off" rather than "0 RPM / failed".
    public var isOff: Bool { actualRPM < 50 && targetRPM < 1 }
}

public struct FanControlState: Sendable, Equatable {
    public let ftst: UInt8?          // nil if key absent
    public let forceBits: UInt16?    // Intel FS!
    public let fans: [FanSnapshot]
    public init(ftst: UInt8?, forceBits: UInt16?, fans: [FanSnapshot]) { self.ftst = ftst; self.forceBits = forceBits; self.fans = fans }

    /// True when some process (not necessarily us) holds manual control.
    public var anyManual: Bool { fans.contains { $0.mode == .manual } || (forceBits ?? 0) != 0 || ftst == 1 }

    /// The raw evidence behind `anyManual`, e.g. ["Ftst=1", "fan 0 mode=1", "fan 1 mode=1"] (logs, probe, diagnostics).
    public var forcingSignals: [String] {
        var out: [String] = []
        if ftst == 1 { out.append("Ftst=1") }
        if let fs = forceBits, fs != 0 { out.append(String(format: "FS!=0x%04x", fs)) }
        for f in fans where f.mode == .manual { out.append("fan \(f.index) mode=1") }
        return out
    }
}

public enum FanReader {
    public static func snapshot(_ smc: SMCReading, profile: FanHardwareProfile, now: Date = Date()) -> FanControlState {
        let fans = profile.fans.map { f -> FanSnapshot in
            FanSnapshot(index: f.index,
                        actualRPM: max(0, (try? smc.readNumber(.fan("F%dAc", f.index))) ?? 0),
                        targetRPM: max(0, (try? smc.readNumber(.fan("F%dTg", f.index))) ?? 0),
                        mode: f.modeKey.flatMap { try? smc.readUInt8($0) }.map(FanModeValue.init),
                        dutyCycle: try? smc.readNumber(.fan("F%dDc", f.index)),
                        timestamp: now)
        }
        let ftst: UInt8? = profile.hasFtstKey ? (try? smc.readUInt8(FanHardwareProfile.ftstKey)) : nil
        var fs: UInt16? = nil
        if profile.hasForceBitsKey, let (info, b) = try? smc.readRaw(FanHardwareProfile.forceBitsKey), info.size == 2, b.count == 2 {
            fs = UInt16(b[0]) << 8 | UInt16(b[1])
        }
        return FanControlState(ftst: ftst, forceBits: fs, fans: fans)
    }
}

/// Percent <-> RPM mapping used everywhere in the UI and engine.
/// 0 % == minimum spinning speed (F%dMn), 100 % == F%dMx. "Off" is not a percentage:
/// only System mode may stop the fans.
public extension FanDescriptor {
    func rpm(forPercent p: Double) -> Double { minRPM + (maxRPM - minRPM) * min(max(p, 0), 100) / 100 }
    func percent(forRPM rpm: Double) -> Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max((rpm - minRPM) / (maxRPM - minRPM) * 100, 0), 100)
    }
    /// The one clamp used by both app and helper.
    func clamp(_ rpm: Double) -> Double { min(max(rpm, minRPM), maxRPM) }
}
