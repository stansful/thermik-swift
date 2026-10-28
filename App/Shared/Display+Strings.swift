// Display+Strings.swift — Thermik (MIT). Created by Unit 0; OWNER: Unit 8 (Unit 7 may ADD cases only via its own
// file-private helpers). Localized titles for Core enums. Core never contains UI strings (SPEC §4.12).
import Foundation
import ThermikCore
import ThermikHelperShared

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
        case .chip: String(localized: "Chip and temperature"); case .pill: String(localized: "Badge")
        case .ringTemp: String(localized: "Ring and temperature"); case .bar: String(localized: "Level and temperature")
        case .sparkline: String(localized: "Mini graph")
        case .iconTempFan: String(localized: "Icons: temperature and fan"); case .chipTempFan: String(localized: "Chip and fan")
        case .flameTempFan: String(localized: "Flame and blades"); case .stackedIcons: String(localized: "Two rows with icons")
        case .stackedUnits: String(localized: "Two rows with units"); case .tempRPM: String(localized: "Temperature and rpm")
        case .compact: String(localized: "menuBarStyle.compact", defaultValue: "Compact", comment: "Menu bar label style"); case .badgeFan: String(localized: "Badge and fan")
        case .ringFan: String(localized: "Ring and fan"); case .cpuGpu: String(localized: "CPU and GPU")
        case .cpuGpuStacked: String(localized: "CPU over GPU"); case .fanOnly: String(localized: "Fan only")
        case .custom: String(localized: "menuBarStyle.custom", defaultValue: "Custom", comment: "Menu bar label style built by the user")
        }
    }
}

extension Route.Page {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview"); case .sensors: String(localized: "Sensors"); case .fans: String(localized: "Fans")
        case .battery: String(localized: "Battery"); case .system: String(localized: "System"); case .diagnostics: String(localized: "Diagnostics")
        case .logs: String(localized: "Logs"); case .alerts: String(localized: "Alerts")
        case .settings: String(localized: "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"; case .sensors: "thermometer.medium"; case .fans: "fan"
        case .battery: "battery.75percent"; case .system: "macbook"; case .diagnostics: "stethoscope"
        case .logs: "list.bullet.rectangle"; case .alerts: "bell"
        case .settings: "gearshape"
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

// MARK: - Unit 8 additions (add-only; the keys above stay unchanged)

extension SensorGroup {
    /// Hardware block of a key (Sensors inspector).
    var title: String {
        switch self {
        case .cpuPerformance: String(localized: "CPU performance cores")
        case .cpuEfficiency: String(localized: "CPU efficiency cores")
        case .cpuFabric: String(localized: "CPU fabric")
        case .cpuAggregate: String(localized: "CPU cluster summary")
        case .gpu: String(localized: "GPU cores")
        case .gpuAggregate: String(localized: "GPU summary")
        case .socFabric: String(localized: "SoC fabric")
        case .soc: String(localized: "SoC die")
        case .memory: String(localized: "Memory")
        case .battery: String(localized: "Battery")
        case .storage: String(localized: "Storage")
        case .wireless: String(localized: "Wireless")
        case .enclosure: String(localized: "Enclosure")
        case .airflow: String(localized: "Airflow")
        case .ports: String(localized: "Ports")
        case .powerDelivery: String(localized: "Power delivery")
        case .board: String(localized: "Logic board")
        case .virtual: String(localized: "Computed by macOS")
        case .other: String(localized: "Other")
        }
    }
}

extension SensorRole {
    var title: String {
        switch self {
        case .probe: String(localized: "Probe")
        case .calibrated: String(localized: "Calibrated probe")
        case .hotspot: String(localized: "Hotspot")
        case .average: String(localized: "Firmware average")
        case .maximum: String(localized: "Firmware maximum")
        case .peakHold: String(localized: "Peak since boot")
        case .reference: String(localized: "Reference value")
        case .duplicate: String(localized: "Duplicate")
        case .unused: String(localized: "Unused")
        }
    }
}

extension SensorSource {
    /// Technical acronyms (not translated).
    var title: String {
        switch self {
        case .smc: "SMC"
        case .hid: "HID"
        }
    }
}

extension CatalogStatus {
    var title: String {
        switch self {
        case .verified(let p): String(localized: "Verified sensor list (\(p))")
        case .unverified(let p): String(localized: "Sensor list not yet verified (\(p))")
        case .heuristic: String(localized: "Approximate sensor names")
        }
    }
    var isHeuristic: Bool { if case .heuristic = self { return true }; return false }
}

extension DiagnosticStatus {
    var title: String {
        switch self {
        case .ok: String(localized: "diagnosticStatus.ok", defaultValue: "OK", comment: "Diagnostic status")
        case .info: String(localized: "Note")
        case .unknown: String(localized: "Unknown")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Problem")
        }
    }
    var symbol: String {
        switch self {
        case .ok: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        case .unknown: "questionmark.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

extension PowerSourceKind {
    var title: String {
        switch self {
        case .ac: String(localized: "Power adapter")
        case .battery: String(localized: "Battery")
        case .ups: String(localized: "UPS")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension MemoryPressure {
    var title: String {
        switch self {
        case .normal: String(localized: "memoryPressure.normal", defaultValue: "Normal", comment: "Memory pressure level")
        case .warning: String(localized: "memoryPressure.warning", defaultValue: "Elevated", comment: "Memory pressure level")
        case .critical: String(localized: "memoryPressure.critical", defaultValue: "Critical", comment: "Memory pressure level")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension HelperInstallKind {
    var title: String {
        switch self {
        case .appService: String(localized: "Login Items (SMAppService)")
        case .legacy: String(localized: "Privileged helper tool (admin password)")
        case .development: String(localized: "Development build")
        }
    }
}

extension HelperManager.Mode {
    var title: String {
        switch self {
        case .appService: String(localized: "Login Items (SMAppService)")
        case .legacy: String(localized: "Privileged helper tool (admin password)")
        }
    }
}

extension HelperManager.State {
    /// One-line status for the helper cards (Fans page, Settings › Helper, onboarding).
    var statusLine: String {
        switch self {
        case .unknown: String(localized: "Checking the helper…")
        case .notInstalled: String(localized: "Not installed")
        case .requiresApproval: String(localized: "Waiting for approval")
        case .needsUpgrade(let installed, let bundled):
            String(localized: "Update available (installed \(installed), bundled \(bundled))")
        case .ready(let info): String(localized: "Installed (v\(info.helperVersion))")
        case .unreachable(let why): String(localized: "Not responding: \(why)")
        }
    }
}

extension FanModeChangeReason {
    var title: String {
        switch self {
        case .user: String(localized: "by you")
        case .launch: String(localized: "at launch")
        case .maxAutoRevert: String(localized: "Max timer ended")
        case .safety: String(localized: "safety override")
        case .foreignController: String(localized: "another app controls the fans")
        case .helperUnavailable: String(localized: "helper unavailable")
        case .notificationAction: String(localized: "from a notification")
        case .shortcut: String(localized: "from Shortcuts")
        case .urlScheme: String(localized: "from a link")
        case .sleep: String(localized: "sleep")
        }
    }
}

/// Why the helper returned the fans to Auto. The helper reports machine tokens (`HelperState.lastRevertReason`,
/// `AppEventPayload.helperReverted`; FanStore records "leaseLost" when it could not fetch one and "macOSReclaimed"
/// when the helper still holds the other fans); the UI shows a phrase that reads after "Fans returned to Auto:".
/// An unknown token is shown as is.
enum HelperRevertReason {
    static func title(_ token: String) -> String {
        switch token {
        case "leaseExpired": return String(localized: "the control lease expired")
        case "leaseLost": return String(localized: "the control lease was lost")
        case "macOSReclaimed": return String(localized: "macOS took back control of a fan")
        case "clientGone": return String(localized: "Thermik disconnected from the helper")
        case "sleep": return String(localized: "sleep")
        case "startupRecovery": return String(localized: "recovery after a helper restart")
        case "sensorFailure": return String(localized: "no chip temperature could be read")
        case "overTemperature": return String(localized: "overheating")
        case "resetAll": return String(localized: "reset requested by Thermik")
        case "released": return String(localized: "Thermik released the fans")
        case "uninstall": return String(localized: "the helper was uninstalled")
        case "restoreRetry": return String(localized: "repeated restore attempt")
        case "overrideWriteFailed": return String(localized: "the safety override could not be applied")
        case "overrideReleased": return String(localized: "the safety override ended")
        case "overrideReleaseFailed": return String(localized: "the safety override could not be released")
        case "stopRestartFailed": return String(localized: "a stopped fan could not be restarted")
        default:
            if token.hasPrefix("signal ") { return String(localized: "the helper was stopped") }   // "signal 15"
            return token
        }
    }
}

extension TemperatureUnitPreference {
    var title: String {
        switch self {
        case .system: String(localized: "System setting")
        case .celsius: String(localized: "Celsius (°C)")
        case .fahrenheit: String(localized: "Fahrenheit (°F)")
        }
    }
}

extension LanguagePreference {
    var title: String {
        switch self {
        case .system: String(localized: "System setting")
        // Language names are always shown in their own language.
        case .english: "English"
        case .russian: "Русский"
        }
    }
}

extension PopoverDensity {
    var title: String {
        switch self {
        case .regular: String(localized: "Regular")
        case .compact: String(localized: "Compact")
        }
    }
}

extension LogColumnGroup {
    var title: String {
        switch self {
        case .headline: String(localized: "Headline temperatures")
        case .fans: String(localized: "Fans and fan mode")
        case .power: String(localized: "Power")
        case .usage: String(localized: "CPU, GPU and memory usage")
        case .thermal: String(localized: "Thermal pressure")
        case .battery: String(localized: "Battery charge")
        case .sensors: String(localized: "Individual sensors")
        case .events: String(localized: "Events")
        }
    }
}

extension LogRotation {
    var title: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .sizeMB(let mb): String(localized: "When larger than \(mb) MB")
        case .never: String(localized: "Never (one file)")
        }
    }
}

extension AlertRule.Subject {
    /// Subject name for rule rows and the editor; `sensorName` resolves `.sensor(id)` to its live display name.
    func title(sensorName: (SensorID) -> String?) -> String {
        switch self {
        case .anySensor: String(localized: "Any sensor")
        case .aggregate(let k): k.title
        case .group(let g): String(localized: "Hottest sensor in \(g.title)")
        case .sensor(let id): sensorName(id) ?? id.description
        case .fanStalled: String(localized: "A fan stalled")
        case .fanModeChanged: String(localized: "Fan mode changed")
        case .thermalPressure(let p): String(localized: "Thermal pressure at least \(p.title)")
        case .abnormalShutdown: String(localized: "Abnormal last shutdown")
        case .batteryService: String(localized: "Battery needs service")
        }
    }
}

extension ThermalClass {
    /// Sensor class names for the colour-scale editor (Settings › Appearance).
    var title: String {
        switch self {
        case .soc: String(localized: "CPU and GPU")
        case .power: String(localized: "Power")
        case .storage: String(localized: "Storage")
        case .battery: String(localized: "Battery")
        case .ambient: String(localized: "Enclosure")
        }
    }
}

extension MenuBarIcon {
    /// Names in the «Свой вариант» icon menu.
    var title: String {
        switch self {
        case .auto: String(localized: "Automatic"); case .none: String(localized: "No icon")
        case .thermometer: String(localized: "Thermometer"); case .cpu: String(localized: "Chip")
        case .memory: String(localized: "Memory"); case .drive: String(localized: "Drive")
        case .battery: String(localized: "Battery"); case .flame: String(localized: "Flame")
        case .heatWaves: String(localized: "Heat waves"); case .fan: String(localized: "Fan")
        case .fanBlades: String(localized: "Fan blades"); case .wind: String(localized: "Wind")
        case .bolt: String(localized: "Bolt"); case .ring: String(localized: "Ring")
        case .level: String(localized: "Level"); case .graph: String(localized: "Mini graph")
        }
    }
}

extension MenuBarCustomLabel.Layout {
    var title: String { switch self { case .inline: String(localized: "One row"); case .stacked: String(localized: "Two rows") } }
}

extension MenuBarCustomLabel.TextSize {
    var title: String {
        switch self { case .small: String(localized: "Small"); case .medium: String(localized: "Medium"); case .large: String(localized: "Large") }
    }
}

extension MenuBarCustomLabel.Separator {
    var title: String {
        switch self { case .space: String(localized: "Space"); case .dot: String(localized: "Dot"); case .bar: String(localized: "Line") }
    }
}
