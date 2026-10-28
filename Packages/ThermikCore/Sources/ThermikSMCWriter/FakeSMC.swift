// FakeSMC.swift — Thermik (MIT). HELPER-ONLY module; used by `thermik-probe fans sim` only.
//
// In-memory SMC that models the PUBLICLY DOCUMENTED fan behaviour of each generation (FANS §5, §12), so the real
// FanWriteSequencer / SMCFanController / ThermalSafetyMonitor code runs end to end without hardware and without
// root. It never opens AppleSMC. Behaviour per generation:
//   m4          mode keys read 3 (thermalmonitord "System Mode"); a manual write is refused with 0x82 until
//               Ftst=1 has been in effect for `ftstYieldDelay` (3.5 s), then the mode drops 3 -> 0 and accepts 1.
//               Ftst=0 makes the daemon reclaim every fan (mode 3).
//   m4Refusing  like m4, but the daemon never yields (heavy load): the unlock must time out and clean up.
//   m1Direct    mode 0, Ftst present; a direct manual write sticks.
//   m1Reclaims  mode 0, Ftst present; a direct manual write without Ftst is reclaimed after 1 s.
//   m5          lowercase `F%dmd`, no Ftst; direct writes.
//   intelPreT2  `FS! ` ui16 bitmask, `fpe2` targets, no mode keys.
//   intelT2     `F%dMd` + `flt` targets, no Ftst.
// Optional on any Apple Silicon generation: `refusesReleaseWhileStopped` (M4 Max, macOS 27, observed 2026-10-27)
// refuses `F%dMd=0` with 0x82 while a manual fan stands still, and `spinUpDelay` keeps a fan that was stopped at
// 0 rpm for that long after a target above zero.
// Writes are logged with the simulated time ("t= 3.80 F0Tg=0088b445"), which reproduces the FANS §5.4 trace.
import Foundation
import ThermikSMC

/// Deterministic clock for the simulator: `sleep` advances time instantly.
public final class SimulatedClock: SequencerClock {
    public private(set) var t: Date
    public init(start: Date = Date(timeIntervalSince1970: 0)) { t = start }
    public func now() -> Date { t }
    public func sleep(_ seconds: Double) { t = t.addingTimeInterval(max(0, seconds)) }
    public func advance(_ seconds: Double) { sleep(seconds) }
}

/// `@unchecked Sendable`: every access to the mutable store goes through `lock`; the simulation itself is
/// single-threaded (the probe drives it sequentially). `SMCReading` requires `Sendable`.
public final class FakeSMC: SMCReadWriting, @unchecked Sendable {
    public enum Generation: String, Sendable, CaseIterable {
        case m4, m4Refusing, m1Direct, m1Reclaims, m5, intelPreT2, intelT2
        public var isAppleSilicon: Bool { self != .intelPreT2 && self != .intelT2 }
    }

    public let generation: Generation
    public let fanCount: Int
    public let minRPM: Double
    public let maxRPM: Double
    /// Delay between Ftst=1 and thermalmonitord yielding (m4).
    public var ftstYieldDelay: Double = 3.5
    /// M4 Max: `F%dMd=0` is refused with 0x82 while a manual fan stands still (target 0 after a stop).
    public var refusesReleaseWhileStopped: Bool {
        get { lock.withLock { refuseStoppedRelease } }
        set { lock.withLock { refuseStoppedRelease = newValue } }
    }
    /// A stopped manual fan needs this long to turn again after a target above zero.
    public var spinUpDelay: Double {
        get { lock.withLock { spinUp } }
        set { lock.withLock { spinUp = newValue } }
    }

    private let lock = NSLock()
    private let now: () -> Date
    private let epoch: Date
    private var store: [FourCC: (info: SMCKeyInfo, bytes: [UInt8])] = [:]
    private var ftstSetAt: Date?
    private var directManualAt: [Int: Date] = [:]
    private var refuseStoppedRelease = false
    private var spinUp: Double = 0
    /// When a stopped fan got a target above zero; it turns once `spinUp` has passed.
    private var spinUpStartedAt: [Int: Date] = [:]
    private var log: [String] = []
    private let modeTemplate: String?

    private static let rw: SMCKeyAttributes = [.read, .write, .function]
    private static let ro: SMCKeyAttributes = [.read]

    public init(_ generation: Generation, clock: SimulatedClock, fanCount: Int = 2, minRPM: Double = 1350, maxRPM: Double = 5777) {
        self.generation = generation; self.fanCount = fanCount
        self.minRPM = generation == .intelPreT2 ? 2000 : minRPM
        self.maxRPM = generation == .intelPreT2 ? 6000 : maxRPM
        now = { clock.now() }
        epoch = clock.now()
        switch generation {
        case .intelPreT2: modeTemplate = nil
        case .m5: modeTemplate = FanHardwareProfile.modeLower
        default: modeTemplate = FanHardwareProfile.modeUpper
        }
        put("FNum", .ui8, Self.ro, [UInt8(fanCount)])
        for i in 0..<fanCount {
            if generation == .intelPreT2 {
                put(.fan("F%dMn", i), .fpe2, [.read, .write], fpe2(self.minRPM))
                put(.fan("F%dMx", i), .fpe2, Self.ro, fpe2(self.maxRPM))
                put(.fan("F%dTg", i), .fpe2, [.read, .write], fpe2(self.minRPM))
                put(.fan("F%dAc", i), .fpe2, Self.ro, fpe2(self.minRPM))
            } else {
                put(.fan("F%dMn", i), .flt, Self.ro, SMCCodec.encodeFloat32LE(Float(self.minRPM)))
                put(.fan("F%dMx", i), .flt, [.read, .atomic, .privateWrite], SMCCodec.encodeFloat32LE(Float(self.maxRPM)))
                put(.fan("F%dTg", i), .flt, [.read, .write, .function, .atomic], SMCCodec.encodeFloat32LE(Float(self.minRPM)))
                put(.fan("F%dAc", i), .flt, [.read, .atomic], SMCCodec.encodeFloat32LE(0))
                if generation.isAppleSilicon { put(.fan("F%dDc", i), .flt, Self.ro, SMCCodec.encodeFloat32LE(0)) }
            }
            if let t = modeTemplate {
                let systemHeld = generation == .m4 || generation == .m4Refusing
                put(.fan(t, i), .ui8, Self.rw, [systemHeld ? 3 : 0])         // 3 = System Mode held by thermalmonitord
            }
        }
        switch generation {
        case .m4, .m4Refusing, .m1Direct, .m1Reclaims: put(FanHardwareProfile.ftstKey, .ui8, Self.rw, [0])
        case .intelPreT2: put(FanHardwareProfile.forceBitsKey, .ui16, [.read, .write], [0, 0])
        case .m5, .intelT2: break
        }
        // Keys a write must never reach (not allow-listed even though writable).
        put("FOFC", .ui32, [.read, .write], [0, 0, 0x0c, 0x12])
    }

    // MARK: Simulation controls

    /// Adds or updates a temperature key (`flt` on Apple Silicon, `sp78` on Intel).
    public func setTemperature(_ key: FourCC, _ celsius: Double) {
        lock.withLock {
            if generation.isAppleSilicon {
                store[key] = (SMCKeyInfo(size: 4, type: .flt, attributes: [.read, .atomic]), SMCCodec.encodeFloat32LE(Float(celsius)))
            } else {
                let raw = UInt16(bitPattern: Int16(max(min(celsius * 256, 32767), -32768)))
                store[key] = (SMCKeyInfo(size: 2, type: .sp78, attributes: [.read]), [UInt8(raw >> 8), UInt8(raw & 0xFF)])
            }
        }
    }

    public func removeKey(_ key: FourCC) { _ = lock.withLock { store.removeValue(forKey: key) } }

    /// Another app takes the fans the way TG Pro does on M4: Ftst=1, every mode key 1 (bypasses the firmware model).
    public func simulateForeignController(targetRPM: Double = 2500) {
        lock.withLock {
            if store[FanHardwareProfile.ftstKey] != nil { store[FanHardwareProfile.ftstKey]?.bytes = [1]; ftstSetAt = now() }
            for i in 0..<fanCount {
                if let t = modeTemplate { store[.fan(t, i)]?.bytes = [1] }
                if generation != .intelPreT2 { store[.fan("F%dTg", i)]?.bytes = SMCCodec.encodeFloat32LE(Float(targetRPM)) }
            }
            if generation == .intelPreT2 { store[FanHardwareProfile.forceBitsKey]?.bytes = [0, UInt8((1 << fanCount) - 1)] }
        }
    }

    /// macOS takes one fan back (wake, thermal reclaim): its mode key leaves manual.
    public func simulateReclaim(fan i: Int) {
        lock.withLock {
            guard let t = modeTemplate else { return }
            let held = (generation == .m4 || generation == .m4Refusing) && ftstSetAt == nil
            store[.fan(t, i)]?.bytes = [held ? 3 : 0]
        }
    }

    /// Writes so far, oldest first ("t= 0.00 F0Md=01", or "t= 0.00 F0Md=01 -> 0x82" when refused).
    public var writeLog: [String] { lock.withLock { log } }
    public func appendLog(_ line: String) { lock.withLock { log.append(line) } }
    public func clearLog() { lock.withLock { log.removeAll() } }

    /// Raw byte value of a key (nil when absent), for the trace.
    public func bytes(_ key: FourCC) -> [UInt8]? { lock.withLock { evolveLocked(); return store[key]?.bytes } }

    // MARK: SMCReading / SMCReadWriting

    public func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        try lock.withLock {
            guard let e = store[key] else { throw SMCError.keyNotFound(key) }
            return e.info
        }
    }

    public func readRaw(_ key: FourCC) throws -> (SMCKeyInfo, [UInt8]) {
        try lock.withLock {
            evolveLocked()
            guard let e = store[key] else { throw SMCError.keyNotFound(key) }
            return (e.info, e.bytes)
        }
    }

    public func keyCount() throws -> Int { lock.withLock { store.count } }

    public func key(at index: Int) throws -> FourCC {
        try lock.withLock {
            let keys = store.keys.sorted { $0.rawValue < $1.rawValue }
            guard keys.indices.contains(index) else { throw SMCError.firmware(SMCResultCode.keyIndexRange.rawValue, key: FourCC(rawValue: 0)) }
            return keys[index]
        }
    }

    public func writeRaw(_ key: FourCC, _ bytes: [UInt8]) throws {
        try lock.withLock {
            evolveLocked()
            guard let entry = store[key] else { throw SMCError.keyNotFound(key) }
            guard entry.info.isWritable else { throw SMCError.notWritable(key) }
            guard bytes.count == Int(entry.info.size) else {
                throw SMCError.sizeMismatch(key: key, expected: Int(entry.info.size), actual: bytes.count)
            }
            let stamp = String(format: "t=%5.2f %@=%@", now().timeIntervalSince(epoch), key.description,
                               bytes.map { String(format: "%02x", $0) }.joined())
            if key == FanHardwareProfile.ftstKey {
                if bytes[0] == 1 { ftstSetAt = now() } else {
                    ftstSetAt = nil
                    if generation == .m4 || generation == .m4Refusing, let t = modeTemplate {
                        for i in 0..<fanCount { store[.fan(t, i)]?.bytes = [3] }   // the daemon reclaims every fan
                    }
                }
            } else if let t = modeTemplate, let i = (0..<fanCount).first(where: { FourCC.fan(t, $0) == key }) {
                let cur = entry.bytes[0]
                if bytes[0] == 1 && cur == 3 {
                    log.append(stamp + " -> 0x82")
                    throw SMCError.firmware(SMCResultCode.badCommand.rawValue, key: key)   // kSMCBadCommand in System Mode
                }
                if bytes[0] == 0 && cur == 1 && refuseStoppedRelease && (number(.fan("F%dAc", i)) ?? 0) < 1 {
                    log.append(stamp + " -> 0x82")
                    throw SMCError.firmware(SMCResultCode.badCommand.rawValue, key: key)   // M4 Max: a stopped fan stays manual
                }
                if bytes[0] == 1 { directManualAt[i] = now() }
                if bytes[0] == 0 && (generation == .m4 || generation == .m4Refusing) && ftstSetAt == nil {
                    log.append(stamp)
                    store[key]?.bytes = [3]
                    return
                }
            } else if let i = (0..<fanCount).first(where: { FourCC.fan("F%dTg", $0) == key }), generation.isAppleSilicon,
                      (number(.fan("F%dAc", i)) ?? 0) < 1, (SMCCodec.decode(bytes, as: entry.info).doubleValue ?? 0) >= 1 {
                spinUpStartedAt[i] = now()
            }
            log.append(stamp)
            store[key]?.bytes = bytes
        }
    }

    // MARK: Firmware / daemon model (evaluated lazily on every access, under the lock)

    private func evolveLocked() {
        let t = now()
        for i in 0..<fanCount {
            if let tmpl = modeTemplate, var mode = store[.fan(tmpl, i)]?.bytes {
                // m4: ~3.5 s after Ftst=1 thermalmonitord yields: mode 3 -> 0.
                if generation == .m4, let at = ftstSetAt, t.timeIntervalSince(at) >= ftstYieldDelay, mode[0] == 3 { mode[0] = 0 }
                // m1 variant: without Ftst, a direct manual write is reclaimed after 1 s.
                if generation == .m1Reclaims, mode[0] == 1, ftstSetAt == nil, let at = directManualAt[i], t.timeIntervalSince(at) >= 1 {
                    mode[0] = 0
                }
                store[.fan(tmpl, i)]?.bytes = mode
            }
            updateActualLocked(i)
        }
    }

    /// Fan physics, instantaneous: forced → target; Ftst=1 + mode 0 → held near Mn; otherwise macOS idle (off).
    private func updateActualLocked(_ i: Int) {
        let tg = number(.fan("F%dTg", i)) ?? 0
        let actual: Double
        if generation == .intelPreT2 {
            let fs = store[FanHardwareProfile.forceBitsKey]?.bytes ?? [0, 0]
            let mask = UInt16(fs[0]) << 8 | UInt16(fs[1])
            actual = mask & (1 << UInt16(i)) != 0 ? tg : minRPM
            store[.fan("F%dAc", i)]?.bytes = fpe2(actual)
            return
        }
        let mode = modeTemplate.flatMap { store[.fan($0, i)]?.bytes.first } ?? 0
        if mode == 1, tg >= 1, let at = spinUpStartedAt[i], now().timeIntervalSince(at) < spinUp { actual = 0 }
        else if mode == 1 { actual = tg; if tg >= 1 { spinUpStartedAt[i] = nil } }
        else if ftstSetAt != nil { actual = minRPM }
        else { actual = generation == .intelT2 ? minRPM : 0 }
        store[.fan("F%dAc", i)]?.bytes = SMCCodec.encodeFloat32LE(Float(actual))
        if store[.fan("F%dDc", i)] != nil {
            store[.fan("F%dDc", i)]?.bytes = SMCCodec.encodeFloat32LE(Float(actual / (maxRPM * 1.67)))
        }
    }

    private func number(_ key: FourCC) -> Double? {
        guard let e = store[key] else { return nil }
        return SMCCodec.decode(e.bytes, as: e.info).doubleValue
    }

    private func put(_ k: FourCC, _ t: SMCDataType, _ a: SMCKeyAttributes, _ b: [UInt8]) {
        store[k] = (SMCKeyInfo(size: UInt32(b.count), type: t, attributes: a), b)
    }

    private func fpe2(_ r: Double) -> [UInt8] { let v = UInt16(r * 4); return [UInt8(v >> 8), UInt8(v & 0xFF)] }
}
