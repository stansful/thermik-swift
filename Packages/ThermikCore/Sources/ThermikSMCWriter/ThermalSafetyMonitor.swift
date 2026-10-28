// ThermalSafetyMonitor.swift — Thermik (MIT). HELPER ONLY. Last-resort thermal check while Thermik holds the fans
// (invariants I8 and I9, SPEC §2.6.2–2.6.3). Deliberately independent of the app: its own key set, its own
// thresholds (ThermikHelper.Safety: 103 / 108 °C, release < 95 °C), ABOVE the app engine's 100 / 105 °C.
//
// Die set (SPEC §2.6.3 correction to the FANS draft): `Tp*`, `Te*`, `Tg*` of type `flt ` on Apple Silicon,
// `TC*`, `TG*` (`sp78` / `flt `) on Intel. The draft also scanned `Tf Tm Ts`, which on M4 Max includes the `Tf?6`
// peak-hold keys (constant 79–93 °C) — its "top-4 = 91 °C at idle" was that artifact.
//
// Value rules (measured on Mac16,5, SENS §2.4): a power-gated P-cluster reads the triplet (-4.0, -4.0 + offset, 0.0),
// right after wake every probe reads exactly 40.0, so values that are not finite, < 10, > 130 or exactly 40.0 are
// dropped; so is any key whose non-zero value has not changed for 30 s (setpoint, not a reading).
//
// Key budget: at most 96 keys, read once per watchdog tick (1 Hz) and only while controlling. M4 Max exposes 156
// candidates (Tp 102, Tg 44, Te 10), so the selection keeps every firmware cluster aggregate (third character
// `x`: Tpx?, Tex? — they carry each cluster's maximum) and fills the rest round-robin across families, so no
// cluster is left uncovered by index order.
import Foundation
import ThermikSMC
import ThermikHelperShared

public final class ThermalSafetyMonitor {
    public struct Thresholds: Sendable, Equatable {
        public var overrideTop4MeanC = ThermikHelper.Safety.overrideTop4MeanC
        public var overrideHottestC = ThermikHelper.Safety.overrideHottestC
        public var releaseTop4MeanC = ThermikHelper.Safety.releaseTop4MeanC
        public var sensorFailureTicks = ThermikHelper.Safety.sensorFailureTicks
        public var staticKeySeconds = ThermikHelper.Safety.staticKeySeconds
        public var validRange: ClosedRange<Double> = 10...130
        /// "Not sampled yet" placeholder of M4 P-cluster probes.
        public var placeholderValue: Double = 40.0
        public init() {}
    }

    public static let maxKeys = 96

    public let thresholds: Thresholds
    public private(set) var overrideActive = false
    public private(set) var lastHottestC: Double?
    public private(set) var lastTop4MeanC: Double?

    private let smc: any SMCReading
    private let appleSilicon: Bool
    private let clock: any SequencerClock
    private var discovered: [FourCC]?
    private var consecutiveFailures = 0
    /// Last value of each key and when it last changed (static-key rule).
    private var lastValue: [FourCC: (value: Double, changedAt: Date)] = [:]

    public init(smc: any SMCReading, appleSilicon: Bool = HostInfo.isAppleSilicon,
                clock: any SequencerClock = SystemSequencerClock(), thresholds: Thresholds = Thresholds()) {
        self.smc = smc; self.appleSilicon = appleSilicon; self.clock = clock; self.thresholds = thresholds
    }

    /// The keys this monitor reads (discovered lazily on first use: ~10 ms of key enumeration).
    public var monitoredKeys: [FourCC] {
        if let d = discovered { return d }
        let d = Self.discoverKeys(smc, appleSilicon: appleSilicon)
        discovered = d
        return d
    }

    /// Candidate families and accepted types.
    static func families(appleSilicon: Bool) -> (prefixes: [String], types: Set<SMCDataType>) {
        appleSilicon ? (["Tp", "Te", "Tg"], [.flt]) : (["TC", "TG"], [.sp78, .flt])
    }

    static func discoverKeys(_ smc: any SMCReading, appleSilicon: Bool) -> [FourCC] {
        let (prefixes, types) = families(appleSilicon: appleSilicon)
        guard let n = try? smc.keyCount(), n > 0 else { return [] }
        var candidates: [FourCC] = []
        for i in 0..<n {
            guard let k = try? smc.key(at: i) else { continue }
            let name = k.description
            guard prefixes.contains(where: { name.hasPrefix($0) }),
                  let info = try? smc.keyInfo(k), types.contains(info.type), info.isReadable else { continue }
            candidates.append(k)
        }
        return selectKeys(candidates, prefixes: prefixes, limit: maxKeys)
    }

    /// Cluster aggregates first, then round-robin across families (index order inside a family).
    public static func selectKeys(_ candidates: [FourCC], prefixes: [String], limit: Int) -> [FourCC] {
        guard candidates.count > limit else { return candidates }
        func isAggregate(_ k: FourCC) -> Bool { let c = Array(k.description); return c.count == 4 && c[2] == "x" }
        var out = Array(candidates.filter(isAggregate).prefix(limit))
        var queues = prefixes.map { p in candidates.filter { $0.description.hasPrefix(p) && !isAggregate($0) } }
        while out.count < limit, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where out.count < limit && !queues[i].isEmpty {
                out.append(queues[i].removeFirst())
            }
        }
        return out
    }

    /// Forget per-key history and the failure counter (call when control ends, so the next session starts clean).
    public func reset() {
        overrideActive = false
        consecutiveFailures = 0
        lastValue.removeAll()
        lastHottestC = nil
        lastTop4MeanC = nil
    }

    /// One watchdog tick (1 Hz while controlling).
    /// The hottest plausible die reading now; no latch or static-key bookkeeping (a fan-stop check, not I8).
    public func readHottest() -> Double? {
        monitoredKeys.compactMap { k -> Double? in
            guard let v = try? smc.readNumber(k), v.isFinite, thresholds.validRange.contains(v),
                  v != thresholds.placeholderValue else { return nil }
            return v
        }.max()
    }

    public func evaluate() -> SafetyVerdict {
        let keys = monitoredKeys
        guard !keys.isEmpty else { return .normal(hottestC: nil) }   // no die sensors known: rely on the app + macOS
        let now = clock.now()
        var values: [Double] = []
        values.reserveCapacity(keys.count)
        for k in keys {
            guard let v = try? smc.readNumber(k), v.isFinite, thresholds.validRange.contains(v),
                  v != thresholds.placeholderValue else { continue }
            if let prev = lastValue[k], abs(prev.value - v) < 0.0005 {
                if now.timeIntervalSince(prev.changedAt) > thresholds.staticKeySeconds { continue }   // static setpoint
            } else {
                lastValue[k] = (v, now)
            }
            values.append(v)
        }
        if values.isEmpty {
            consecutiveFailures += 1
            if consecutiveFailures >= thresholds.sensorFailureTicks { return .sensorFailure }       // I9
            if overrideActive, let h = lastHottestC, let m = lastTop4MeanC { return .override(hottestC: h, top4MeanC: m) }
            return .normal(hottestC: nil)
        }
        consecutiveFailures = 0
        values.sort(by: >)
        let hottest = values[0]
        let top = values.prefix(4)
        let top4 = top.reduce(0, +) / Double(top.count)
        lastHottestC = hottest
        lastTop4MeanC = top4
        if top4 >= thresholds.overrideTop4MeanC || hottest >= thresholds.overrideHottestC { overrideActive = true }   // I8
        else if overrideActive && top4 < thresholds.releaseTop4MeanC { overrideActive = false }
        return overrideActive ? .override(hottestC: hottest, top4MeanC: top4) : .normal(hottestC: hottest)
    }
}
