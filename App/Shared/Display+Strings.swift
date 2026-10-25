// Display+Strings.swift — Thermik (MIT). Created by Unit 0; OWNER: Unit 8 (Unit 7 may ADD cases only via its own
// file-private helpers). Localized titles for Core enums. Core never contains UI strings (SPEC §4.12).
import Foundation
import ThermikCore

extension FanMode {
    var title: String {
        switch self {
        case .system: String(localized: "Auto", comment: "Fan mode: macOS controls the fans")
        case .curve: String(localized: "Curve", comment: "Fan mode")
        case .fixed: String(localized: "Fixed", comment: "Fan mode")
        case .max: String(localized: "Max", comment: "Fan mode")
        }
    }
}

extension FanPresetID {
    var title: String {
        switch self {
        case .quiet: String(localized: "Quiet"); case .balanced: String(localized: "Balanced")
        // Own key: the thermal level "Cool" (kit ThermalLevel) is «Прохладно», this preset is «Прохладный».
        case .cool: String(localized: "fanPreset.cool", defaultValue: "Cool", comment: "Fan preset name")
        case .performance: String(localized: "Performance")
        }
    }
}

extension DisplayGroup {
    var title: String {
        switch self {
        case .cpu: String(localized: "CPU"); case .gpu: String(localized: "GPU"); case .soc: String(localized: "SoC")
        case .memory: String(localized: "Memory"); case .storage: String(localized: "Storage")
        case .battery: String(localized: "Battery"); case .power: String(localized: "Power")
        case .enclosure: String(localized: "Enclosure & airflow"); case .ports: String(localized: "Ports")
        case .wireless: String(localized: "Wireless"); case .other: String(localized: "Other")
        }
    }
}

extension AggregateKind {
    var title: String {
        switch self {
        case .cpuAverage: String(localized: "CPU average"); case .cpuHottest: String(localized: "CPU hottest")
        case .gpuAverage: String(localized: "GPU average"); case .gpuHottest: String(localized: "GPU hottest")
        case .socHottest: String(localized: "CPU or GPU (hotter)"); case .socDie: String(localized: "SoC die")
        case .highestAll: String(localized: "Hottest sensor"); case .averageAll: String(localized: "All sensors average")
        case .memory: String(localized: "Memory"); case .ssd: String(localized: "SSD"); case .battery: String(localized: "Battery")
        case .safetyTop4: String(localized: "Hottest 4 die sensors (average)"); case .rawHottestDie: String(localized: "Hottest die sensor")
        }
    }
}

extension ThermalPressure {
    var title: String {
        switch self {
        case .nominal: String(localized: "Nominal"); case .moderate: String(localized: "Moderate")
        case .heavy: String(localized: "Heavy"); case .trapping: String(localized: "Throttling")
        // Own key: the thermal level "Critical" (kit ThermalLevel) is «Критично», this pressure level is «Критическая».
        case .sleeping: String(localized: "thermalPressure.critical", defaultValue: "Critical", comment: "Thermal pressure level")
        }
    }
}

extension ShutdownVerdict {
    var title: String {
        switch self {
        case .normalRestart: String(localized: "Normal restart")
        case .normalShutdown: String(localized: "Normal shutdown")
        case .forced: String(localized: "Forced (power button)")
        case .thermal: String(localized: "Overheating")
        case .powerLoss: String(localized: "Power loss or empty battery")
        case .watchdog: String(localized: "Watchdog reset")
        case .kernelPanic: String(localized: "Kernel panic")
        case .intelCode(let c): String(localized: "Shutdown cause code \(c)")
        case .other: String(localized: "Other")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension BatteryCondition {
    var title: String {
        switch self {
        case .normal: String(localized: "Normal"); case .serviceRecommended: String(localized: "Service recommended")
        case .permanentFailure: String(localized: "Service battery"); case .unknown: String(localized: "Unknown")
        }
    }
}

extension HelperAvailability {
    var title: String {
        switch self {
        case .notInstalled: String(localized: "Fan control needs the Thermik helper")
        case .requiresApproval: String(localized: "Approve Thermik in System Settings › Login Items")
        case .needsUpgrade: String(localized: "The helper needs an update")
        case .unreachable: String(localized: "The helper is not responding")
        case .connecting: String(localized: "Connecting to the helper…")
        }
    }
}

extension MenuBarStyle {
    var title: String {
        switch self {
        case .iconOnly: String(localized: "Icon only"); case .temp: String(localized: "Temperature")
        case .iconTemp: String(localized: "Icon and temperature"); case .tempFan: String(localized: "Temperature and fan")
        case .stacked: String(localized: "Stacked"); case .gauge: String(localized: "Gauge")
        }
    }
}

extension Route.Page {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview"); case .sensors: String(localized: "Sensors"); case .fans: String(localized: "Fans")
        case .battery: String(localized: "Battery"); case .system: String(localized: "System"); case .diagnostics: String(localized: "Diagnostics")
        case .logs: String(localized: "Logs"); case .alerts: String(localized: "Alerts")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"; case .sensors: "thermometer.medium"; case .fans: "fan"
        case .battery: "battery.75percent"; case .system: "macbook"; case .diagnostics: "stethoscope"
        case .logs: "list.bullet.rectangle"; case .alerts: "bell"
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: String(localized: "General"); case .menuBar: String(localized: "Menu Bar"); case .sensors: String(localized: "Sensors")
        case .fans: String(localized: "Fans"); case .alerts: String(localized: "Alerts"); case .logging: String(localized: "Logging")
        case .appearance: String(localized: "Appearance"); case .helper: String(localized: "Helper")
        case .advanced: String(localized: "Advanced"); case .about: String(localized: "About")
        }
    }
}

extension DiagnosticKind {
    var title: String {
        switch self {
        case .lastShutdown: String(localized: "Last shutdown"); case .fans: String(localized: "Fans")
        case .sensors: String(localized: "Temperature sensors"); case .battery: String(localized: "Battery health")
        case .thermal: String(localized: "Thermal pressure"); case .storage: String(localized: "Drive health")
        case .helper: String(localized: "Fan helper"); case .smc: String(localized: "SMC access")
        }
    }
}
