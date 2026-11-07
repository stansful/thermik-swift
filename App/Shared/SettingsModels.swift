// SettingsModels.swift — Thermik (MIT). App-level persisted settings types.
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

    private static let fixedSymbols: [MenuBarIcon: String] = [
        .thermometer: "thermometer.medium", .cpu: "cpu", .memory: "memorychip", .drive: "internaldrive",
        .battery: "battery.75percent", .flame: "flame.fill", .heatWaves: "heat.waves", .fan: "fan.fill",
        .fanBlades: "fanblades.fill", .wind: "wind", .bolt: "bolt.fill",
    ]

    /// SF Symbol, or nil for none and the drawn graphics. `auto` picks by what the value is.
    func symbol(for kind: MenuBarMetric) -> String? {
        switch self {
        case .auto: automaticSymbol(for: kind)
        case .none, .ring, .level, .graph: nil
        default: Self.fixedSymbols[self]
        }
    }

    private func automaticSymbol(for kind: MenuBarMetric) -> String? {
        switch kind {
        case .temperature: "thermometer.medium"
        case .fanAverage, .fanMax, .fan: "fan.fill"
        case .systemPower: "bolt.fill"
        case .none: nil
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
        switch self {
        case .custom: return cfg.custom ?? .standard
        case .stacked, .temp, .iconTemp, .chip, .tempFan, .pill, .ringTemp, .bar, .sparkline, .gauge, .iconOnly: return nil
        case .fanOnly:
            let (_, fan) = configuredMetrics(cfg)
            return MenuBarCustomLabel(items: [item(fan, .fan)]).withStableIDs()
        default: return composedPreset(cfg)?.withStableIDs()
        }
    }

    private func composedPreset(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        if let preset = decoratedTemperatureAndFanComposition(cfg) { return preset }
        if let preset = plainTemperatureAndFanComposition(cfg) { return preset }
        return processorComposition()
    }

    private func decoratedTemperatureAndFanComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let (temperature, fan) = configuredMetrics(cfg)
        switch self {
        case .iconTempFan: return MenuBarCustomLabel(items: [item(temperature, .thermometer), item(fan, .fan)])
        case .chipTempFan: return MenuBarCustomLabel(items: [item(temperature, .cpu), item(fan, .fan)])
        case .flameTempFan: return MenuBarCustomLabel(items: [item(temperature, .flame), item(fan, .fanBlades)])
        case .badgeFan: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .fan)], badge: true)
        case .ringFan: return MenuBarCustomLabel(items: [item(temperature, .ring), item(fan, .fan)])
        default: return nil
        }
    }

    private func plainTemperatureAndFanComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let (temperature, fan) = configuredMetrics(cfg)
        switch self {
        case .stackedIcons: return MenuBarCustomLabel(items: [item(temperature, .thermometer), item(fan, .fan)], layout: .stacked)
        case .stackedUnits: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .none, showUnit: true)], layout: .stacked)
        case .tempRPM: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .none, showUnit: true)])
        case .compact: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .none)], size: .small, separator: .dot)
        default: return nil
        }
    }

    private func processorComposition() -> MenuBarCustomLabel? {
        let items = processorItems()
        switch self {
        case .cpuGpu: return MenuBarCustomLabel(items: items, separator: .bar)
        case .cpuGpuStacked: return MenuBarCustomLabel(items: items, layout: .stacked)
        default: return nil
        }
    }

    private func processorItems() -> [MenuBarLabelItem] {
        let cpu = MenuBarMetric.temperature(.aggregate(.cpuAverage))
        let gpu = MenuBarMetric.temperature(.aggregate(.gpuAverage))
        return [item(cpu, .none, caption: String(localized: "CPU")),
                item(gpu, .none, caption: String(localized: "GPU"))]
    }

    private func configuredMetrics(_ cfg: MenuBarConfig) -> (temperature: MenuBarMetric, fan: MenuBarMetric) {
        let fan: MenuBarMetric = cfg.secondary == .none ? .fanAverage : cfg.secondary
        return (cfg.primary, fan)
    }

    private func item(_ metric: MenuBarMetric, _ icon: MenuBarIcon,
                      caption: String = "", showUnit: Bool = false) -> MenuBarLabelItem {
        MenuBarLabelItem(metric: metric, icon: icon, caption: caption, showUnit: showUnit)
    }
}

extension MenuBarStyle {
    /// Where «Свой вариант» starts when the user customises this style: its own composition, or the closest one.
    func editableComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel {
        if let composition = composition(cfg) { return composition.withFreshIDs() }
        if let composition = temperatureAndFanEditableComposition(cfg) { return composition }
        if let composition = iconEditableComposition(cfg) { return composition }
        return graphicEditableComposition(cfg) ?? .standard
    }

    private func temperatureAndFanEditableComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let (temperature, fan) = configuredMetrics(cfg)
        switch self {
        case .stacked: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .fan)], layout: .stacked)
        case .tempFan: return MenuBarCustomLabel(items: [item(temperature, .none), item(fan, .fan)])
        default: return nil
        }
    }

    private func iconEditableComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let (temperature, _) = configuredMetrics(cfg)
        switch self {
        case .iconTemp, .iconOnly: return singleMetric(temperature, icon: .thermometer)
        case .chip: return singleMetric(temperature, icon: .cpu)
        case .pill: return singleMetric(temperature, icon: .none, badge: true)
        default: return nil
        }
    }

    private func graphicEditableComposition(_ cfg: MenuBarConfig) -> MenuBarCustomLabel? {
        let (temperature, _) = configuredMetrics(cfg)
        switch self {
        case .temp: return singleMetric(temperature, icon: .none)
        case .ringTemp, .gauge: return singleMetric(temperature, icon: .ring)
        case .bar: return singleMetric(temperature, icon: .level)
        case .sparkline: return singleMetric(temperature, icon: .graph)
        default: return nil
        }
    }

    private func singleMetric(_ metric: MenuBarMetric, icon: MenuBarIcon, badge: Bool = false) -> MenuBarCustomLabel {
        MenuBarCustomLabel(items: [MenuBarLabelItem(metric: metric, icon: icon)], badge: badge)
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
    /// Additive: left out of the "Hottest" value (popover hero, Overview, the Sensors sidebar badge) — display only,
    /// aggregates, alerts, fan curves and the safety override still see it. `true` or nil (nil = counted); optional,
    /// so overrides saved before it existed still decode.
    var excludedFromHottest: Bool?
}
