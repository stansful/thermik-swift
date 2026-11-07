// URLRouter.swift — Thermik (MIT). `thermik://` links, registered in project.yml
// (CFBundleURLTypes). Navigation links act at once. A link that hands control of the fans to Thermik asks first
// (any web page can open a URL; Cancel is the default button), unless the user ticked "Always allow"; switching back
// to Auto never asks.
//   thermik://open[?page=overview|sensors|fans|battery|system|diagnostics|logs|alerts][&sensor=smc:Tp01]
//   thermik://panel                                   show or hide the menu bar panel (alias: popover)
//   thermik://settings[/general|menuBar|sensors|fans|alerts|logging|appearance|helper|advanced|about]
//   thermik://fans/mode/auto|curve|fixed|max          (system = auto, manual = fixed)
//   thermik://fans/preset/quiet|balanced|cool|performance
//   thermik://fans/fixed?percent=60[&fan=0]           (alias: fans/manual)
import AppKit
import os
import ThermikCore

@MainActor final class URLRouter {
    nonisolated static let scheme = "thermik"

    enum Action: Equatable, Sendable {
        case showMain(Route?)
        case togglePanel
        case settings(SettingsTab?)
        case fanMode(FanMode)
        case fanPreset(FanPresetID)
        case fixed(percent: Double, fan: Int?)
    }

    private let env: AppEnvironment
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "url")

    init(env: AppEnvironment) { self.env = env }

    func handle(_ url: URL) {
        guard let action = Self.parse(url) else {
            log.notice("ignored link with unknown route")
            return
        }
        log.info("link: \(String(describing: action), privacy: .public)")
        perform(action)
    }

    private func perform(_ action: Action) {
        switch action {
        case .showMain(let route): env.router.showMain(route)
        case .togglePanel: env.visibility.popoverOpen ? env.router.closePopover() : env.router.openPopover()
        case .settings(let tab): env.router.showSettings(tab)
        case .fanMode(let mode): handleFanMode(mode)
        case .fanPreset(let preset): handleFanPreset(preset)
        case .fixed(let percent, let fan): handleFixed(percent: percent, fan: fan)
        }
    }

    private func handleFanMode(_ mode: FanMode) {
        guard canChangeFans(to: mode) else { return }
        if mode != .system {
            guard confirm(String(localized: "A link asks Thermik to switch the fans to “\(mode.title)”.")) else { return }
        }
        env.fans.setMode(mode, reason: .urlScheme)
    }

    private func handleFanPreset(_ preset: FanPresetID) {
        guard canChangeFans(to: .curve),
              confirm(String(localized: "A link asks Thermik to apply the “\(preset.title)” fan preset.")) else { return }
        env.fans.applyPreset(preset)
        env.fans.setMode(.curve, reason: .urlScheme)
    }

    private func handleFixed(percent: Double, fan: Int?) {
        guard canChangeFans(to: .fixed) else { return }
        guard let text = fixedConfirmationText(percent: percent, fan: fan) else { return }
        guard confirm(text) else { return }
        if fan != nil { env.fans.setLinked(false) }
        env.fans.setFixedPercent(percent, fan: fan)
        env.fans.setMode(.fixed, reason: .urlScheme)
    }

    private func fixedConfirmationText(percent: Double, fan: Int?) -> String? {
        let speed = ThermikFormat.percent(percent / 100)
        if let fan, let name = env.fans.fans.first(where: { $0.id == fan })?.displayName {
            return String(localized: "A link asks Thermik to run “\(name)” at \(speed).")
        }
        if fan == nil { return String(localized: "A link asks Thermik to run the fans at \(speed).") }
        log.notice("link names fan \(fan ?? -1, privacy: .public), which this Mac does not have")
        return nil
    }

    /// Pure parser (no side effects): nil for anything unknown.
    nonisolated static func parse(_ url: URL) -> Action? {
        guard url.scheme?.lowercased() == scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (parts.host ?? "").lowercased()
        let path = parts.path.split(separator: "/").map { $0.lowercased() }
        return parseAction(host: host, path: path, query: queryItems(from: parts))
    }

    private nonisolated static func queryItems(from parts: URLComponents) -> [String: String] {
        Dictionary((parts.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func parseAction(host: String, path: [String], query: [String: String]) -> Action? {
        switch host {
        case "open", "main": return parseOpen(path: path, query: query)
        case "panel", "popover": return .togglePanel
        case "settings": return parseSettings(path: path)
        case "fans": return parseFans(path: path, query: query)
        default: return nil
        }
    }

    private nonisolated static func parseOpen(path: [String], query: [String: String]) -> Action? {
        guard let pageName = query["page"] ?? path.first else { return .showMain(nil) }
        guard let page = Route.Page(rawValue: pageName.lowercased()) else { return nil }
        return .showMain(route(page, sensor: query["sensor"].flatMap { SensorID($0) }))
    }

    private nonisolated static func parseSettings(path: [String]) -> Action? {
        guard let name = path.first else { return .settings(nil) }
        guard let tab = SettingsTab.allCases.first(where: { $0.rawValue.lowercased() == name }) else { return nil }
        return .settings(tab)
    }

    private nonisolated static func parseFans(path: [String], query: [String: String]) -> Action? {
        switch path.first {
        case "mode": return parseFanMode(path: path)
        case "preset": return path.dropFirst().first.flatMap { FanPresetID(rawValue: $0) }.map { .fanPreset($0) }
        case "fixed", "manual": return parseFixed(query: query)
        default: return nil
        }
    }

    private nonisolated static func parseFanMode(path: [String]) -> Action? {
        switch path.dropFirst().first {
        case "auto", "system": return .fanMode(.system)
        case "curve": return .fanMode(.curve)
        case "fixed", "manual": return .fanMode(.fixed)
        case "max": return .fanMode(.max)
        default: return nil
        }
    }

    private nonisolated static func parseFixed(query: [String: String]) -> Action? {
        guard let p = query["percent"].flatMap({ Double($0) }), p.isFinite else { return nil }
        let fan = query["fan"].flatMap { Int($0) }
        if let fan, fan < 0 { return nil }
        return .fixed(percent: min(max(p, 0), 100), fan: fan)
    }

    private nonisolated static func route(_ page: Route.Page, sensor: SensorID?) -> Route {
        switch page {
        case .overview: .overview; case .sensors: .sensors(sensor); case .fans: .fans; case .battery: .battery
        case .system: .system; case .diagnostics: .diagnostics; case .logs: .logs; case .alerts: .alerts
        case .settings: .settings(nil)
        }
    }

    /// Fanless Macs ignore fan links. Without the helper (or with another app in control) the Fans page explains why.
    private func canChangeFans(to mode: FanMode) -> Bool {
        guard env.fans.hasFans else { log.notice("fan link ignored: no fans"); return false }
        guard mode == .system || env.fans.canControl else {
            log.notice("fan link: fan control unavailable, showing the Fans page")
            env.router.showMain(.fans)
            return false
        }
        return true
    }

    private func confirm(_ request: String) -> Bool {
        if env.settings.allowFanControlFromLinks { return true }
        NSApp.activate()
        let alert = makeConfirmationAlert(request: request)
        let allowed = alert.runModal() == .alertSecondButtonReturn
        if allowed, alert.suppressionButton?.state == .on { env.settings.allowFanControlFromLinks = true }
        log.info("fan link \(allowed ? "allowed" : "cancelled", privacy: .public)")
        return allowed
    }

    private func makeConfirmationAlert(request: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Allow this link to change fan control?")
        alert.informativeText = request
        configureConfirmationButtons(alert)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Always allow links to change fan control")
        return alert
    }

    private func configureConfirmationButtons(_ alert: NSAlert) {
        // Cancel is the default (Return) button: the alert takes focus from whatever the user was typing in, so a
        // stray Return must never count as consent. Allow needs a deliberate click (or Tab + Space).
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
    }
}
