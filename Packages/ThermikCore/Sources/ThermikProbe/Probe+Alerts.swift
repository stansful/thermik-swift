// Probe+Alerts.swift — OWNER: Unit 6. `thermik-probe alerts replay`: feeds synthetic 1 Hz series through
// AlertRule.defaultRules with a pure AlertEngine (no notifications, no hardware) and checks the SPEC §5 Unit 6 cases:
// raise after exactly 10 s above, no raise on a single spike, clear below threshold − hysteresis, no second raise
// within the cooldown, one-shot abnormalShutdown. Exits with status 1 when a check fails.
import Foundation
import ThermikCore

extension Probe {
    static func alerts(_ args: [String]) async {
        guard args.first == "replay" else {
            print("usage: thermik-probe alerts replay")
            return
        }
        var replay = AlertReplay()
        replay.ramp()
        replay.spike()
        replay.oscillation()
        replay.cooldown()
        replay.oneShots()
        replay.nonTemperature()
        print("\n\(replay.passed) passed, \(replay.failed) failed")
        if replay.failed > 0 { exit(1) }
    }
}

private struct AlertReplay {
    static let t0 = Date(timeIntervalSince1970: 1_793_016_000)       // 2026-10-26T12:00:00Z (fixed, reproducible)
    static let tp01 = SensorID.smc("Tp01")                            // P-cluster probe
    static let tg0f = SensorID.smc("Tg0f")                            // GPU probe (a cooler second sensor)
    static let anyRule = AlertRule.defaultRules[0].id                 // any sensor > 100 °C for 10 s
    /// The rules as they ship, but with the set the replay checks turned on (every rule ships off since v0.1):
    /// any sensor, abnormal shutdown, battery service, stalled fan and thermal pressure.
    static let replayRules: [AlertRule] = AlertRule.defaultRules.enumerated().map { i, rule in
        var r = rule
        r.enabled = [0, 2, 3, 5, 6].contains(i)
        return r
    }
    var passed = 0
    var failed = 0
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.formatOptions = [.withInternetDateTime]; return f
    }()

    struct Sample {
        var hot: Double? = 60
        var pressure: ThermalPressure = .nominal
        var shutdown: ShutdownVerdict? = nil
        var battery = false
        var stalled: [Int] = []
        var modeChange: FanModeChange? = nil
    }

    /// Runs `seconds` 1 Hz evaluations of `rules` and prints every event; returns them.
    mutating func run(_ title: String, seconds: Int, rules: [AlertRule] = AlertReplay.replayRules,
                      _ sample: (Int) -> Sample) -> [AlertEvent] {
        print("\n== \(title)")
        var engine = AlertEngine()
        var all: [AlertEvent] = []
        for t in 0..<seconds {
            let s = sample(t)
            var values: [SensorID: Double] = [Self.tg0f: 55]
            if let hot = s.hot { values[Self.tp01] = hot }
            let inputs = AlertInputs(date: Self.t0.addingTimeInterval(Double(t)), sensorValues: values,
                                     sensorGroups: [Self.tp01: .cpu, Self.tg0f: .gpu],
                                     aggregates: AggregateValues(values: [.cpuHottest: s.hot ?? 0], sources: [.cpuHottest: Self.tp01]),
                                     stalledFans: s.stalled, fanModeChange: s.modeChange, pressure: s.pressure,
                                     abnormalShutdown: s.shutdown, batteryNeedsService: s.battery)
            for e in engine.evaluate(rules: rules, inputs: inputs) {
                all.append(e)
                let value = e.value.map { String(format: "  value=%.1f °C", $0) } ?? ""
                let sensor = e.sensorID.map { "  sensor=\($0)" } ?? ""
                print("  \(iso.string(from: e.date))  t=+\(offset(e))s  \(e.kind == .raised ? "RAISED " : "CLEARED")  \(e.subject)\(value)\(sensor)")
            }
        }
        if all.isEmpty { print("  (no events)") }
        return all
    }

    func offset(_ e: AlertEvent) -> Int { Int(e.date.timeIntervalSince(Self.t0).rounded()) }

    mutating func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL") \(what)")
        if ok { passed += 1 } else { failed += 1 }
    }

    func events(_ all: [AlertEvent], _ rule: UUID, _ kind: AlertEvent.Kind) -> [AlertEvent] {
        all.filter { $0.ruleID == rule && $0.kind == kind }
    }

    // MARK: Scenarios

    /// 60 °C, ramp +1 °C/s to 105 °C (first sample above 100 °C at t = 61 s), hold, ramp down, 60 °C.
    mutating func ramp() {
        func v(_ t: Int) -> Double {
            switch t {
            case ..<30: return 60
            case 30..<65: return 70 + Double(t - 30)
            case 65..<95: return 105
            case 95..<130: return 105 - Double(t - 95)
            default: return 60
            }
        }
        let all = run("ramp to 105 °C and back (smc:Tp01); rule: any sensor > 100 °C for 10 s, hysteresis 5 °C", seconds: 200) {
            Sample(hot: v($0))
        }
        let firstAbove = (0..<200).first { v($0) > 100 } ?? -1
        let firstBelow = (firstAbove..<200).first { v($0) < 95 } ?? -1
        let raised = events(all, Self.anyRule, .raised)
        let cleared = events(all, Self.anyRule, .cleared)
        check(raised.count == 1 && raised.first.map(offset) == firstAbove + 10,
              "raises exactly 10 s after the first sample above 100 °C (first above t=+\(firstAbove)s, raised t=+\(raised.first.map(offset) ?? -1)s)")
        check(raised.first?.sensorID == Self.tp01, "names the hottest sensor (smc:Tp01)")
        check(cleared.count == 1 && cleared.first.map(offset) == firstBelow,
              "clears on the first sample below 95 °C (t=+\(firstBelow)s), not at 100 °C")
        check(all.filter { $0.ruleID != Self.anyRule }.isEmpty, "no other default rule fires")
    }

    /// A single 104 °C sample among 70 °C.
    mutating func spike() {
        let all = run("single-sample spike to 104 °C", seconds: 60) { Sample(hot: $0 == 20 ? 104 : 70) }
        check(all.isEmpty, "one sample above the threshold does not raise")
    }

    /// 99.5 / 100.5 °C alternating every second for 3 minutes: never 10 s continuously above.
    mutating func oscillation() {
        let all = run("oscillation 99.5 ↔ 100.5 °C every second for 180 s", seconds: 180) {
            Sample(hot: $0.isMultiple(of: 2) ? 99.5 : 100.5)
        }
        check(all.isEmpty, "a series straddling the threshold never raises (the condition must hold 10 s)")
    }

    /// 20 s at 103 °C, 20 s at 90 °C, repeated for 15 min: raise, clear, then nothing until the 600 s cooldown ends.
    mutating func cooldown() {
        let all = run("cooldown: 20 s at 103 °C / 20 s at 90 °C for 15 min", seconds: 900) {
            Sample(hot: $0 % 40 < 20 ? 103 : 90)
        }
        let raised = events(all, Self.anyRule, .raised).map(offset)
        let cleared = events(all, Self.anyRule, .cleared).map(offset)
        check(raised.first == 10, "first raise after 10 s above (t=+\(raised.first ?? -1)s)")
        check(cleared.first == 20, "clears at the first sample below 95 °C (t=+\(cleared.first ?? -1)s)")
        let second = raised.dropFirst().first ?? -1
        check(second >= 610 && !raised.contains { $0 > 10 && $0 < 610 },
              "no second raise within 600 s; next raise at t=+\(second)s (≥ first raise + 600 s)")
        check(second == 610, "the next raise happens as soon as the cooldown ends while the condition holds")
    }

    /// abnormalShutdown is one-shot even when the store keeps passing the verdict; fanModeChanged fires per change.
    mutating func oneShots() {
        let shutdownRule = AlertRule.defaultRules[2].id
        let all = run("one-shot abnormalShutdown (verdict passed on every evaluation)", seconds: 30) { _ in
            Sample(hot: 60, shutdown: .kernelPanic)
        }
        let raised = events(all, shutdownRule, .raised)
        check(raised.count == 1 && raised.first.map(offset) == 0, "abnormalShutdown raises once, on the first evaluation")
        check(events(all, shutdownRule, .cleared).isEmpty, "one-shot subjects never emit .cleared")

        var rules = Self.replayRules
        rules[4].enabled = true                                         // fanModeChanged (off by default)
        let change = FanModeChange(from: .system, to: .max, reason: .user)
        let back = FanModeChange(from: .max, to: .system, reason: .maxAutoRevert)
        let modes = run("fanModeChanged enabled: changes at t=5 s and t=6 s", seconds: 12, rules: rules) { t in
            Sample(hot: 60, modeChange: t == 5 ? change : (t == 6 ? back : nil))
        }
        check(events(modes, rules[4].id, .raised).map(offset) == [5, 6], "fanModeChanged raises once per change")
    }

    /// Thermal pressure heavy 10 s rule, battery service, stalled fan.
    mutating func nonTemperature() {
        let pressureRule = AlertRule.defaultRules[6].id, batteryRule = AlertRule.defaultRules[3].id
        let stallRule = AlertRule.defaultRules[5].id
        let all = run("thermal pressure heavy t=10…34 s; battery service t=0…19 s; fan 1 stalled t=40…99 s", seconds: 120) { t in
            Sample(hot: 60, pressure: (10..<35).contains(t) ? .heavy : .nominal, battery: t < 20, stalled: (40..<100).contains(t) ? [1] : [])
        }
        check(events(all, pressureRule, .raised).map(offset) == [20], "thermalPressure(heavy) raises after 10 s at ≥ heavy")
        check(events(all, pressureRule, .cleared).map(offset) == [35], "…and clears when the pressure drops")
        check(events(all, batteryRule, .raised).map(offset) == [0] && events(all, batteryRule, .cleared).map(offset) == [20],
              "batteryService raises at once (forSeconds 0) and clears when the flag goes away")
        check(events(all, stallRule, .raised).map(offset) == [70] && events(all, stallRule, .cleared).map(offset) == [100],
              "fanStalled raises after 30 s and clears when the fan spins again")
    }
}
