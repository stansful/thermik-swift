// AlertModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Alert rules (supersets TG Pro's two thresholds).
import Foundation

public struct AlertRule: Codable, Identifiable, Hashable, Sendable {
    public enum Subject: Codable, Hashable, Sendable {
        case anySensor                          // any visible temperature sensor (smoothed)
        case aggregate(AggregateKind)           // e.g. .cpuHottest
        case group(DisplayGroup)                // hottest visible sensor of a group
        case sensor(SensorID)
        case fanStalled                         // P1
        case fanModeChanged                     // P1
        case thermalPressure(ThermalPressure)   // ≥ level (P1)
        case abnormalShutdown                   // once per boot (P1)
        case batteryService                     // P1
        public var isTemperature: Bool {
            switch self { case .anySensor, .aggregate, .group, .sensor: return true; default: return false }
        }
    }
    public enum Channel: String, Codable, Sendable, CaseIterable { case local, email, webhook }   // email/webhook P2
    public enum Action: String, Codable, Sendable { case setFansMax }                              // P1

    public var id: UUID
    public var subject: Subject
    public var thresholdC: Double?              // temperature subjects (TG range 40…110)
    public var forSeconds: TimeInterval         // must persist this long (TG fires instantly)
    public var hysteresisC: Double              // re-arm only after value < threshold − hysteresis
    public var cooldownSeconds: TimeInterval    // no repeat within this time
    public var channels: Set<Channel>
    public var soundName: String?               // UNNotificationSound(named:); nil = default sound
    public var action: Action?
    public var enabled: Bool

    public init(id: UUID = UUID(), subject: Subject, thresholdC: Double? = nil, forSeconds: TimeInterval = 10,
                hysteresisC: Double = 5, cooldownSeconds: TimeInterval = 600, channels: Set<Channel> = [.local],
                soundName: String? = nil, action: Action? = nil, enabled: Bool = true) {
        self.id = id; self.subject = subject; self.thresholdC = thresholdC; self.forSeconds = forSeconds
        self.hysteresisC = hysteresisC; self.cooldownSeconds = cooldownSeconds; self.channels = channels
        self.soundName = soundName; self.action = action; self.enabled = enabled
    }

    /// Defaults mirror TG Pro (FEAT §8.1). Stable ids so "reset to defaults" is idempotent.
    public static let defaultRules: [AlertRule] = [
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000001")!, subject: .anySensor,
                  thresholdC: 100, forSeconds: 10, enabled: true),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000002")!, subject: .aggregate(.cpuHottest),
                  thresholdC: 95, forSeconds: 30, enabled: false),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000003")!, subject: .abnormalShutdown,
                  forSeconds: 0, cooldownSeconds: 0, enabled: true),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000004")!, subject: .batteryService,
                  forSeconds: 0, cooldownSeconds: 86_400, enabled: true),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000005")!, subject: .fanModeChanged,
                  forSeconds: 0, cooldownSeconds: 0, enabled: false),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000006")!, subject: .fanStalled,
                  forSeconds: 30, cooldownSeconds: 3_600, enabled: true),
        AlertRule(id: UUID(uuidString: "6F1C0001-0000-4000-8000-000000000007")!, subject: .thermalPressure(.heavy),
                  forSeconds: 10, cooldownSeconds: 1_800, enabled: true),
    ]
}

/// Everything the alert engine needs for one evaluation (built by AlertStore from the stores each tick).
public struct AlertInputs: Sendable {
    public var date: Date
    public var sensorValues: [SensorID: Double]          // smoothed, VISIBLE temperature sensors only
    public var sensorGroups: [SensorID: DisplayGroup]
    public var aggregates: AggregateValues
    public var stalledFans: [Int]
    public var fanModeChange: FanModeChange?
    public var pressure: ThermalPressure
    public var abnormalShutdown: ShutdownVerdict?        // set on the first evaluation after launch when abnormal
    public var batteryNeedsService: Bool
    public init(date: Date, sensorValues: [SensorID: Double], sensorGroups: [SensorID: DisplayGroup],
                aggregates: AggregateValues, stalledFans: [Int], fanModeChange: FanModeChange?, pressure: ThermalPressure,
                abnormalShutdown: ShutdownVerdict?, batteryNeedsService: Bool) {
        self.date = date; self.sensorValues = sensorValues; self.sensorGroups = sensorGroups; self.aggregates = aggregates
        self.stalledFans = stalledFans; self.fanModeChange = fanModeChange; self.pressure = pressure
        self.abnormalShutdown = abnormalShutdown; self.batteryNeedsService = batteryNeedsService
    }
}

public struct FanModeChange: Sendable, Hashable, Codable {
    public var from: FanMode
    public var to: FanMode
    public var reason: FanModeChangeReason
    public init(from: FanMode, to: FanMode, reason: FanModeChangeReason) { self.from = from; self.to = to; self.reason = reason }
}

public struct AlertEvent: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable { case raised, cleared }
    public var id: UUID
    public var ruleID: UUID
    public var date: Date
    public var kind: Kind
    public var subject: AlertRule.Subject
    public var value: Double?                 // °C (temperature subjects)
    public var sensorID: SensorID?            // which sensor triggered (anySensor/group)
    public init(id: UUID = UUID(), ruleID: UUID, date: Date, kind: Kind, subject: AlertRule.Subject, value: Double?, sensorID: SensorID?) {
        self.id = id; self.ruleID = ruleID; self.date = date; self.kind = kind; self.subject = subject
        self.value = value; self.sensorID = sensorID
    }
}
