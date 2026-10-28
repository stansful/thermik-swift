// MainWindowModel.swift — Thermik (MIT). Unit 8. Navigation and per-window UI state of the main window.
// Owned by WindowManager (so routes from the menu bar, notifications and ⌘1…⌘8 land in the same window) and read by
// MainWindowRoot. Changes that affect sampling cadence (page, inspected sensor) are reported through `onVisibleChange`;
// WindowManager turns them into VisibilityTracker updates (SPEC §4.6).
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class MainWindowModel {
    /// Selected sidebar page.
    var page: Route.Page = .overview { didSet { if oldValue != page { onVisibleChange?() } } }
    /// Sensors page: selected row (also the inspector subject).
    var selectedSensor: SensorID? { didSet { if oldValue != selectedSensor { onVisibleChange?() } } }
    var isInspectorShown = false { didSet { if oldValue != isInspectorShown { onVisibleChange?() } } }
    /// Toolbar history range shared by every chart in the window.
    var historyWindow: HistoryWindow = .m15
    var sensorSearch = ""
    var eventSearch = ""
    /// Sensors page group filter chip (nil = All).
    var sensorGroupFilter: DisplayGroup?
    /// "Set alert…" from a sensor row: the Alerts page opens its editor pre-filled with this subject.
    var pendingAlertSubject: AlertRule.Subject?
    /// Settings page: the selected tab (kept while the user visits other pages).
    var settingsTab: SettingsTab = .general

    /// Installed by WindowManager.
    @ObservationIgnored var onVisibleChange: (() -> Void)?

    /// Applies a route. `.sensors(nil)` keeps the current sensor selection.
    func open(_ route: Route) {
        page = route.page
        if case .sensors(let id?) = route {
            selectedSensor = id
            isInspectorShown = true
        }
        if case .settings(let tab?) = route { settingsTab = tab }
    }

    /// Ships the sensor to the Alerts page editor.
    func createAlert(for subject: AlertRule.Subject) {
        pendingAlertSubject = subject
        page = .alerts
    }
}

extension Route.Page {
    /// ⌘1…⌘8 (sidebar order); Settings uses ⌘, instead.
    var shortcutDigit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    /// The pages of the top sidebar section (Settings sits in its own section below them).
    static var contentPages: [Route.Page] { allCases.filter { $0 != .settings } }
    /// Pages whose content plots history: the toolbar shows the range picker there.
    var showsHistoryRange: Bool { self == .overview || self == .sensors || self == .battery || self == .system }
}
