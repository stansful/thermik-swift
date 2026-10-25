// SettingsStore.swift — Thermik (MIT). Implemented by Unit 0; OWNER afterwards: Unit 5 (keys are FROZEN, SPEC §2.11).
// Typed UserDefaults facade. Simple values stored natively, complex ones as JSON Data. Every write is immediate.
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class SettingsStore {
    enum Key {
        static let launchAtLogin = "general.launchAtLogin"
        static let updateInterval = "general.updateInterval"
        static let showDockIcon = "general.showDockIconWhileWindowOpen"
        static let temperatureUnit = "general.temperatureUnit"
        static let language = "general.language"
        static let animatedEffects = "appearance.animatedEffects"
        static let colorBlindScale = "appearance.colorBlindScale"
        static let popoverDensity = "appearance.popoverDensity"
        static let menuBar = "menuBar.config"
        static let sensorOverrides = "sensors.overrides"
        static let showHiddenSensors = "sensors.showHidden"
        static let showRawKeys = "sensors.showRawKeys"
        static let driveTemperatures = "sensors.driveTemperatures"
        static let fans = "fans.config"
        static let alertsEnabled = "alerts.enabled"
        static let alertRules = "alerts.rules"
        static let alertSoundName = "alerts.soundName"
        static let alertsSnoozedUntil = "alerts.snoozedUntil"
        static let log = "log.config"
        static let onboardingCompleted = "onboarding.completed"
        static let helperWanted = "helper.wanted"
        static let suppressHelperPrompt = "helper.suppressInstallPrompt"
        static let menuBarHintShown = "menuBar.hintShown"
        static let all = [launchAtLogin, updateInterval, showDockIcon, temperatureUnit, language, animatedEffects, colorBlindScale,
                          popoverDensity, menuBar, sensorOverrides, showHiddenSensors, showRawKeys, driveTemperatures, fans,
                          alertsEnabled, alertRules, alertSoundName, alertsSnoozedUntil, log, onboardingCompleted, helperWanted,
                          suppressHelperPrompt, menuBarHintShown]
    }

    /// Allowed update intervals (s). TG range 1…60, default 2.
    static let updateIntervals: [Double] = [1, 2, 3, 5, 10, 30, 60]

    @ObservationIgnored private let defaults: UserDefaults

    // General
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }
    var updateInterval: Double { didSet { defaults.set(updateInterval, forKey: Key.updateInterval) } }
    var showDockIconWhileWindowOpen: Bool { didSet { defaults.set(showDockIconWhileWindowOpen, forKey: Key.showDockIcon) } }
    var temperatureUnit: TemperatureUnitPreference { didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) } }
    var language: LanguagePreference { didSet { applyLanguage() } }
    // Appearance
    var animatedEffects: Bool { didSet { defaults.set(animatedEffects, forKey: Key.animatedEffects) } }
    var colorBlindScale: Bool { didSet { defaults.set(colorBlindScale, forKey: Key.colorBlindScale) } }
    var popoverDensity: PopoverDensity { didSet { defaults.set(popoverDensity.rawValue, forKey: Key.popoverDensity) } }
    // Menu bar
    var menuBar: MenuBarConfig { didSet { encode(menuBar, Key.menuBar) } }
    var menuBarHintShown: Bool { didSet { defaults.set(menuBarHintShown, forKey: Key.menuBarHintShown) } }
    // Sensors
    var sensorOverrides: [String: SensorOverride] { didSet { encode(sensorOverrides, Key.sensorOverrides) } }
    var showHiddenSensors: Bool { didSet { defaults.set(showHiddenSensors, forKey: Key.showHiddenSensors) } }
    var showRawKeys: Bool { didSet { defaults.set(showRawKeys, forKey: Key.showRawKeys) } }
    var driveTemperatures: Bool { didSet { defaults.set(driveTemperatures, forKey: Key.driveTemperatures) } }
    // Fans
    var fans: FanUserConfig { didSet { encode(fans, Key.fans) } }
    // Alerts
    var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) } }
    var alertRules: [AlertRule] { didSet { encode(alertRules, Key.alertRules) } }
    var alertSoundName: String? { didSet { defaults.set(alertSoundName, forKey: Key.alertSoundName) } }
    var alertsSnoozedUntil: Date? { didSet { defaults.set(alertsSnoozedUntil, forKey: Key.alertsSnoozedUntil) } }
    // Logging
    var log: LogConfig { didSet { encode(log, Key.log) } }
    // Onboarding / helper
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) } }
    var helperWanted: Bool { didSet { defaults.set(helperWanted, forKey: Key.helperWanted) } }
    var suppressHelperPrompt: Bool { didSet { defaults.set(suppressHelperPrompt, forKey: Key.suppressHelperPrompt) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        let interval = defaults.object(forKey: Key.updateInterval) as? Double ?? 2
        updateInterval = Self.updateIntervals.contains(interval) ? interval : 2
        showDockIconWhileWindowOpen = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        temperatureUnit = TemperatureUnitPreference(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .system
        language = LanguagePreference(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        animatedEffects = defaults.object(forKey: Key.animatedEffects) as? Bool ?? true
        colorBlindScale = defaults.object(forKey: Key.colorBlindScale) as? Bool ?? false
        popoverDensity = PopoverDensity(rawValue: defaults.string(forKey: Key.popoverDensity) ?? "") ?? .regular
        menuBar = Self.decode(MenuBarConfig.self, defaults, Key.menuBar) ?? MenuBarConfig()
        menuBarHintShown = defaults.bool(forKey: Key.menuBarHintShown)
        sensorOverrides = Self.decode([String: SensorOverride].self, defaults, Key.sensorOverrides) ?? [:]
        showHiddenSensors = defaults.bool(forKey: Key.showHiddenSensors)
        showRawKeys = defaults.bool(forKey: Key.showRawKeys)
        driveTemperatures = defaults.object(forKey: Key.driveTemperatures) as? Bool ?? true
        fans = Self.decode(FanUserConfig.self, defaults, Key.fans) ?? FanUserConfig()
        alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? true
        alertRules = Self.decode([AlertRule].self, defaults, Key.alertRules) ?? AlertRule.defaultRules
        alertSoundName = defaults.string(forKey: Key.alertSoundName)
        alertsSnoozedUntil = defaults.object(forKey: Key.alertsSnoozedUntil) as? Date
        log = Self.decode(LogConfig.self, defaults, Key.log) ?? LogConfig()
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        helperWanted = defaults.bool(forKey: Key.helperWanted)
        suppressHelperPrompt = defaults.bool(forKey: Key.suppressHelperPrompt)
    }

    // MARK: Derived

    var effectiveUnit: UnitTemperature {
        switch temperatureUnit {
        case .celsius: return .celsius
        case .fahrenheit: return .fahrenheit
        case .system: return Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
        }
    }

    /// Sensor names from the DB: Russian when the effective UI language is Russian.
    var preferRussian: Bool {
        switch language {
        case .russian: return true
        case .english: return false
        case .system: return (Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }

    func override(for id: SensorID) -> SensorOverride { sensorOverrides[id.description] ?? SensorOverride() }
    func setOverride(_ o: SensorOverride, for id: SensorID) { sensorOverrides[id.description] = o }

    /// Everything back to defaults (fans return to System first — the caller (Settings UI) must call
    /// FanStore.resetToSystem() before this). Relaunch is recommended afterwards.
    func resetToDefaults() {
        for k in Key.all { defaults.removeObject(forKey: k) }
        let fresh = SettingsStore(defaults: defaults)
        launchAtLogin = fresh.launchAtLogin; updateInterval = fresh.updateInterval
        showDockIconWhileWindowOpen = fresh.showDockIconWhileWindowOpen; temperatureUnit = fresh.temperatureUnit
        language = fresh.language; animatedEffects = fresh.animatedEffects; colorBlindScale = fresh.colorBlindScale
        popoverDensity = fresh.popoverDensity; menuBar = fresh.menuBar; menuBarHintShown = fresh.menuBarHintShown
        sensorOverrides = fresh.sensorOverrides; showHiddenSensors = fresh.showHiddenSensors; showRawKeys = fresh.showRawKeys
        driveTemperatures = fresh.driveTemperatures; fans = fresh.fans; alertsEnabled = fresh.alertsEnabled
        alertRules = fresh.alertRules; alertSoundName = fresh.alertSoundName; alertsSnoozedUntil = fresh.alertsSnoozedUntil
        log = fresh.log; onboardingCompleted = fresh.onboardingCompleted; helperWanted = fresh.helperWanted
        suppressHelperPrompt = fresh.suppressHelperPrompt
    }

    // MARK: Persistence helpers

    /// Language override (P1): writes AppleLanguages for this app's domain; takes effect after relaunch.
    private func applyLanguage() {
        defaults.set(language.rawValue, forKey: Key.language)
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .english: defaults.set(["en"], forKey: "AppleLanguages")
        case .russian: defaults.set(["ru"], forKey: "AppleLanguages")
        }
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
