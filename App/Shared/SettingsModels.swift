// SettingsModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). App-level persisted settings types.
import Foundation
import ThermikCore

enum TemperatureUnitPreference: String, Codable, CaseIterable, Sendable { case system, celsius, fahrenheit }
enum LanguagePreference: String, Codable, CaseIterable, Sendable { case system, english, russian }
enum PopoverDensity: String, Codable, CaseIterable, Sendable { case regular, compact }

/// Menu bar label layout (DES §2.2).
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly, temp, iconTemp, tempFan, stacked, gauge
    var id: String { rawValue }
}

/// What a menu bar slot shows.
enum MenuBarMetric: Codable, Hashable, Sendable {
    case temperature(TemperatureSource)
    case fanAverage, fanMax
    case fan(Int)
    case systemPower
    case none
}

struct MenuBarConfig: Codable, Hashable, Sendable {
    var style: MenuBarStyle = .stacked                              // `.temp` is used automatically on fanless Macs
    var primary: MenuBarMetric = .temperature(.aggregate(.cpuAverage))
    var secondary: MenuBarMetric = .fanAverage
    var colored = false                                             // template (monochrome) by default
    var alertColor = true                                           // colour while an alert / critical level is active
    var showOverrideBadge = true                                    // ◆ while Thermik forces the fans
    var warnWhenHidden = true
}

/// Per-sensor user overrides, keyed by SensorID.description.
struct SensorOverride: Codable, Hashable, Sendable {
    var name: String?
    var hidden: Bool?
    var pinned: Bool?
}
