// MenuBarController.swift — Thermik (MIT). OWNER: Unit 7. Surface FROZEN: init(env:), install(), isItemOnScreen,
// consume(_:). The last tick consumer (SPEC §2.3.3): resolves the menu bar metrics, colours, ◆ badge and stale marker
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
        let env = self.env, debug = self.debug
        let status = StatusItemController(autosaveName: "ThermikStatusItem") {
            PopoverRoot()
                .thermikEnvironment(env)
                .environment(debug)
        }
        self.status = status
        status.onOpen = { [weak self] in self?.popoverDidOpen() }
        status.onClose = { [weak self] in self?.popoverDidClose() }
        status.menuProvider = { [weak self] in self?.makeContextMenu() }
        status.onAlternateClick = { env.router.showMain(nil) }
        status.onAppearanceChange = { [weak self] in self?.refreshLabel() }
        env.router.openPopover = { [weak self] in self?.status?.open() }
        env.router.closePopover = { [weak self] in self?.status?.close() }
        // The kit's right-click "Open Thermik" item posts `.thermikOpenMainWindow`; route it to the main window.
        openMainObserver = NotificationCenter.default.addObserver(forName: .thermikOpenMainWindow, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated { env.router.showMain(nil) }
        }

        let monitor = MenuBarVisibility(status: status, settings: env.settings)
        monitor.onChange = { [weak self] reason in
            guard let self, reason == nil, let status = self.status else { return }
            self.firstRunHint.showIfNeeded(settings: self.env.settings, status: status, itemVisible: true)
        }
        monitor.start()
        visibilityMonitor = monitor

        // Ticks stop while the sampler is paused or stuck: re-check the stale marker every few seconds (0.2 Hz).
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStale() }
        }
        timer.tolerance = 2.5
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer

        observeConfiguration()
        configureStyleCycling()
        refreshLabel()                                    // "—" immediately, before the first tick
        log.info("status item installed")
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

    /// Builds the label from the stores (the rendering decides whether anything visible changed).
    func makeLabel(appearance: NSAppearance.Name) -> (MenuBarSnapshot, MenuBarStyle, MenuBarRenderOptions) {
        let cfg = env.settings.menuBar
        let fanState = FanPanelState(fans: env.fans, debug: debug)
        // Fanless Macs default to `temp` (a stacked/temp+fan label would have nothing to show on its fan line).
        let fanless = (env.sensors.isLoaded && !env.fans.hasFans) || debug.fanless
        var style = debug.styleOverride ?? cfg.style
        if fanless && (style == .stacked || style == .tempFan) && cfg.secondary.isFanMetric { style = .temp }
        let unit = env.settings.effectiveUnit
        let readings = MenuBarReadings(sensors: env.sensors, fans: env.fans, history: env.history, fanless: fanless)

        let primary = readings.reading(cfg.primary)
        let usesSecondary = style == .stacked || style == .tempFan
        let secondary = usesSecondary ? readings.reading(cfg.secondary) : .none

        var celsius = 0.0, normalized = 0.0
        var level: ThermalLevel?
        switch primary {
        case .temperature(let c, let scale):
            celsius = c; normalized = scale.normalized(c); level = scale.level(c)
        case .rpm(let r):
            let maxRPM = readings.maxRPM
            normalized = maxRPM > 0 ? min(max(r / maxRPM, 0), 1) : 0
        case .watts, .unavailable, .none:
            break
        }
        let alert = env.alerts.hasActiveAlert || (level ?? .frost) >= .veryHot
        let badge: MenuBarBadge
        if let forced = debug.badge {
            badge = forced
        } else if fanState.safetyTemperature != nil {
            badge = .safety
        } else if cfg.showOverrideBadge && env.fans.isOverriding {
            badge = .override
        } else {
            badge = .none
        }
        var snapshot = MenuBarSnapshot(celsius: celsius, rpm: nil, normalized: normalized, alert: alert)
        snapshot.primary = primary
        snapshot.secondary = secondary
        snapshot.fahrenheit = unit == .fahrenheit
        snapshot.stale = isStale && primary.kind != .none
        snapshot.badge = badge
        if style == .sparkline, let id = Self.seriesID(cfg.primary) {
            snapshot.history = env.history.sparkline(id, points: 24).map(Double.init)
        }
        snapshot.accessibilityText = spoken(primary: primary, secondary: secondary, metricP: cfg.primary,
                                            metricS: cfg.secondary, unit: unit, stale: snapshot.stale, badge: badge)
        if let label = style.composition(cfg) {
            let values = readings.composed(label)
            snapshot.composition = label
            snapshot.composed = values
            // VoiceOver reads every value of a composed label, by its caption when it has one.
            let shown = label.items.filter { if case .none = readings.reading($0.metric) { false } else { true } }
            snapshot.accessibilityText = spoken(values: zip(shown, values).map { ($0.metric, $0.caption, $1.reading) },
                                                unit: unit, stale: snapshot.stale, badge: badge)
        }
        let options = MenuBarRenderOptions(colored: cfg.colored, alertColor: cfg.alertColor,
                                           colorBlind: env.settings.colorBlindScale, appearance: appearance)
        return (snapshot, style, options)
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
        case .rpm(let v):
            let off = v <= 50
            if case .fan(let i) = metric, let f = env.fans.fans.first(where: { $0.id == i }) {
                let name = popoverFanName(f)
                return off ? name + " " + String(localized: "Off") : String(localized: "\(name) \(ThermikFormat.rpm(v)) rpm")
            }
            return off ? String(localized: "fans off") : String(localized: "fans \(ThermikFormat.rpm(v)) rpm")
        case .watts(let w):
            return String(localized: "system power \(ThermikFormat.watts(w))")
        case .unavailable:
            return metricName(metric) + " " + String(localized: "no data")
        case .none:
            return nil
        }
    }

    private func metricName(_ m: MenuBarMetric) -> String {
        switch m {
        case .temperature(.aggregate(let k)):
            switch k {
            case .cpuAverage, .cpuHottest: return String(localized: "CPU")
            case .gpuAverage, .gpuHottest: return String(localized: "GPU")
            case .socHottest, .socDie: return String(localized: "SoC")
            default: return k.title
            }
        case .temperature(.sensor(let id)):
            return env.sensors.sensor(id)?.displayName ?? id.key
        case .fanAverage, .fanMax, .fan: return String(localized: "Fans")
        case .systemPower: return String(localized: "Power")
        case .none: return ""
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
            _ = env.settings.menuBar
            _ = env.settings.temperatureUnit
            _ = env.settings.colorBlindScale
            _ = env.settings.colorScales
            _ = env.fans.isOverriding
            _ = env.fans.status
            _ = env.fans.hasFans
            _ = env.alerts.hasActiveAlert
            _ = debug.isActive
            _ = debug.badge; _ = debug.stale; _ = debug.fanless; _ = debug.styleOverride; _ = debug.cycleStyles
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshLabel()
                self.configureStyleCycling()
                self.observeConfiguration()
            }
        }
    }

    /// DEBUG: cycles through every label style every 3 s (acceptance: "all label styles render").
    private func configureStyleCycling() {
        guard debug.cycleStyles else {
            if styleTimer != nil { styleTimer?.invalidate(); styleTimer = nil; debug.styleOverride = nil }
            return
        }
        guard styleTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let all = MenuBarStyle.allCases
                let current = self.debug.styleOverride ?? self.env.settings.menuBar.style
                let next = all[((all.firstIndex(of: current) ?? 0) + 1) % all.count]
                self.debug.styleOverride = next
                log.debug("debug style: \(next.rawValue)")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        styleTimer = t
    }

    // MARK: Right-click menu

    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        let fans = env.fans
        let state = FanPanelState(fans: fans, debug: debug)
        if state.hasFans {
            let modeItem = NSMenuItem(title: String(localized: "Fan mode"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for mode in FanMode.allCases {
                let item = MenuItemAction.item(mode.title) { [weak self] in
                    self?.env.fans.setMode(mode, reason: .user)
                    self?.env.router.requestTick()
                }
                item.state = state.mode == mode ? .on : .off
                item.isEnabled = state.canControl
                sub.addItem(item)
            }
            if !state.canControl {
                sub.addItem(.separator())
                let why = NSMenuItem(title: disabledReason(state), action: nil, keyEquivalent: "")
                why.isEnabled = false
                sub.addItem(why)
            }
            sub.autoenablesItems = false
            modeItem.submenu = sub
            m.addItem(modeItem)
            m.addItem(.separator())
        }
        m.addItem(MenuItemAction.item(String(localized: "Open Thermik")) { [weak self] in self?.env.router.showMain(nil) })
        m.addItem(MenuItemAction.item(String(localized: "Settings…"), key: ",") { [weak self] in self?.env.router.showSettings(nil) })
        #if DEBUG
        m.addItem(.separator())
        m.addItem(debugMenuItem())
        #endif
        m.addItem(.separator())
        m.addItem(withTitle: String(localized: "Quit Thermik"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.autoenablesItems = false
        return m
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
        let m = NSMenu()
        let d = debug
        func toggle(_ title: String, _ on: Bool, _ action: @escaping @MainActor () -> Void) {
            let i = MenuItemAction.item(title, action: action); i.state = on ? .on : .off; m.addItem(i)
        }
        toggle("Cycle label styles (3 s)", d.cycleStyles) { d.cycleStyles.toggle() }
        let styles = NSMenuItem(title: "Label style", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for s in MenuBarStyle.allCases {
            let i = MenuItemAction.item(s.title) { d.cycleStyles = false; d.styleOverride = s }
            i.state = d.styleOverride == s ? .on : .off
            sm.addItem(i)
        }
        sm.addItem(MenuItemAction.item("Use setting") { d.styleOverride = nil })
        styles.submenu = sm
        m.addItem(styles)
        m.addItem(.separator())
        toggle("Simulate stale readings", d.stale) { d.stale.toggle() }
        toggle("Simulate fanless Mac", d.fanless) { d.fanless.toggle() }
        toggle("Force ◆ override badge", d.badge == .override) { d.badge = d.badge == .override ? nil : .override }
        toggle("Simulate safety override (103°)", d.safetyOverrideC != nil) {
            if d.safetyOverrideC == nil { d.safetyOverrideC = 103; d.badge = .safety } else { d.safetyOverrideC = nil; d.badge = nil }
        }
        toggle("Simulate engaging", d.engaging) { d.engaging.toggle() }
        toggle("Simulate Max countdown (30 min)", d.maxDeadline != nil) {
            d.maxDeadline = d.maxDeadline == nil ? Date().addingTimeInterval(30 * 60) : nil
        }
        toggle("Simulate foreign controller (TG Pro)", d.foreignController != nil) {
            d.foreignController = d.foreignController == nil ? "TG Pro" : nil
        }
        let helper = NSMenuItem(title: "Helper state", action: nil, keyEquivalent: "")
        let hm = NSMenu()
        for a in [HelperAvailability.notInstalled, .requiresApproval, .needsUpgrade, .unreachable, .connecting] {
            let i = MenuItemAction.item(a.rawValue) { d.helper = d.helper == a ? nil : a }
            i.state = d.helper == a ? .on : .off
            hm.addItem(i)
        }
        hm.addItem(MenuItemAction.item("Real state") { d.helper = nil })
        helper.submenu = hm
        m.addItem(helper)
        let pressure = NSMenuItem(title: "Thermal pressure", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        for p in ThermalPressure.allCases {
            let i = MenuItemAction.item(p.title) { d.pressure = d.pressure == p ? nil : p }
            i.state = d.pressure == p ? .on : .off
            pm.addItem(i)
        }
        pm.addItem(MenuItemAction.item("Real pressure") { d.pressure = nil })
        pressure.submenu = pm
        m.addItem(pressure)
        m.addItem(.separator())
        m.addItem(MenuItemAction.item("Show first-run hint") { [weak self] in
            guard let b = self?.status?.item.button else { return }
            self?.firstRunHint.show(relativeTo: b)
        })
        m.addItem(MenuItemAction.item("Show hidden-item hint") { [weak self] in
            self?.visibilityMonitor?.showHint(self?.visibilityMonitor?.reason ?? .notch)
        })
        m.addItem(MenuItemAction.item("Reset debug overrides") { d.reset() })
        root.submenu = m
        return root
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
