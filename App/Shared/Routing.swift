// Routing.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Navigation + what is on screen (drives sampling cadence).
import Foundation
import Observation
import ThermikCore

enum Route: Hashable, Codable, Sendable {
    case overview, sensors(SensorID?), fans, battery, system, diagnostics, logs, alerts
    /// Settings live in the main window too (nil: keep the tab that was open).
    case settings(SettingsTab?)
    /// Sidebar identity (ignores the selected sensor / settings tab).
    var page: Page {
        switch self {
        case .overview: .overview; case .sensors: .sensors; case .fans: .fans; case .battery: .battery
        case .system: .system; case .diagnostics: .diagnostics; case .logs: .logs; case .alerts: .alerts
        case .settings: .settings
        }
    }
    enum Page: String, Hashable, Codable, Sendable, CaseIterable {
        case overview, sensors, fans, battery, system, diagnostics, logs, alerts, settings
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, menuBar, sensors, fans, alerts, logging, appearance, helper, advanced, about
    var id: String { rawValue }
}

/// Imperative navigation used from anywhere (stores, notifications, status item). Closures are installed by
/// AppDelegate once WindowManager / MenuBarController exist.
/// Injected like the stores: `@Environment(AppRouter.self) private var router`.
@MainActor @Observable final class AppRouter {
    @ObservationIgnored var showMain: (Route?) -> Void = { _ in }
    @ObservationIgnored var showSettings: (SettingsTab?) -> Void = { _ in }
    @ObservationIgnored var showOnboarding: () -> Void = {}
    @ObservationIgnored var openPopover: () -> Void = {}
    @ObservationIgnored var closePopover: () -> Void = {}
    /// Ask SamplingCoordinator for an extra tick as soon as possible (e.g. right after a fan-mode change).
    @ObservationIgnored var requestTick: () -> Void = {}
}

/// Set by the UI units; read by SamplingCoordinator to pick cadence and what to read.
@MainActor @Observable final class VisibilityTracker {
    var popoverOpen = false
    var mainWindowVisible = false            // visible and not fully occluded
    var visiblePage: Route.Page? = nil       // nil when the main window is hidden
    var settingsOpen = false
    var inspectedSensor: SensorID? = nil     // inspector open → keep sampling it every tick
    var isAnyUIVisible: Bool { popoverOpen || mainWindowVisible }
    /// The System page is the only view of per-core load, GPU usage and IOReport data.
    var showsSystemPage: Bool { mainWindowVisible && visiblePage == .system }
    /// IOReport frequency/power sampling (~6–8 ms) only while something shows it.
    var needsSoCMetrics: Bool { showsSystemPage }
    var needsBatteryDetail: Bool { mainWindowVisible && visiblePage == .battery }
    var needsAllSensors: Bool { popoverOpen || (mainWindowVisible && [.overview, .sensors].contains(visiblePage)) }
}
