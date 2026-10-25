// FanModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Fan modes, curves, engine plan & commands.
// Only exception: Unit 3 may retune the NUMBERS inside FanPresets.curve(_:).
// Percent semantics everywhere: 0 % == F%dMn (minimum SPINNING speed), 100 % == F%dMx, per fan.
// "Off" is never a manual value — only System (macOS) may stop the fans (FANS §11.1).
import Foundation

/// User-facing mode (explicit; no hidden TG-Pro-style override checkboxes).
public enum FanMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system   // UI "Auto" / "Авто": macOS controls the fans (default, and on every quit/crash)
    case curve    // UI "Curve" / "Кривая"
    case fixed    // UI "Fixed" / "Фиксированная"
    case max      // UI "Max" / "Максимум"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .system: "fan.badge.automatic"; case .curve: "chart.xyaxis.line"; case .fixed: "dial.medium"; case .max: "wind" }
    }
}

public enum PowerSourceKind: String, Codable, Sendable { case ac, battery, ups, unknown }

public struct CurvePoint: Codable, Sendable, Hashable {
    public var celsius: Double
    public var percent: Double          // 0…100
    public init(_ celsius: Double, _ percent: Double) { self.celsius = celsius; self.percent = percent }
}

/// Asymmetric EMA on the control temperature (fast up, slow down), seconds.
public struct Smoothing: Codable, Sendable, Hashable {
    public var riseTau: Double
    public var fallTau: Double
    public init(riseTau: Double = 2, fallTau: Double = 12) { self.riseTau = riseTau; self.fallTau = fallTau }
}

/// Slew limits in %/s and hold-before-decrease. UI shows ramp TIMES: rampUp = 100/up, rampDown = 100/down.
public struct Slew: Codable, Sendable, Hashable {
    public var upPercentPerSecond: Double
    public var downPercentPerSecond: Double
    public var downHoldSeconds: Double
    public init(up: Double = 25, down: Double = 2, hold: Double = 30) {
        upPercentPerSecond = up; downPercentPerSecond = down; downHoldSeconds = hold
    }
}

/// Engine strategy per fan (FANS §11.2). New cases may be APPENDED later (Codable stays compatible).
public enum FanStrategy: Codable, Sendable, Hashable {
    case system
    case fixedRPM(Double)
    case fixedPercent(Double)
    /// System until sensor ≥ threshold, then 100 % until < threshold − hysteresis AND minHold elapsed.
    case autoMax(sensor: TemperatureSource, thresholdC: Double, hysteresisC: Double, minHoldSeconds: Double)
    /// System below lowC; linear lowC…highC → min…max %; changes slewed so 0→100 % takes gradualSeconds.
    case autoBoost(sensor: TemperatureSource, lowC: Double, highC: Double, minPercent: Double, maxPercent: Double,
                   gradualSeconds: Double, hysteresisC: Double)
    /// Piecewise-linear curve; below the first point: System if releaseBelowFirstPoint, else first percent.
    case curve(sensor: TemperatureSource, points: [CurvePoint], hysteresisC: Double,
               releaseBelowFirstPoint: Bool, smoothing: Smoothing, slew: Slew)
}

/// App-engine safety (FANS §11.3). Helper has its own, higher thresholds (ThermikHelper.Safety).
public struct SafetyConfig: Codable, Sendable, Hashable {
    public var criticalC: Double = 100           // smoothed AggregateKind.safetyTop4
    public var rawCriticalC: Double = 105        // instantaneous AggregateKind.rawHottestDie
    public var hysteresisC: Double = 6
    public var fixedModeFloor = true             // fixed speeds ramp toward 100 % in the last 10 °C before critical
    public init() {}
}

/// Thermal guard (P1, FEAT §6.6): pressure-based floor on top of any forced mode.
public struct ThermalGuardConfig: Codable, Sendable, Hashable {
    public var enabled = false
    public var moderateFloorPercent: Double = 70
    public var heavyPercent: Double = 100
    public var engageAfterSeconds: Double = 5
    public var releaseAfterSeconds: Double = 30
    /// Also take control while the user is in System mode (default off: never take control unasked).
    public var applyInSystemMode = false
    public init() {}
}

/// Complete engine input for one tick.
public struct FanPlan: Codable, Sendable, Hashable {
    public var linked: Bool = true               // one strategy for all fans (percent mapped per fan's own range)
    public var shared: FanStrategy = .system
    public var perFan: [Int: FanStrategy] = [:]  // used when !linked; missing == .system
    public var safety = SafetyConfig()
    public var thermalGuard = ThermalGuardConfig()
    public init() {}
    public func strategy(for fan: Int) -> FanStrategy { linked ? shared : (perFan[fan] ?? .system) }
    /// Every TemperatureSource the plan reads (the store resolves exactly these each tick).
    public var referencedSources: Set<TemperatureSource> {
        var s: Set<TemperatureSource> = [.aggregate(.safetyTop4), .aggregate(.rawHottestDie)]
        for st in [shared] + Array(perFan.values) {
            switch st {
            case .autoMax(let src, _, _, _), .autoBoost(let src, _, _, _, _, _, _), .curve(let src, _, _, _, _, _): s.insert(src)
            default: break
            }
        }
        return s
    }
}

public enum FanCommand: Sendable, Equatable, Hashable, CustomStringConvertible {
    case system
    case rpm(Double)
    public var description: String { switch self { case .system: return "system"; case .rpm(let r): return String(format: "%.0f rpm", r) } }
}

public enum FanPresetID: String, Codable, Sendable, CaseIterable, Identifiable {
    case quiet, balanced, cool, performance
    public var id: String { rawValue }
}

/// User-editable curve (persisted). `strategy` converts it for the engine.
public struct FanCurve: Codable, Sendable, Hashable {
    public var input: TemperatureSource
    public var points: [CurvePoint]
    public var hysteresisC: Double
    public var releaseBelowFirstPoint: Bool
    public var smoothing: Smoothing
    public var slew: Slew
    public var presetID: FanPresetID?            // nil = custom (edited)
    public init(input: TemperatureSource, points: [CurvePoint], hysteresisC: Double = 3, releaseBelowFirstPoint: Bool = true,
                smoothing: Smoothing = Smoothing(), slew: Slew = Slew(), presetID: FanPresetID? = nil) {
        self.input = input; self.points = points; self.hysteresisC = hysteresisC
        self.releaseBelowFirstPoint = releaseBelowFirstPoint; self.smoothing = smoothing; self.slew = slew; self.presetID = presetID
    }
    public var strategy: FanStrategy {
        .curve(sensor: input, points: points, hysteresisC: hysteresisC, releaseBelowFirstPoint: releaseBelowFirstPoint,
               smoothing: smoothing, slew: slew)
    }
}

/// PROVISIONAL presets tuned to M4 Max reality (idle CPU average ≈ 60–68 °C, all-core load ≈ 77–80 °C,
/// cluster hotspots ≈ 90–99 °C; SENS §5.1/§5.4). Unit 3 may retune the NUMBERS after a ≤ 60 s load test;
/// the API is frozen.
public enum FanPresets {
    public static func curve(_ id: FanPresetID) -> FanCurve {
        switch id {
        case .quiet:
            return FanCurve(input: .aggregate(.cpuAverage),
                            points: [CurvePoint(68, 0), CurvePoint(80, 20), CurvePoint(90, 55), CurvePoint(97, 100)],
                            hysteresisC: 4, releaseBelowFirstPoint: true, smoothing: Smoothing(riseTau: 3, fallTau: 15),
                            slew: Slew(up: 100.0 / 6, down: 100.0 / 60, hold: 30), presetID: .quiet)
        case .balanced:
            return FanCurve(input: .aggregate(.socHottest),
                            points: [CurvePoint(62, 0), CurvePoint(75, 30), CurvePoint(85, 65), CurvePoint(94, 100)],
                            hysteresisC: 3, releaseBelowFirstPoint: true, smoothing: Smoothing(riseTau: 2, fallTau: 12),
                            slew: Slew(up: 25, down: 2, hold: 30), presetID: .balanced)
        case .cool:
            return FanCurve(input: .aggregate(.socHottest),
                            points: [CurvePoint(55, 10), CurvePoint(68, 40), CurvePoint(78, 75), CurvePoint(88, 100)],
                            hysteresisC: 3, releaseBelowFirstPoint: false, smoothing: Smoothing(riseTau: 1.5, fallTau: 10),
                            slew: Slew(up: 100.0 / 3, down: 100.0 / 40, hold: 20), presetID: .cool)
        case .performance:
            return FanCurve(input: .aggregate(.safetyTop4),
                            points: [CurvePoint(50, 25), CurvePoint(62, 55), CurvePoint(72, 85), CurvePoint(82, 100)],
                            hysteresisC: 2, releaseBelowFirstPoint: false, smoothing: Smoothing(riseTau: 1, fallTau: 8),
                            slew: Slew(up: 50, down: 100.0 / 30, hold: 20), presetID: .performance)
        }
    }
}

/// Persisted fan settings (SettingsStore key `fans.config`).
public struct FanUserConfig: Codable, Sendable, Hashable {
    public var mode: FanMode = .system
    public var linked: Bool = true
    public var fixedPercent: Double = 50                 // linked Fixed
    public var fixedPercentPerFan: [Int: Double] = [:]   // unlinked Fixed
    public var curveAC: FanCurve = FanPresets.curve(.balanced)
    public var curveBattery: FanCurve? = nil             // P1: nil = use curveAC on battery too
    public var maxAutoRevertMinutes: Int? = 30           // nil = never
    public var thermalGuard = ThermalGuardConfig()       // P1
    public var safety = SafetyConfig()
    /// false (default): every launch starts in System and the user re-selects; true: re-apply `mode` at launch.
    public var restoreModeOnLaunch = false
    public init() {}
}

public enum FanModeChangeReason: String, Codable, Sendable {
    case user, launch, maxAutoRevert, safety, foreignController, helperUnavailable, notificationAction, shortcut, urlScheme, sleep
}

/// What FanStore reports to the UI.
public enum FanControlStatus: Sendable, Equatable {
    case fanless                                   // FNum == 0 → monitoring only, fan UI hidden
    case monitoringOnly(HelperAvailability)        // helper missing / needs approval / unreachable
    case system                                    // helper ready, mode System, macOS in charge
    case engaging                                  // first manual command in flight (Ftst unlock may take ~3–6 s)
    case active                                    // Thermik holds the fans (◆ badge)
    case safetyOverride(temperatureC: Double)      // engine or helper forced max
    case foreignController(name: String?)          // another app forces the fans; we refuse to fight
    case error(String)
}

public enum HelperAvailability: String, Sendable, Equatable, Codable {
    case notInstalled, requiresApproval, needsUpgrade, unreachable, connecting
}
