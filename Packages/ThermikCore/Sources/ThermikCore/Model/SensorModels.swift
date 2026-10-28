// SensorModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Sensor identity, catalog and grouping.
import Foundation

public enum Quantity: String, Codable, Sendable, CaseIterable { case temperature, power, voltage, current, fanRPM }

public enum SensorSource: String, Codable, Sendable { case smc, hid }

/// Stable across launches → used in settings, CSV headers, history series and URLs.
public struct SensorID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let source: SensorSource
    /// SMC FourCC ("Tp01", trailing spaces kept) or HID product name ("PMU tdie1").
    public let key: String
    public init(source: SensorSource, key: String) { self.source = source; self.key = key }
    public static func smc(_ key: String) -> SensorID { SensorID(source: .smc, key: key) }
    public static func hid(_ product: String) -> SensorID { SensorID(source: .hid, key: product) }

    /// "smc:Tp01", "hid:PMU tdie1".
    public var description: String { "\(source.rawValue):\(key)" }
    public init?(_ string: String) {
        guard let colon = string.firstIndex(of: ":"),
              let src = SensorSource(rawValue: String(string[..<colon])) else { return nil }
        self.init(source: src, key: String(string[string.index(after: colon)...]))
    }
    /// DB descriptor key → id: "Tp01" → smc, "hid:PMU tdie1" → hid.
    public init(databaseKey: String) {
        if databaseKey.hasPrefix("hid:") { self.init(source: .hid, key: String(databaseKey.dropFirst(4))) }
        else { self.init(source: .smc, key: databaseKey) }
    }
    public static func < (a: SensorID, b: SensorID) -> Bool { a.description < b.description }
}

/// Hardware block a key belongs to (SENS §8.2). Drives grouping, colour class and sanity range.
public enum SensorGroup: String, Codable, Sendable, CaseIterable {
    case cpuPerformance, cpuEfficiency, cpuFabric, cpuAggregate
    case gpu, gpuAggregate, socFabric, soc, memory
    case battery, storage, wireless, enclosure, airflow, ports
    case powerDelivery, board, virtual, other

    /// Per-class colour scale (DES §7.3.2).
    public var thermalClass: ThermalClass {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpuFabric, .cpuAggregate, .gpu, .gpuAggregate,
             .socFabric, .soc, .memory, .virtual: return .soc
        case .powerDelivery, .wireless, .board, .other: return .power
        case .storage, .ports, .airflow: return .storage
        case .battery: return .battery
        case .enclosure: return .ambient
        }
    }

    /// Plausible range (SENS §7). Die sensors are never < 10 °C while the Mac runs; ambient-like ones can be cold.
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .battery, .enclosure, .airflow, .ports, .wireless, .storage, .board: return -20...100
        default: return 10...130
        }
    }

    /// Exactly 40.0 is the M4 "not sampled yet" placeholder on these groups (SENS §5.3).
    public var rejectsExact40: Bool { self == .cpuPerformance || self == .cpuAggregate || self == .cpuFabric }
}

/// What a key IS (SENS §8.4). Only probe/calibrated feed averages; hotspot/maximum feed maxima.
public enum SensorRole: String, Codable, Sendable, CaseIterable {
    case probe        // independent measurement (default)
    case calibrated   // == another probe + constant offset (2nd key of an Apple-Silicon triplet) → DISPLAY this
    case hotspot      // spatial max of a zone (3rd key of a triplet)
    case average      // firmware-computed average
    case maximum      // firmware-computed max across sensors
    case peakHold     // running max since boot (Tf?6) — NEVER show as current
    case reference    // fixed calibration value (TR0Z, PMU tcal)
    case duplicate    // byte-identical mirror of another key
    case unused       // constant 0 / constant garbage on this SKU

    public var feedsAverages: Bool { self == .probe || self == .calibrated }
    public var feedsMaxima: Bool { self == .probe || self == .calibrated || self == .hotspot || self == .maximum }
    /// Never listed, even with "show hidden sensors".
    public var isNeverShown: Bool { self == .peakHold || self == .reference || self == .unused }
}

/// Colour-scale class (DES §7.3.2): °C at the 7 ramp stops frost…critical. Each stop is also where its level begins
/// (the app's ThermalScale.level): with the CPU/GPU defaults "Hot" starts at 65 °C and "Critical" at 85 °C.
/// Users retune them in Settings › Appearance › Colour scale.
public enum ThermalClass: String, Codable, Sendable, CaseIterable {
    case soc, power, storage, battery, ambient
    public var stops: [Double] {
        switch self {
        case .soc, .power: return [30, 45, 50, 55, 65, 75, 85]
        case .storage:     return [25, 35, 50, 55, 65, 75, 85]
        case .battery:     return [20, 28, 33, 38, 42, 46, 50]
        case .ambient:     return [15, 22, 28, 34, 38, 42, 46]
        }
    }
}

/// UI grouping (sidebar chips, popover sections). Many SensorGroups → one DisplayGroup.
public enum DisplayGroup: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, soc, memory, storage, battery, power, enclosure, ports, wireless, other
    public init(_ g: SensorGroup) {
        switch g {
        case .cpuPerformance, .cpuEfficiency, .cpuFabric, .cpuAggregate: self = .cpu
        case .gpu, .gpuAggregate: self = .gpu
        case .socFabric, .soc: self = .soc
        case .memory: self = .memory
        case .storage: self = .storage
        case .battery: self = .battery
        case .powerDelivery: self = .power
        case .enclosure, .airflow: self = .enclosure
        case .ports: self = .ports
        case .wireless: self = .wireless
        case .board, .virtual, .other: self = .other
        }
    }
    /// SF Symbol (DES §5.1; there is no `gpu` symbol).
    public var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d"
        case .soc: return "cpu.fill"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .battery: return "battery.75percent"
        case .power: return "bolt"
        case .enclosure: return "wind"
        case .ports: return "cable.connector"
        case .wireless: return "wifi"
        case .other: return "square.grid.2x2"
        }
    }
}

/// One entry of a per-chip JSON database (schema 1, §3.3).
public struct SensorDescriptor: Codable, Sendable, Hashable {
    public var key: String                 // SMC FourCC, or "hid:<Product>" for HID-only sensors
    public var name: String                // English UI name
    public var nameRu: String?             // Russian UI name
    public var group: SensorGroup
    public var role: SensorRole
    public var cluster: Int?               // P/E cluster index when meaningful (0-based)
    public var visible: Bool               // shown in the default sensor lists
    public var invalidValues: [Double]?    // exact sentinels to drop (e.g. 40.0)
    public init(key: String, name: String, nameRu: String? = nil, group: SensorGroup, role: SensorRole = .probe,
                cluster: Int? = nil, visible: Bool = true, invalidValues: [Double]? = nil) {
        self.key = key; self.name = name; self.nameRu = nameRu; self.group = group; self.role = role
        self.cluster = cluster; self.visible = visible; self.invalidValues = invalidValues
    }
}

/// Optional approximate die position for the chip thermal map (P1), unit square of the die.
public struct DieLayoutPoint: Codable, Sendable, Hashable {
    public var key: String
    public var x: Double
    public var y: Double
    public init(key: String, x: Double, y: Double) { self.key = key; self.x = x; self.y = y }
}

/// Named key sets inside a DB `headline` object.
public enum HeadlineSet: String, Codable, Sendable, CaseIterable {
    case cpu            // calibrated P+E probes → CPU average (EMA)
    case cpuHotspot     // firmware cluster maxima → CPU hottest
    case gpu            // calibrated GPU probes → GPU average / hottest
    case soc            // die average (TCMb)
    case memory, battery, ssd
    case safety         // OPTIONAL override of the safety set (default: cpuHotspot ∪ gpu)
}

/// Per-chip database file `Resources/SensorDB/<platform-name>.json` (schema 1).
public struct ChipSensorDatabase: Codable, Sendable {
    public var schema: Int
    public var platform: String            // IORegistry IOPlatformExpertDevice "platform-name", e.g. "t6041"; "intel"
    public var chip: String                // "Apple M4 Max"
    public var verified: Bool              // true only after a load test on real hardware
    public var observedOn: [String]?       // ["Mac16,5"]
    public var note: String?
    public var headline: [String: [String]]// HeadlineSet.rawValue → DB keys
    public var sensors: [SensorDescriptor]
    public var dieLayout: [DieLayoutPoint]?   // optional (P1)
    public var fanNames: [String]?            // optional English fan names by index, e.g. ["Left", "Right"]
    public var fanNamesRu: [String]?
    public func headlineKeys(_ set: HeadlineSet) -> [String] { headline[set.rawValue] ?? [] }
}

/// How the catalog for this Mac was built.
public enum CatalogStatus: Sendable, Equatable, Codable {
    case verified(platform: String)        // DB present and verified
    case unverified(platform: String)      // DB present, not yet load-tested
    case heuristic(platform: String)       // no DB: prefix heuristics (show "approximate names" banner)
}

/// Chip / board identity (SENS §8.3).
public struct ChipIdentity: Sendable, Equatable, Codable {
    public var platformName: String        // "t6041"; "intel" when absent
    public var targetType: String?         // "J616c"
    public var modelIdentifier: String     // "Mac16,5"
    public var chipName: String            // "Apple M4 Max"
    public var isAppleSilicon: Bool
    public var smcPlatform: String?        // SMC RPlt, e.g. "j616c"
    public init(platformName: String, targetType: String?, modelIdentifier: String, chipName: String,
                isAppleSilicon: Bool, smcPlatform: String?) {
        self.platformName = platformName; self.targetType = targetType; self.modelIdentifier = modelIdentifier
        self.chipName = chipName; self.isAppleSilicon = isAppleSilicon; self.smcPlatform = smcPlatform
    }
}

/// A discovered sensor at runtime.
public struct Sensor: Identifiable, Sendable, Hashable {
    public let id: SensorID
    public let quantity: Quantity
    public let descriptor: SensorDescriptor
    public let smcType: String?            // "flt ", "ioft", "sp78" — for the inspector
    public let isHeuristic: Bool           // not from a DB entry
    public init(id: SensorID, quantity: Quantity, descriptor: SensorDescriptor, smcType: String?, isHeuristic: Bool) {
        self.id = id; self.quantity = quantity; self.descriptor = descriptor; self.smcType = smcType; self.isHeuristic = isHeuristic
    }
    public var group: SensorGroup { descriptor.group }
    public var role: SensorRole { descriptor.role }
    public var displayGroup: DisplayGroup { DisplayGroup(descriptor.group) }
    public var thermalClass: ThermalClass { descriptor.group.thermalClass }
    public var isVisibleByDefault: Bool { descriptor.visible && !descriptor.role.isNeverShown }
    /// Localized DB name: Russian when the preferred language is Russian and nameRu exists.
    public func name(preferRussian: Bool) -> String { preferRussian ? (descriptor.nameRu ?? descriptor.name) : descriptor.name }
}
