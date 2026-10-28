// DiagnosticsStore.swift — Thermik (MIT). OWNER: Unit 6. Surface FROZEN; additions marked. SPEC §2.13.
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
        if let inv = sensors.inventory {
            // Re-load after a re-discovery (wake with a reopened SMC) so groups and visibility stay current.
            let signature = "\(inv.sensors.count)|\(inv.smcKeyCount)|\(inv.catalogStatus)|\(inv.fanProfile.fans.count)"
            if signature != inventorySignature { engine.load(inventory: inv); inventorySignature = signature }
        }
        // The cadence scales how long a sensor may go unread before its stuck / range timers restart (30 s, 60 s ticks).
        engine.nominalInterval = sensors.nominalInterval
        engine.observe(frame: tick.sensors, commands: fans.lastCommands, profile: fans.profile)
        let stalled = engine.stalledFans
        if stalled != stalledFans { stalledFans = stalled }
        if lastEvaluation.map({ tick.date.timeIntervalSince($0) >= Self.evaluationInterval || tick.date < $0 }) ?? true {
            evaluate(now: tick.date)
        }
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

    /// ADDED (Unit 6): "Copy report" — the Markdown report on the general pasteboard.
    func copyReport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(makeReport(), forType: .string)
    }

    // MARK: Evaluation

    private func evaluate(now: Date) {
        lastEvaluation = now
        engine.foreignControllerName = foreignControllerName(now: now)
        let slow = SlowSystemData(appleBatteryHealth: system.appleBatteryHealth, nvme: system.nvme.isEmpty ? nil : system.nvme,
                                  boot: system.boot, shutdownVerdict: system.shutdownVerdict)
        let context = DiagnosticsContext(slow: slow, battery: system.battery, helper: helperHealth(), inventory: sensors.inventory,
                                         pressure: system.pressure, pressureEventsToday: system.pressureEventsToday)
        var fresh = engine.items(context: context, now: now)
        for i in fresh.indices {
            if let old = items.first(where: { $0.id == fresh[i].id }), old.status == fresh[i].status,
               old.finding == fresh[i].finding, old.details == fresh[i].details {
                fresh[i].updated = old.updated
            }
        }
        if fresh != items { items = fresh }
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
