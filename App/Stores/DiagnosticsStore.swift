// DiagnosticsStore.swift — Thermik (MIT).
//
// Feeds every tick into DiagnosticsEngine (fan stall / target mismatch / foreign control, stuck sensors) and
// re-evaluates the items every 5 s from the stores' slow data. Items whose content did not change keep their
// `updated` date, so the Diagnostics page re-renders only on change. The fanStalled alert reads `stalledFans`.
import AppKit
import Foundation
import Observation
import ThermikCore

@MainActor @Observable final class DiagnosticsStore: TickConsumer {
    @ObservationIgnored let sensors: SensorStore
    @ObservationIgnored let fans: FanStore
    @ObservationIgnored let system: SystemStore
    @ObservationIgnored let helper: HelperManager
    @ObservationIgnored let sampler: any SystemSampling
    @ObservationIgnored let events: EventLogStore

    private(set) var items: [DiagnosticItem] = []
    private(set) var powerLog: [PowerLogEvent] = []
    private(set) var isLoadingPowerLog = false
    var overall: DiagnosticStatus { items.map(\.status).max() ?? .unknown }
    /// Fans the engine considers stalled (feeds the fanStalled alert).
    private(set) var stalledFans: [Int] = []

    static let evaluationInterval: TimeInterval = 5
    static let reportEventCount = 50

    @ObservationIgnored private var engine = DiagnosticsEngine()
    @ObservationIgnored private var inventorySignature: String?
    @ObservationIgnored private var lastEvaluation: Date?
    @ObservationIgnored private var installedControllers: (checked: Date, products: [String])?

    init(sensors: SensorStore, fans: FanStore, system: SystemStore, helper: HelperManager, sampler: any SystemSampling,
         events: EventLogStore) {
        self.sensors = sensors; self.fans = fans; self.system = system; self.helper = helper; self.sampler = sampler
        self.events = events
    }

    func consume(_ tick: Tick) {
        loadInventoryIfNeeded()
        // The cadence scales how long a sensor may go unread before its stuck / range timers restart (30 s, 60 s ticks).
        engine.nominalInterval = sensors.nominalInterval
        engine.observe(frame: tick.sensors, commands: fans.lastCommands, profile: fans.profile)
        updateStalledFans()
        if shouldEvaluate(at: tick.date) { evaluate(now: tick.date) }
    }

    private func loadInventoryIfNeeded() {
        guard let inventory = sensors.inventory else { return }
        // Re-load after a re-discovery (wake with a reopened SMC) so groups and visibility stay current.
        let signature = "\(inventory.sensors.count)|\(inventory.smcKeyCount)|\(inventory.catalogStatus)|\(inventory.fanProfile.fans.count)"
        guard signature != inventorySignature else { return }
        engine.load(inventory: inventory)
        inventorySignature = signature
    }

    private func updateStalledFans() {
        let stalled = engine.stalledFans
        if stalled != stalledFans { stalledFans = stalled }
    }

    private func shouldEvaluate(at date: Date) -> Bool {
        guard let lastEvaluation else { return true }
        return date.timeIntervalSince(lastEvaluation) >= Self.evaluationInterval || date < lastEvaluation
    }

    /// Re-evaluate everything now (cheap; slow data comes from SystemStore).
    func refresh() { evaluate(now: Date()) }

    /// `pmset -g log` on demand (1.4–3.4 s, off-main).
    func loadPowerLog() async {
        guard !isLoadingPowerLog else { return }
        isLoadingPowerLog = true
        powerLog = await sampler.powerLog(limit: 300)
        isLoadingPowerLog = false
    }

    /// Markdown report for GitHub issues (serials redacted) — "Copy report".
    func makeReport() -> String {
        refresh()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return engine.report(items: items, machine: system.machine, inventory: sensors.inventory, appVersion: version + build)
            + DiagnosticsEngine.eventsMarkdown(events.events, limit: Self.reportEventCount)
    }

    /// "Copy report" — the Markdown report on the general pasteboard.
    func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(makeReport(), forType: .string)
    }

    // MARK: Evaluation

    private func evaluate(now: Date) {
        lastEvaluation = now
        engine.foreignControllerName = foreignControllerName(now: now)
        var fresh = engine.items(context: diagnosticsContext(), now: now)
        preserveUpdateDates(in: &fresh)
        if fresh != items { items = fresh }
    }

    private func diagnosticsContext() -> DiagnosticsContext {
        let slow = SlowSystemData(appleBatteryHealth: system.appleBatteryHealth, nvme: system.nvme.isEmpty ? nil : system.nvme,
                                  boot: system.boot, shutdownVerdict: system.shutdownVerdict)
        return DiagnosticsContext(slow: slow, battery: system.battery, helper: helperHealth(), inventory: sensors.inventory,
                                  pressure: system.pressure, pressureEventsToday: system.pressureEventsToday)
    }

    private func preserveUpdateDates(in fresh: inout [DiagnosticItem]) {
        for index in fresh.indices {
            guard let old = items.first(where: { $0.id == fresh[index].id }), old.status == fresh[index].status,
                  old.finding == fresh[index].finding, old.details == fresh[index].details else { continue }
            fresh[index].updated = old.updated
        }
    }

    /// Thermik's helper as the Diagnostics page should show it.
    private func helperHealth() -> HelperHealth {
        if sensors.isLoaded, !fans.hasFans { return .notApplicable }
        if case .foreignController(let name) = fans.status { return .foreignController(Self.plausible(name)) }
        return helper.health
    }

    /// FanStore's name for a foreign controller when it is a plausible fan controller (never a battery charge limiter),
    /// else the first installed known fan-control helper (checked every 10 min; presence of files only).
    private func foreignControllerName(now: Date) -> String? {
        if let name = Self.plausible(fans.foreignControllerName) { return name }
        guard engine.foreignControlSuspected || fans.foreignControllerName != nil else { return nil }
        if installedControllers.map({ now.timeIntervalSince($0.checked) > 600 || now < $0.checked }) ?? true {
            installedControllers = (now, DiagnosticsEngine.installedFanControlProducts())
        }
        return installedControllers?.products.first
    }

    private static func plausible(_ name: String?) -> String? {
        guard let name, !name.isEmpty, DiagnosticsEngine.isPlausibleFanController(name) else { return nil }
        return name
    }
}
