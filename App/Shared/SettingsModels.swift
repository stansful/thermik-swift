// SettingsModels.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). App-level persisted settings types.
import Foundation
import ThermikCore

enum TemperatureUnitPreference: String, Codable, CaseIterable, Sendable { case system, celsius, fahrenheit }
enum LanguagePreference: String, Codable, CaseIterable, Sendable { case system, english, russian }
enum PopoverDensity: String, Codable, CaseIterable, Sendable { case regular, compact }

/// Menu bar label layout (DES §2.2).
enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    // Case order is the gallery order; raw values are persisted, so existing ones never change.
    case stacked, temp, iconTemp, chip, tempFan, pill, ringTemp, bar, sparkline, gauge, iconOnly
    // Composed presets (drawn from a MenuBarCustomLabel, see `composition(_:)`), then the user's own.
    case iconTempFan, chipTempFan, flameTempFan, stackedIcons, stackedUnits, tempRPM, compact, badgeFan, ringFan
    case cpuGpu, cpuGpuStacked, fanOnly, custom
    var id: String { rawValue }
}

/// Glyph (or small graphic) in front of one value of a composed label.
enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case auto, none
    case thermometer, cpu, memory, drive, battery, flame, heatWaves
    case fan, fanBlades, wind, bolt
    case ring, level, graph                       // graphics drawn from the value (inline layout only)

    /// SF Symbol, or nil for none and the drawn graphics. `auto` picks by what the value is.
    func symbol(for kind: MenuBarMetric) -> String? {
        switch self {
        case .auto:
            switch kind {
            case .temperature: "thermometer.medium"
            case .fanAverage, .fanMax, .fan: "fan.fill"
            case .systemPower: "bolt.fill"
            case .none: nil
            }
        case .none, .ring, .level, .graph: nil
        case .thermometer: "thermometer.medium"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .drive: "internaldrive"
        case .battery: "battery.75percent"
        case .flame: "flame.fill"
        case .heatWaves: "heat.waves"
        case .fan: "fan.fill"
        case .fanBlades: "fanblades.fill"
        case .wind: "wind"
        case .bolt: "bolt.fill"
        }
    }
    var isGraphic: Bool { self == .ring || self == .level || self == .graph }
}

/// One value of a composed label: what it shows and how it is marked.
struct MenuBarLabelItem: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var metric: MenuBarMetric
    var icon: MenuBarIcon = .auto
    /// Short text before the value («ГП», «SSD»); at most `captionLimit` characters.
    var caption = ""
    /// "об/мин" / "Вт" after rpm and power values (temperatures always carry °).
    var showUnit = false
    static let captionLimit = 4
}

/// A label the user builds from 1…4 values (style `.custom`); the composed presets are built from it too.
struct MenuBarCustomLabel: Codable, Hashable, Sendable {
    enum Layout: String, Codable, CaseIterable, Sendable { case inline, stacked }
    enum TextSize: String, Codable, CaseIterable, Sendable { case small, medium, large }
    enum Separator: String, Codable, CaseIterable, Sendable { case space, dot, bar }

    var items: [MenuBarLabelItem]
    var layout: Layout = .inline
    var size: TextSize = .medium
    var bold = true
    var separator: Separator = .space
    /// Everything knocked out of one rounded badge, like the input-source badge.
    var badge = false
    /// Glyphs take their value's colour (with Coloured temperature on).
    var tintIcons = false

    static let maxItems = 4
    /// The starting point of «Свой вариант»: CPU temperature and fan speed, each with its glyph.
    static let standard = MenuBarCustomLabel(items: [
        MenuBarLabelItem(metric: .temperature(.aggregate(.cpuAverage)), icon: .thermometer),
        MenuBarLabelItem(metric: .fanAverage, icon: .fan),
    ])
}

extension MenuBarStyle {
    /// Drawn by the composer from a MenuBarCustomLabel (see `composition(_:)`).
    var isComposed: Bool {
        switch self {
        case .stacked, .temp, .iconTemp, .chip, .tempFan, .pill, .ringTemp, .bar, .sparkline, .gauge, .iconOnly: false
        case .iconTempFan, .chipTempFan, .flameTempFan, .stackedIcons, .stackedUnits, .tempRPM, .compact, .badgeFan, .ringFan,
             .cpuGpu, .cpuGpuStacked, .fanOnly, .custom: true
        }
    }

    /// The label a composed style stands for, filled with the configured values (`custom`: the user's own);
    /// nil for the styles that draw themselves.
    func composition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let t = cfg.primary
        let f: MenuBarMetric = cfg.secondary == .none ? .fanAverage : cfg.secondary
        let cpu = MenuBarMetric.temperature(.aggregate(.cpuAverage)), gpu = MenuBarMetric.temperature(.aggregate(.gpuAverage))
        func item(_ m: MenuBarMetric, _ icon: MenuBarIcon, caption: String = "", unit: Bool = false) -> MenuBarLabelItem {
            MenuBarLabelItem(metric: m, icon: icon, caption: caption, showUnit: unit)
        }
        let preset: MenuBarCustomLabel
        switch self {
        case .iconTempFan: preset = MenuBarCustomLabel(items: [item(t, .thermometer), item(f, .fan)])
        case .chipTempFan: preset = MenuBarCustomLabel(items: [item(t, .cpu), item(f, .fan)])
        case .flameTempFan: preset = MenuBarCustomLabel(items: [item(t, .flame), item(f, .fanBlades)])
        case .stackedIcons: preset = MenuBarCustomLabel(items: [item(t, .thermometer), item(f, .fan)], layout: .stacked)
        case .stackedUnits: preset = MenuBarCustomLabel(items: [item(t, .none), item(f, .none, unit: true)], layout: .stacked)
        case .tempRPM: preset = MenuBarCustomLabel(items: [item(t, .none), item(f, .none, unit: true)])
        case .compact: preset = MenuBarCustomLabel(items: [item(t, .none), item(f, .none)], size: .small, separator: .dot)
        case .badgeFan: preset = MenuBarCustomLabel(items: [item(t, .none), item(f, .fan)], badge: true)
        case .ringFan: preset = MenuBarCustomLabel(items: [item(t, .ring), item(f, .fan)])
        case .cpuGpu:
            preset = MenuBarCustomLabel(items: [item(cpu, .none, caption: String(localized: "CPU")),
                                              item(gpu, .none, caption: String(localized: "GPU"))], separator: .bar)
        case .cpuGpuStacked:
            preset = MenuBarCustomLabel(items: [item(cpu, .none, caption: String(localized: "CPU")),
                                              item(gpu, .none, caption: String(localized: "GPU"))], layout: .stacked)
        case .fanOnly: preset = MenuBarCustomLabel(items: [item(f, .fan)])
        case .custom: return cfg.custom ?? .standard
        case .stacked, .temp, .iconTemp, .chip, .tempFan, .pill, .ringTemp, .bar, .sparkline, .gauge, .iconOnly: return nil
        }
        return preset.withStableIDs()
    }
}

extension MenuBarStyle {
    /// Where «Свой вариант» starts when the user customises this style: its own composition, or the closest one.
    func editableComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel {
        if let c = composition(cfg) { return c.withFreshIDs() }
        let t = cfg.primary, f: MenuBarMetric = cfg.secondary == .none ? .fanAverage : cfg.secondary
        func one(_ icon: MenuBarIcon, badge: Bool = false) -> MenuBarCustomLabel {
            MenuBarCustomLabel(items: [MenuBarLabelItem(metric: t, icon: icon)], badge: badge)
        }
        switch self {
        case .stacked: return MenuBarCustomLabel(items: [MenuBarLabelItem(metric: t, icon: .none), MenuBarLabelItem(metric: f, icon: .fan)],
                                                 layout: .stacked)
        case .tempFan: return MenuBarCustomLabel(items: [MenuBarLabelItem(metric: t, icon: .none), MenuBarLabelItem(metric: f, icon: .fan)])
        case .temp: return one(.none)
        case .iconTemp, .iconOnly: return one(.thermometer)
        case .chip: return one(.cpu)
        case .pill: return one(.none, badge: true)
        case .ringTemp, .gauge: return one(.ring)
        case .bar: return one(.level)
        case .sparkline: return one(.graph)
        default: return .standard
        }
    }

    /// Glyph shown next to an icon choice in the editor (the drawn graphics get a stand-in).
    static func previewSymbol(_ icon: MenuBarIcon, for metric: MenuBarMetric) -> String {
        switch icon {
        case .none: "nosign"
        case .ring: "circle.circle"
        case .level: "chart.bar.fill"
        case .graph: "chart.xyaxis.line"
        default: icon.symbol(for: metric) ?? "wand.and.stars"
        }
    }
}

extension MenuBarCustomLabel {
    /// Index-based ids: presets are rebuilt on every tick and must compare equal.
    func withStableIDs() -> MenuBarCustomLabel {
        var c = self
        for i in c.items.indices { c.items[i].id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(i + 1))) }
        return c
    }
    /// Fresh ids, for a preset copied into «Свой вариант» (its rows are edited by id).
    func withFreshIDs() -> MenuBarCustomLabel {
        var c = self
        for i in c.items.indices { c.items[i].id = UUID() }
        return c
    }
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
    /// «Свой вариант» (style `.custom`). Optional so configurations saved before it existed still decode.
    var custom: MenuBarCustomLabel?
}

/// Per-sensor user overrides, keyed by SensorID.description.
struct SensorOverride: Codable, Hashable, Sendable {
    var name: String?
    var hidden: Bool?
    var pinned: Bool?
}
