// SettingsStore.swift — Thermik (MIT). Implemented by Unit 0; OWNER afterwards: Unit 5 (keys are FROZEN, SPEC §2.11).
// Typed UserDefaults facade. Simple values stored natively, complex ones as JSON Data. Every write is immediate.
// Unit 5 added keys (additive, not in the frozen table): `general.hotKeys` (P1 global shortcuts) and
// `general.urlScheme.allowFanControl` (P2: `thermik://` links may change fan control without asking).
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
        // Unit 5 (additive)
        static let hotKeys = "general.hotKeys"
        static let allowFanControlFromLinks = "general.urlScheme.allowFanControl"
        // Additive: user-tuned colour-scale stops per sensor class (Settings › Appearance).
        static let colorScales = "appearance.colorScales"
        static let all = [launchAtLogin, updateInterval, showDockIcon, temperatureUnit, language, animatedEffects, colorBlindScale,
                          popoverDensity, menuBar, sensorOverrides, showHiddenSensors, showRawKeys, driveTemperatures, fans,
                          alertsEnabled, alertRules, alertSoundName, alertsSnoozedUntil, log, onboardingCompleted, helperWanted,
                          suppressHelperPrompt, menuBarHintShown, hotKeys, allowFanControlFromLinks, colorScales]
    }

    /// Allowed update intervals (s). TG range 1…60, default 2.
    static let updateIntervals: [Double] = [1, 2, 3, 5, 10, 30, 60]

    @ObservationIgnored private let defaults: UserDefaults
    /// True while `resetToDefaults()` copies the defaults back: nothing is written, so the keys stay absent and a
    /// later version's new defaults apply.
    @ObservationIgnored private var isRestoring = false

    // General
    var launchAtLogin: Bool { didSet { store(launchAtLogin, Key.launchAtLogin) } }
    var updateInterval: Double {
        didSet {
            // Snap foreign values (old builds, `defaults write`, a slider) to the nearest supported interval.
            if !Self.updateIntervals.contains(updateInterval) { updateInterval = Self.nearestInterval(updateInterval) }
            store(updateInterval, Key.updateInterval)
        }
    }
    var showDockIconWhileWindowOpen: Bool { didSet { store(showDockIconWhileWindowOpen, Key.showDockIcon) } }
    var temperatureUnit: TemperatureUnitPreference { didSet { store(temperatureUnit.rawValue, Key.temperatureUnit) } }
    var language: LanguagePreference { didSet { applyLanguage() } }
    /// P1 global shortcuts, keyed by `HotKeyAction.rawValue`. Empty by default: no combination is preset, so Thermik
    /// never collides with another app (FEAT §9.2).
    var hotKeys: [String: HotKeyCombo] { didSet { encode(hotKeys, Key.hotKeys) } }
    /// P2: `thermik://fans/…` links change fan control without the confirmation alert.
    var allowFanControlFromLinks: Bool { didSet { store(allowFanControlFromLinks, Key.allowFanControlFromLinks) } }
    // Appearance
    var animatedEffects: Bool { didSet { store(animatedEffects, Key.animatedEffects) } }
    var colorBlindScale: Bool { didSet { store(colorBlindScale, Key.colorBlindScale) } }
    var popoverDensity: PopoverDensity { didSet { store(popoverDensity.rawValue, Key.popoverDensity) } }
    /// Colour-scale stops the user changed, by `ThermalClass.rawValue` (seven °C values). Absent classes use the
    /// defaults. Applied to `ThermalScaleOverrides` at once, so every colour follows on the next redraw.
    var colorScales: [String: [Double]] {
        didSet { encode(colorScales, Key.colorScales); ThermalScaleOverrides.apply(colorScales) }
    }
    // Menu bar
    var menuBar: MenuBarConfig { didSet { encode(menuBar, Key.menuBar) } }
    var menuBarHintShown: Bool { didSet { store(menuBarHintShown, Key.menuBarHintShown) } }
    // Sensors
    var sensorOverrides: [String: SensorOverride] { didSet { encode(sensorOverrides, Key.sensorOverrides) } }
    var showHiddenSensors: Bool { didSet { store(showHiddenSensors, Key.showHiddenSensors) } }
    var showRawKeys: Bool { didSet { store(showRawKeys, Key.showRawKeys) } }
    var driveTemperatures: Bool { didSet { store(driveTemperatures, Key.driveTemperatures) } }
    // Fans
    var fans: FanUserConfig { didSet { encode(fans, Key.fans) } }
    // Alerts
    var alertsEnabled: Bool { didSet { store(alertsEnabled, Key.alertsEnabled) } }
    var alertRules: [AlertRule] { didSet { encode(alertRules, Key.alertRules) } }
    var alertSoundName: String? { didSet { store(alertSoundName, Key.alertSoundName) } }
    var alertsSnoozedUntil: Date? { didSet { store(alertsSnoozedUntil, Key.alertsSnoozedUntil) } }
    // Logging
    var log: LogConfig { didSet { encode(log, Key.log) } }
    // Onboarding / helper
    var onboardingCompleted: Bool { didSet { store(onboardingCompleted, Key.onboardingCompleted) } }
    var helperWanted: Bool { didSet { store(helperWanted, Key.helperWanted) } }
    var suppressHelperPrompt: Bool { didSet { store(suppressHelperPrompt, Key.suppressHelperPrompt) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? true
        let interval = defaults.object(forKey: Key.updateInterval) as? Double ?? 2
        updateInterval = Self.updateIntervals.contains(interval) ? interval : Self.nearestInterval(interval)
        showDockIconWhileWindowOpen = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        temperatureUnit = TemperatureUnitPreference(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .system
        language = LanguagePreference(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        hotKeys = Self.decode([String: HotKeyCombo].self, defaults, Key.hotKeys) ?? [:]
        allowFanControlFromLinks = defaults.bool(forKey: Key.allowFanControlFromLinks)
        animatedEffects = defaults.object(forKey: Key.animatedEffects) as? Bool ?? true
        colorBlindScale = defaults.object(forKey: Key.colorBlindScale) as? Bool ?? false
        popoverDensity = PopoverDensity(rawValue: defaults.string(forKey: Key.popoverDensity) ?? "") ?? .regular
        colorScales = Self.decode([String: [Double]].self, defaults, Key.colorScales) ?? [:]
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
        ThermalScaleOverrides.apply(colorScales)          // didSet does not run in init
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
    func setOverride(_ o: SensorOverride, for id: SensorID) {
        // An override with every field nil is the same as none: drop it so the plist does not grow forever.
        sensorOverrides[id.description] = (o.name == nil && o.hidden == nil && o.pinned == nil) ? nil : o
    }

    /// Keys that views keep through @AppStorage outside this store (the popover's expanded groups, Unit 7; the
    /// experimental CLPC power toggle in Settings › Advanced, Unit 8, read by Unit 2's IOReport). Reset clears them too.
    /// Per-boot bookkeeping (alerts.lastShutdownAlertBoot, diag.*) is deliberately kept.
    static let viewOwnedKeys = ["popover.expandedGroups", "advanced.experimentalCLPCPower"]

    /// Everything back to defaults (fans return to System first — the caller (Settings UI) must call
    /// FanStore.resetToSystem() before this). Relaunch is recommended afterwards (`AppDelegate.relaunch()`).
    /// The keys are REMOVED, not rewritten with today's defaults.
    func resetToDefaults() {
        for k in Key.all { defaults.removeObject(forKey: k) }
        for k in Self.viewOwnedKeys { defaults.removeObject(forKey: k) }
        defaults.removeObject(forKey: "AppleLanguages")
        let fresh = SettingsStore(defaults: defaults)
        isRestoring = true
        defer { isRestoring = false }
        launchAtLogin = fresh.launchAtLogin; updateInterval = fresh.updateInterval
        showDockIconWhileWindowOpen = fresh.showDockIconWhileWindowOpen; temperatureUnit = fresh.temperatureUnit
        language = fresh.language; hotKeys = fresh.hotKeys; allowFanControlFromLinks = fresh.allowFanControlFromLinks
        animatedEffects = fresh.animatedEffects; colorBlindScale = fresh.colorBlindScale
        popoverDensity = fresh.popoverDensity; colorScales = fresh.colorScales; menuBar = fresh.menuBar; menuBarHintShown = fresh.menuBarHintShown
        sensorOverrides = fresh.sensorOverrides; showHiddenSensors = fresh.showHiddenSensors; showRawKeys = fresh.showRawKeys
        driveTemperatures = fresh.driveTemperatures; fans = fresh.fans; alertsEnabled = fresh.alertsEnabled
        alertRules = fresh.alertRules; alertSoundName = fresh.alertSoundName; alertsSnoozedUntil = fresh.alertsSnoozedUntil
        log = fresh.log; onboardingCompleted = fresh.onboardingCompleted; helperWanted = fresh.helperWanted
        suppressHelperPrompt = fresh.suppressHelperPrompt
    }

    // MARK: Persistence helpers

    /// Language override (P1): writes AppleLanguages for this app's domain; takes effect after relaunch.
    private func applyLanguage() {
        guard !isRestoring else { return }
        defaults.set(language.rawValue, forKey: Key.language)
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .english: defaults.set(["en"], forKey: "AppleLanguages")
        case .russian: defaults.set(["ru"], forKey: "AppleLanguages")
        }
    }

    private static func nearestInterval(_ v: Double) -> Double {
        guard v.isFinite else { return 2 }
        return updateIntervals.min { abs($0 - v) < abs($1 - v) } ?? 2
    }

    /// Plist-native values (`nil` removes the key).
    private func store(_ value: Any?, _ key: String) {
        guard !isRestoring else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    private func encode<T: Encodable>(_ value: T, _ key: String) {
        guard !isRestoring else { return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
