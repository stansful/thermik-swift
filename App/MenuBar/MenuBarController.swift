// MenuBarController.swift — Thermik (MIT).
// The last tick consumer: resolves the menu bar metrics, colours, ◆ badge and stale marker
// into a label snapshot (cheap; the image is redrawn only when the visible text changes), owns the status item, the
// popover, hidden/notch detection, the first-run hint and the right-click menu (Mode ▸, Open Thermik, Settings…, Quit).
import AppKit
import SwiftUI
import ThermikCore
import os

private let log = Logger(subsystem: "app.thermik.Thermik", category: "menubar")

@MainActor final class MenuBarController: TickConsumer {
    private let env: AppEnvironment
    private var status: StatusItemController?
    private var visibilityMonitor: MenuBarVisibility?
    private let firstRunHint = FirstRunHint()
    private var openMainObserver: (any NSObjectProtocol)?
    private var staleTimer: Timer?
    private var styleTimer: Timer?
    private var lastStale = false
    /// Forced UI states for manual verification (DEBUG builds; empty in Release).
    let debug = PopoverDebugOverrides()

    init(env: AppEnvironment) { self.env = env }

    func install() {
        guard status == nil else { return }
        let status = makeStatus()
        self.status = status
        configureStatus(status)
        installVisibilityMonitor(status)
        installStaleTimer()
        finishInstall()
        log.info("status item installed")
    }

    private func makeStatus() -> StatusItemController {
        let env = self.env, debug = self.debug
        return StatusItemController(autosaveName: "ThermikStatusItem") {
            PopoverRoot()
                .thermikEnvironment(env)
                .environment(debug)
        }
    }

    private func configureStatus(_ status: StatusItemController) {
        let env = self.env
        status.onOpen = { [weak self] in self?.popoverDidOpen() }
        status.onClose = { [weak self] in self?.popoverDidClose() }
        status.menuProvider = { [weak self] in self?.makeContextMenu() }
        status.onAlternateClick = { env.router.showMain(nil) }
        status.onAppearanceChange = { [weak self] in self?.refreshLabel() }
        env.router.openPopover = { [weak self] in self?.status?.open() }
        env.router.closePopover = { [weak self] in self?.status?.close() }
        observeOpenMain()
    }

    private func observeOpenMain() {
        let env = self.env
        // The kit's right-click "Open Thermik" item posts `.thermikOpenMainWindow`; route it to the main window.
        openMainObserver = NotificationCenter.default.addObserver(forName: .thermikOpenMainWindow, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated { env.router.showMain(nil) }
        }
    }

    private func installVisibilityMonitor(_ status: StatusItemController) {
        let monitor = MenuBarVisibility(status: status, settings: env.settings)
        monitor.onChange = { [weak self] reason in
            guard let self, reason == nil, let status = self.status else { return }
            self.firstRunHint.showIfNeeded(settings: self.env.settings, status: status, itemVisible: true)
        }
        monitor.start()
        visibilityMonitor = monitor
    }

    private func installStaleTimer() {
        // Ticks stop while the sampler is paused or stuck: re-check the stale marker every few seconds (0.2 Hz).
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStale() }
        }
        timer.tolerance = 2.5
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func finishInstall() {
        observeConfiguration()
        configureStyleCycling()
        refreshLabel()                                    // "—" immediately, before the first tick
    }

    var isItemOnScreen: Bool { status?.isOnScreen ?? false }

    func consume(_ tick: Tick) {
        refreshLabel()
        if let status, !env.settings.menuBarHintShown, visibilityMonitor?.isHidden == false {
            firstRunHint.showIfNeeded(settings: env.settings, status: status, itemVisible: status.isOnScreen)
        }
    }

    // MARK: Label

    private func refreshLabel() {
        guard let status else { return }
        let (snapshot, style, options) = makeLabel(appearance: status.menuBarAppearance)
        lastStale = snapshot.stale
        status.update(snapshot, style: style, options: options)
    }

    private func checkStale() {
        let stale = isStale
        if stale != lastStale { refreshLabel() }
    }

    private var isStale: Bool { env.sensors.showsStaleReadings || debug.stale }

    private struct LabelValues {
        let cfg: MenuBarConfig
        let unit: UnitTemperature
        let style: MenuBarStyle
        let readings: MenuBarReadings
        let primary: MenuBarReading
        let secondary: MenuBarReading
        let fanState: FanPanelState
    }

    /// Builds the label from the stores (the rendering decides whether anything visible changed).
    func makeLabel(appearance: NSAppearance.Name) -> (MenuBarSnapshot, MenuBarStyle, MenuBarRenderOptions) {
        let values = labelValues()
        var snapshot = makeSnapshot(for: values)
        addHistory(to: &snapshot, values: values)
        snapshot.accessibilityText = spoken(primary: values.primary, secondary: values.secondary, metricP: values.cfg.primary,
                                            metricS: values.cfg.secondary, unit: values.unit, stale: snapshot.stale, badge: snapshot.badge)
        addComposed(to: &snapshot, values: values)
        let options = MenuBarRenderOptions(colored: values.cfg.colored, alertColor: values.cfg.alertColor,
                                           colorBlind: env.settings.colorBlindScale, appearance: appearance)
        return (snapshot, values.style, options)
    }

    private func labelValues() -> LabelValues {
        let cfg = env.settings.menuBar
        let fanState = FanPanelState(fans: env.fans, debug: debug)
        let fanless = (env.sensors.isLoaded && !env.fans.hasFans) || debug.fanless
        let style = resolvedStyle(cfg: cfg, fanless: fanless)
        let readings = MenuBarReadings(sensors: env.sensors, fans: env.fans, history: env.history, fanless: fanless)
        let primary = readings.reading(cfg.primary)
        let usesSecondary = style == .stacked || style == .tempFan
        let secondary = usesSecondary ? readings.reading(cfg.secondary) : .none
        return LabelValues(cfg: cfg, unit: env.settings.effectiveUnit, style: style, readings: readings,
                           primary: primary, secondary: secondary, fanState: fanState)
    }

    private func resolvedStyle(cfg: MenuBarConfig, fanless: Bool) -> MenuBarStyle {
        let style = debug.styleOverride ?? cfg.style
        // Fanless Macs default to `temp` (a stacked/temp+fan label would have nothing to show on its fan line).
        if fanless && (style == .stacked || style == .tempFan) && cfg.secondary.isFanMetric { return .temp }
        return style
    }

    private func makeSnapshot(for values: LabelValues) -> MenuBarSnapshot {
        let metrics = labelMetrics(for: values.primary, readings: values.readings)
        let alert = env.alerts.hasActiveAlert || (metrics.level ?? .frost) >= .veryHot
        let badge = labelBadge(for: values)
        var snapshot = MenuBarSnapshot(celsius: metrics.celsius, rpm: nil, normalized: metrics.normalized, alert: alert)
        snapshot.primary = values.primary
        snapshot.secondary = values.secondary
        snapshot.fahrenheit = values.unit == .fahrenheit
        snapshot.stale = isStale && values.primary.kind != .none
        snapshot.badge = badge
        return snapshot
    }

    private func labelMetrics(for primary: MenuBarReading, readings: MenuBarReadings)
            -> (celsius: Double, normalized: Double, level: ThermalLevel?) {
        switch primary {
        case .temperature(let c, let scale): return (c, scale.normalized(c), scale.level(c))
        case .rpm(let r):
            let maxRPM = readings.maxRPM
            return (0, maxRPM > 0 ? min(max(r / maxRPM, 0), 1) : 0, nil)
        case .watts, .unavailable, .none: return (0, 0, nil)
        }
    }

    private func labelBadge(for values: LabelValues) -> MenuBarBadge {
        if let forced = debug.badge { return forced }
        if values.fanState.safetyTemperature != nil { return .safety }
        if values.cfg.showOverrideBadge && env.fans.isOverriding { return .override }
        return .none
    }

    private func addHistory(to snapshot: inout MenuBarSnapshot, values: LabelValues) {
        guard values.style == .sparkline, let id = Self.seriesID(values.cfg.primary) else { return }
        snapshot.history = env.history.sparkline(id, points: 24).map(Double.init)
    }

    private func addComposed(to snapshot: inout MenuBarSnapshot, values: LabelValues) {
        guard let label = values.style.composition(values.cfg) else { return }
        let resolved = values.readings.composed(label)
        snapshot.composition = label
        snapshot.composed = resolved
        // VoiceOver reads every value of a composed label, by its caption when it has one.
        let shown = label.items.filter { if case .none = values.readings.reading($0.metric) { false } else { true } }
        snapshot.accessibilityText = spoken(values: zip(shown, resolved).map { ($0.metric, $0.caption, $1.reading) },
                                            unit: values.unit, stale: snapshot.stale, badge: snapshot.badge)
    }

    /// History series behind a menu bar metric, for the sparkline style (fan average/max: the first fan's curve).
    static func seriesID(_ metric: MenuBarMetric) -> SeriesID? {
        switch metric {
        case .temperature(.aggregate(let k)): .aggregate(k)
        case .temperature(.sensor(let id)): .sensor(id)
        case .fan(let i): .fanRPM(i)
        case .fanAverage, .fanMax: .fanRPM(0)
        case .systemPower: .power(.systemTotal)
        case .none: nil
        }
    }

    // MARK: VoiceOver / tooltip: "Thermik, CPU 62 degrees, fans 1840 rpm"

    private func spoken(primary: MenuBarReading, secondary: MenuBarReading, metricP: MenuBarMetric, metricS: MenuBarMetric,
                        unit: UnitTemperature, stale: Bool, badge: MenuBarBadge) -> String {
        var parts = ["Thermik"]
        if let p = phrase(primary, metric: metricP, unit: unit) { parts.append(p) }
        if let s = phrase(secondary, metric: metricS, unit: unit) { parts.append(s) }
        return finish(parts, stale: stale, badge: badge)
    }

    private func spoken(values: [(metric: MenuBarMetric, caption: String, reading: MenuBarReading)], unit: UnitTemperature,
                        stale: Bool, badge: MenuBarBadge) -> String {
        var parts = ["Thermik"]
        for v in values {
            guard let p = phrase(v.reading, metric: v.metric, unit: unit) else { continue }
            guard !v.caption.isEmpty, case .temperature = v.reading else { parts.append(p); continue }
            parts.append(v.caption + " " + String(localized: "\(ThermikFormat.degrees(v.reading.celsius ?? 0, unit: unit)) degrees"))
        }
        return finish(parts, stale: stale, badge: badge)
    }

    private func finish(_ partsIn: [String], stale: Bool, badge: MenuBarBadge) -> String {
        var parts = partsIn
        if stale { parts.append(String(localized: "readings paused")) }
        switch badge {
        case .override: parts.append(String(localized: "Thermik controls the fans"))
        case .safety: parts.append(String(localized: "Safety override: fans at maximum"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }

    private func phrase(_ r: MenuBarReading, metric: MenuBarMetric, unit: UnitTemperature) -> String? {
        switch r {
        case .temperature(let c, _):
            return metricName(metric) + " " + String(localized: "\(ThermikFormat.degrees(c, unit: unit)) degrees")
        case .rpm(let v): return rpmPhrase(v, metric: metric)
        case .watts(let w): return String(localized: "system power \(ThermikFormat.watts(w))")
        case .unavailable: return metricName(metric) + " " + String(localized: "no data")
        case .none: return nil
        }
    }

    private func rpmPhrase(_ value: Double, metric: MenuBarMetric) -> String {
        let off = value <= 50
        if case .fan(let i) = metric, let f = env.fans.fans.first(where: { $0.id == i }) {
            let name = popoverFanName(f)
            return off ? name + " " + String(localized: "Off") : String(localized: "\(name) \(ThermikFormat.rpm(value)) rpm")
        }
        return off ? String(localized: "fans off") : String(localized: "fans \(ThermikFormat.rpm(value)) rpm")
    }

    private func metricName(_ m: MenuBarMetric) -> String {
        switch m {
        case .temperature(.aggregate(let k)): return aggregateMetricName(k)
        case .temperature(.sensor(let id)): return env.sensors.sensor(id)?.displayName ?? id.key
        case .fanAverage, .fanMax, .fan: return String(localized: "Fans")
        case .systemPower: return String(localized: "Power")
        case .none: return ""
        }
    }

    private func aggregateMetricName(_ kind: AggregateKind) -> String {
        switch kind {
        case .cpuAverage, .cpuHottest: return String(localized: "CPU")
        case .gpuAverage, .gpuHottest: return String(localized: "GPU")
        case .socHottest, .socDie: return String(localized: "SoC")
        default: return kind.title
        }
    }

    // MARK: Popover lifecycle

    private func popoverDidOpen() {
        firstRunHint.close()
        env.visibility.popoverOpen = true          // 1 s cadence + all visible sensors + IOReport (SPEC §2.3.4)
        env.router.requestTick()
    }

    private func popoverDidClose() {
        env.visibility.popoverOpen = false
    }

    // MARK: Observation (settings / fan state changes re-render at once instead of on the next tick)

    private func observeConfiguration() {
        withObservationTracking {
            trackConfiguration()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.configurationDidChange()
            }
        }
    }

    private func trackConfiguration() {
        trackLabelConfiguration()
        trackFanConfiguration()
        trackDebugConfiguration()
    }

    private func trackLabelConfiguration() {
        _ = env.settings.menuBar
        _ = env.settings.temperatureUnit
        _ = env.settings.colorBlindScale
        _ = env.settings.colorScales
        _ = env.alerts.hasActiveAlert
    }

    private func trackFanConfiguration() {
        _ = env.fans.isOverriding
        _ = env.fans.status
        _ = env.fans.hasFans
    }

    private func trackDebugConfiguration() {
        _ = debug.isActive
        _ = debug.badge
        _ = debug.stale
        _ = debug.fanless
        _ = debug.styleOverride
        _ = debug.cycleStyles
    }

    private func configurationDidChange() {
        refreshLabel()
        configureStyleCycling()
        observeConfiguration()
    }

    /// DEBUG: cycles through every label style every 3 s (acceptance: "all label styles render").
    private func configureStyleCycling() {
        guard debug.cycleStyles else { stopStyleCycling(); return }
        guard styleTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cycleStyle() }
        }
        RunLoop.main.add(t, forMode: .common)
        styleTimer = t
    }

    private func stopStyleCycling() {
        guard styleTimer != nil else { return }
        styleTimer?.invalidate()
        styleTimer = nil
        debug.styleOverride = nil
    }

    private func cycleStyle() {
        let all = MenuBarStyle.allCases
        let current = debug.styleOverride ?? env.settings.menuBar.style
        let next = all[((all.firstIndex(of: current) ?? 0) + 1) % all.count]
        debug.styleOverride = next
        log.debug("debug style: \(next.rawValue)")
    }

    // MARK: Right-click menu

    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        addFanModeItem(to: m)
        addMainMenuItems(to: m)
        addDebugMenuItem(to: m)
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Quit Thermik"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.autoenablesItems = false
        return m
    }

    private func addFanModeItem(to m: NSMenu) {
        let state = FanPanelState(fans: env.fans, debug: debug)
        guard state.hasFans else { return }
        let modeItem = NSMenuItem(title: String(localized: "Fan mode"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        addFanModeItems(to: sub, state: state)
        addDisabledReason(to: sub, state: state)
        sub.autoenablesItems = false
        modeItem.submenu = sub
        m.addItem(modeItem)
        m.addItem(.separator())
    }

    private func addFanModeItems(to sub: NSMenu, state: FanPanelState) {
        for mode in FanMode.allCases {
            sub.addItem(fanModeItem(mode, state: state))
        }
    }

    private func fanModeItem(_ mode: FanMode, state: FanPanelState) -> NSMenuItem {
        let item = MenuItemAction.item(mode.title) { [weak self] in
            self?.env.fans.setMode(mode, reason: .user)
            self?.env.router.requestTick()
        }
        item.state = state.mode == mode ? .on : .off
        item.isEnabled = state.canControl
        return item
    }

    private func addDisabledReason(to sub: NSMenu, state: FanPanelState) {
        guard !state.canControl else { return }
        sub.addItem(.separator())
        let why = NSMenuItem(title: disabledReason(state), action: nil, keyEquivalent: "")
        why.isEnabled = false
        sub.addItem(why)
    }

    private func addMainMenuItems(to m: NSMenu) {
        m.addItem(MenuItemAction.item(String(localized: "Open Thermik")) { [weak self] in self?.env.router.showMain(nil) })
        m.addItem(MenuItemAction.item(String(localized: "Settings…"), key: ",") { [weak self] in self?.env.router.showSettings(nil) })
    }

    private func addDebugMenuItem(to m: NSMenu) {
        #if DEBUG
        m.addItem(.separator())
        m.addItem(debugMenuItem())
        #endif
    }

    private func disabledReason(_ s: FanPanelState) -> String {
        if let a = s.helperAvailability { return a.title }
        if s.isForeign {
            return s.foreignName.map { String(localized: "Fan control is in use by \($0)") }
                ?? String(localized: "Another app is controlling the fans")
        }
        return String(localized: "Fan control is not available")
    }

    #if DEBUG
    /// Developer-only verification menu (not localized: never shipped in Release builds).
    private func debugMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        root.submenu = makeDebugMenu()
        return root
    }

    private func makeDebugMenu() -> NSMenu {
        let m = NSMenu()
        let d = debug
        addDebugStyleItems(to: m)
        addDebugReadingItems(to: m)
        addDebugFanStateItems(to: m)
        addDebugHelperItems(to: m)
        addDebugPressureItems(to: m)
        addDebugHintItems(to: m)
        m.addItem(MenuItemAction.item("Reset debug overrides") { d.reset() })
        return m
    }

    private func addToggle(_ title: String, selected: Bool, to m: NSMenu, action: @escaping @MainActor () -> Void) {
        let item = MenuItemAction.item(title, action: action)
        item.state = selected ? .on : .off
        m.addItem(item)
    }

    private func addDebugStyleItems(to m: NSMenu) {
        let d = debug
        addToggle("Cycle label styles (3 s)", selected: d.cycleStyles, to: m) { d.cycleStyles.toggle() }
        let styles = NSMenuItem(title: "Label style", action: nil, keyEquivalent: "")
        styles.submenu = debugStylesMenu()
        m.addItem(styles)
        m.addItem(.separator())
    }

    private func debugStylesMenu() -> NSMenu {
        let d = debug
        let sm = NSMenu()
        for s in MenuBarStyle.allCases {
            sm.addItem(debugStyleItem(s, overrides: d))
        }
        sm.addItem(MenuItemAction.item("Use setting") { d.styleOverride = nil })
        return sm
    }

    private func debugStyleItem(_ style: MenuBarStyle, overrides d: PopoverDebugOverrides) -> NSMenuItem {
        let item = MenuItemAction.item(style.title) {
            d.cycleStyles = false
            d.styleOverride = style
        }
        item.state = d.styleOverride == style ? .on : .off
        return item
    }

    private func addDebugReadingItems(to m: NSMenu) {
        let d = debug
        addToggle("Simulate stale readings", selected: d.stale, to: m) { d.stale.toggle() }
        addToggle("Simulate fanless Mac", selected: d.fanless, to: m) { d.fanless.toggle() }
        addToggle("Force ◆ override badge", selected: d.badge == .override, to: m) { d.badge = d.badge == .override ? nil : .override }
        addToggle("Simulate safety override (103°)", selected: d.safetyOverrideC != nil, to: m) { Self.toggleSafetyOverride(d) }
    }

    private static func toggleSafetyOverride(_ d: PopoverDebugOverrides) {
        if d.safetyOverrideC == nil {
            d.safetyOverrideC = 103
            d.badge = .safety
        } else {
            d.safetyOverrideC = nil
            d.badge = nil
        }
    }

    private func addDebugFanStateItems(to m: NSMenu) {
        let d = debug
        addToggle("Simulate engaging", selected: d.engaging, to: m) { d.engaging.toggle() }
        addToggle("Simulate Max countdown (30 min)", selected: d.maxDeadline != nil, to: m) {
            d.maxDeadline = d.maxDeadline == nil ? Date().addingTimeInterval(30 * 60) : nil
        }
        addToggle("Simulate foreign controller (TG Pro)", selected: d.foreignController != nil, to: m) {
            d.foreignController = d.foreignController == nil ? "TG Pro" : nil
        }
    }

    private func addDebugHelperItems(to m: NSMenu) {
        let helper = NSMenuItem(title: "Helper state", action: nil, keyEquivalent: "")
        helper.submenu = debugHelperMenu()
        m.addItem(helper)
    }

    private func debugHelperMenu() -> NSMenu {
        let d = debug
        let hm = NSMenu()
        for a in [HelperAvailability.notInstalled, .requiresApproval, .needsUpgrade, .unreachable, .connecting] {
            hm.addItem(debugHelperItem(a, overrides: d))
        }
        hm.addItem(MenuItemAction.item("Real state") { d.helper = nil })
        return hm
    }

    private func debugHelperItem(_ availability: HelperAvailability, overrides d: PopoverDebugOverrides) -> NSMenuItem {
        let item = MenuItemAction.item(availability.rawValue) { d.helper = d.helper == availability ? nil : availability }
        item.state = d.helper == availability ? .on : .off
        return item
    }

    private func addDebugPressureItems(to m: NSMenu) {
        let pressure = NSMenuItem(title: "Thermal pressure", action: nil, keyEquivalent: "")
        pressure.submenu = debugPressureMenu()
        m.addItem(pressure)
    }

    private func debugPressureMenu() -> NSMenu {
        let d = debug
        let pm = NSMenu()
        for p in ThermalPressure.allCases {
            pm.addItem(debugPressureItem(p, overrides: d))
        }
        pm.addItem(MenuItemAction.item("Real pressure") { d.pressure = nil })
        return pm
    }

    private func debugPressureItem(_ pressure: ThermalPressure, overrides d: PopoverDebugOverrides) -> NSMenuItem {
        let item = MenuItemAction.item(pressure.title) { d.pressure = d.pressure == pressure ? nil : pressure }
        item.state = d.pressure == pressure ? .on : .off
        return item
    }

    private func addDebugHintItems(to m: NSMenu) {
        m.addItem(.separator())
        m.addItem(firstRunHintDebugItem())
        m.addItem(hiddenHintDebugItem())
    }

    private func firstRunHintDebugItem() -> NSMenuItem {
        MenuItemAction.item("Show first-run hint") { [weak self] in
            guard let b = self?.status?.item.button else { return }
            self?.firstRunHint.show(relativeTo: b)
        }
    }

    private func hiddenHintDebugItem() -> NSMenuItem {
        MenuItemAction.item("Show hidden-item hint") { [weak self] in
            self?.visibilityMonitor?.showHint(self?.visibilityMonitor?.reason ?? .notch)
        }
    }
    #endif
}

extension MenuBarMetric {
    var isFanMetric: Bool {
        switch self { case .fanAverage, .fanMax, .fan: true; default: false }
    }
}

/// Closure-backed NSMenuItem target (kept alive by the item's representedObject).
@MainActor private final class MenuItemAction: NSObject {
    private let handler: @MainActor () -> Void
    private init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func run(_ sender: Any?) { handler() }

    static func item(_ title: String, key: String = "", action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuItemAction(action)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.target = target
        item.representedObject = target
        return item
    }
}
