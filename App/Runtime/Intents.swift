// Intents.swift — Thermik (MIT). OWNER: Unit 5. P1 App Intents for Shortcuts and Spotlight (FEAT §9.7): Get
// Temperature, Set Fan Mode, Apply Fan Preset. They run inside the app process — the system launches the agent in
// the background when it is not running — and act on `AppEnvironment.current`, like a click in the popover would.
// Titles must stay string literals: Xcode extracts them at build time (App Intents metadata), Russian comes from the
// String Catalog (L10n fragment unit5.json).
import AppIntents
import Foundation
import ThermikCore

// MARK: Parameters

enum TemperatureSourceAppEnum: String, AppEnum {
    case cpuAverage, cpuHottest, gpuAverage, gpuHottest, socHottest, highestAll, averageAll, memory, ssd, battery

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Temperature Source")
    static let caseDisplayRepresentations: [TemperatureSourceAppEnum: DisplayRepresentation] = [
        .cpuAverage: DisplayRepresentation(title: "CPU average"),
        .cpuHottest: DisplayRepresentation(title: "CPU hottest"),
        .gpuAverage: DisplayRepresentation(title: "GPU average"),
        .gpuHottest: DisplayRepresentation(title: "GPU hottest"),
        .socHottest: DisplayRepresentation(title: "CPU or GPU (hotter)"),
        .highestAll: DisplayRepresentation(title: "Hottest sensor"),
        .averageAll: DisplayRepresentation(title: "All sensors average"),
        .memory: DisplayRepresentation(title: "Memory"),
        .ssd: DisplayRepresentation(title: "SSD"),
        .battery: DisplayRepresentation(title: "Battery"),
    ]

    var kind: AggregateKind {
        switch self {
        case .cpuAverage: .cpuAverage; case .cpuHottest: .cpuHottest; case .gpuAverage: .gpuAverage
        case .gpuHottest: .gpuHottest; case .socHottest: .socHottest; case .highestAll: .highestAll
        case .averageAll: .averageAll; case .memory: .memory; case .ssd: .ssd; case .battery: .battery
        }
    }
}

enum FanModeAppEnum: String, AppEnum {
    case auto, curve, fixed, max

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fan Mode")
    static let caseDisplayRepresentations: [FanModeAppEnum: DisplayRepresentation] = [
        .auto: DisplayRepresentation(title: "Auto"),
        .curve: DisplayRepresentation(title: "Curve"),
        .fixed: DisplayRepresentation(title: "Fixed"),
        .max: DisplayRepresentation(title: "Max"),
    ]

    var mode: FanMode {
        switch self { case .auto: .system; case .curve: .curve; case .fixed: .fixed; case .max: .max }
    }
}

enum FanPresetAppEnum: String, AppEnum {
    case quiet, balanced, cool, performance

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fan Preset")
    static let caseDisplayRepresentations: [FanPresetAppEnum: DisplayRepresentation] = [
        .quiet: DisplayRepresentation(title: "Quiet"),
        .balanced: DisplayRepresentation(title: "Balanced"),
        // Own key: the thermal level "Cool" is «Прохладно», the preset is «Прохладный» (same key as Display+Strings).
        .cool: DisplayRepresentation(title: LocalizedStringResource("fanPreset.cool", defaultValue: "Cool")),
        .performance: DisplayRepresentation(title: "Performance"),
    ]

    var preset: FanPresetID {
        switch self { case .quiet: .quiet; case .balanced: .balanced; case .cool: .cool; case .performance: .performance }
    }
}

// MARK: Intents

struct GetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Temperature"
    static let description = IntentDescription("Returns a temperature measured by Thermik, in degrees Celsius.")
    static let openAppWhenRun = false

    @Parameter(title: "Source", default: .cpuAverage)
    var source: TemperatureSourceAppEnum

    static var parameterSummary: some ParameterSummary { Summary("Get the \(\.$source) temperature") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let env = try await ThermikIntents.environment()
        let wholeMac = await ThermikIntents.wholeMacValue(source.kind, env: env)
        guard let celsius = wholeMac ?? env.sensors.value(.aggregate(source.kind)) else { throw ThermikIntentError.noReading }
        let text = ThermikFormat.temp(celsius, unit: env.settings.effectiveUnit)
        return .result(value: (celsius * 10).rounded() / 10, dialog: IntentDialog("\(source.kind.title): \(text)"))
    }
}

struct SetFanModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Fan Mode"
    static let description = IntentDescription("Switches Thermik's fan mode. Curve and Fixed use the settings chosen in Thermik.")
    static let openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: FanModeAppEnum

    static var parameterSummary: some ParameterSummary { Summary("Set the fan mode to \(\.$mode)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try await ThermikIntents.environment()
        try ThermikIntents.requireFanControl(env, for: mode.mode)
        env.fans.setMode(mode.mode, reason: .shortcut)
        let label = String(localized: "Fan mode")
        return .result(dialog: IntentDialog("\(label): \(mode.mode.title)"))
    }
}

struct ApplyFanPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Fan Preset"
    static let description = IntentDescription("Applies a fan curve preset and switches Thermik to the Curve mode.")
    static let openAppWhenRun = false

    @Parameter(title: "Preset", default: .balanced)
    var preset: FanPresetAppEnum

    static var parameterSummary: some ParameterSummary { Summary("Apply the \(\.$preset) fan preset") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try await ThermikIntents.environment()
        try ThermikIntents.requireFanControl(env, for: .curve)
        env.fans.applyPreset(preset.preset)
        env.fans.setMode(.curve, reason: .shortcut)
        let label = String(localized: "Fan preset")
        return .result(dialog: IntentDialog("\(label): \(preset.preset.title)"))
    }
}

/// Phrases are localized only through App/Resources/AppShortcuts.xcstrings (the `AppShortcuts` table; keys are the
/// English phrases with `${applicationName}`), not through Localizable.xcstrings.
struct ThermikShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetTemperatureIntent(),
                    phrases: ["Get the \(.applicationName) temperature", "\(.applicationName) temperature"],
                    shortTitle: "Get Temperature", systemImageName: "thermometer.medium")
        AppShortcut(intent: SetFanModeIntent(),
                    phrases: ["Set the \(.applicationName) fan mode", "Change the \(.applicationName) fan mode"],
                    shortTitle: "Set Fan Mode", systemImageName: "fan")
    }
}

// MARK: Support

enum ThermikIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noReading
    case fanless
    case helperUnavailable
    case foreignController(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Thermik is still starting. Try again in a moment."
        case .noReading: "Thermik has no reading for this temperature yet."
        case .fanless: "Passively cooled — no fans"
        case .helperUnavailable: "Fan control needs the Thermik helper"
        case .foreignController(let name): "Fan control is in use by \(name)"
        }
    }
}

@MainActor enum ThermikIntents {
    /// The environment once the first tick has landed (an intent may be what launched the app). At most 5 s.
    static func environment() async throws -> AppEnvironment {
        for _ in 0..<50 {
            if let env = AppEnvironment.current, env.sensors.lastUpdate != nil { return env }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let env = AppEnvironment.current else { throw ThermikIntentError.notRunning }
        return env
    }

    /// `highestAll` / `averageAll` are defined over every visible sensor, but with no window open a tick reads only the
    /// headline, safety and rule keys (SamplingCoordinator), so the store's value would describe that subset (mostly
    /// die sensors). Unless the last frame read every visible sensor, one extra read-only pass over them answers for
    /// the whole Mac (unsmoothed, like the aggregator's input). nil = use the store's value.
    static func wholeMacValue(_ kind: AggregateKind, env: AppEnvironment) async -> Double? {
        guard kind == .highestAll || kind == .averageAll, let inventory = env.sensors.inventory else { return nil }
        let visible = env.sensors.sensors.filter { !$0.isHidden }.map(\.id)
        if let f = env.sensors.lastFrame,
           visible.allSatisfy({ f.values[$0] != nil || f.raw[$0] != nil || f.gated.contains($0) }) { return nil }
        let frame = await env.sensorSampler.sample(SampleRequest(sensorIDs: visible, includeFans: false, includePower: false))
        return SensorAggregator(inventory: inventory).aggregates(frame.values, visible: Set(visible))[kind]
    }

    /// Releasing the fans to Auto is always allowed; anything else needs fans, the helper and no foreign controller.
    static func requireFanControl(_ env: AppEnvironment, for mode: FanMode) throws {
        guard env.fans.hasFans else { throw ThermikIntentError.fanless }
        guard mode != .system else { return }
        if let name = env.fans.foreignControllerName { throw ThermikIntentError.foreignController(name) }
        guard env.fans.canControl else { throw ThermikIntentError.helperUnavailable }
    }
}
