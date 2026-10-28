// SamplingCoordinator.swift — Thermik (MIT). Basic loop by Unit 0; OWNER: Unit 5 (adaptive cadence §2.3.4,
// per-reader cadences, sleep/wake pause, request building from every consumer's needs). Surface FROZEN.
//
// One loop (Task + ContinuousClock) on the main actor. Each tick awaits both samplers concurrently (their actors
// do the IOKit work off the main thread), then hands one `Tick` to the consumers in the fixed order of §2.3.3.
//   cadence    1 s while the popover or a live main-window page is visible, while Thermik drives the fans, or
//              while a sensor is inspected; `settings.updateInterval` (default 2 s) otherwise
//   keys       headline + safety + pinned + alert subjects + menu-bar sensor + log columns + curve input
//              (≈ 30–40 on M4 Max); every listed sensor while the popover / Overview / Sensors page is visible (≈ 85)
//   readers    thermal pressure every tick; CPU/GPU load every tick on the System page, else 5 s; memory 2 s / 10 s;
//              battery 5 s (every tick on the Battery page, 60 s retries on desktops); power sources on IOPS
//              notifications + 30 s; IOReport only on the System page; NVMe SMART 60 s; system_profiler 6 h; boot
//              history at launch and after wake. The CSV log keeps usage / IOReport power per tick while UI is visible.
// The interval is re-read before every sleep. A change that needs fresher data (popover opened) wakes the sleep and
// ticks at once; the loop never bursts to catch up after a stall. Per-tick timings: category "sampling", .debug.
import Foundation
import os
import ThermikCore

@MainActor final class SamplingCoordinator {
    private let env: AppEnvironment
    private let consumers: [TickConsumer]
    private let clock = ContinuousClock()
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "sampling")
    private var task: Task<Void, Never>?
    /// The loop's current sleep; cancelling it wakes the loop early.
    private var sleeper: Task<Void, Never>?
    private var staleWatchdog: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var lastTick: ContinuousClock.Instant?            // start of the previous tick (measured dt)
    private var lastSlot: ContinuousClock.Instant?            // grid slot of the previous tick (cadence)
    private var lastTickEnd: ContinuousClock.Instant?
    private var lastNominal: TimeInterval?
    private(set) var isPaused = false
    /// Bumped by pause()/stop(): a tick whose sampling straddles a pause is dropped instead of delivered.
    private var generation = 0
    private var started = false
    private var wakePending = false
    private var tickRequested = false
    // Cadence change detection
    private var lastFast = false
    private var lastNeedsAll = false
    private var lastNeedsSoC = false
    private var lastInspected: SensorID?
    private var lastShowHidden = false
    private var lastIntervalSeconds: TimeInterval = 0
    // Reader schedule
    private var lastRead: [Reader: ContinuousClock.Instant] = [:]
    private var powerSourcesDirty = true
    private var batteryMissing = false
    private var slowInFlight: SlowDataRequest = []
    private var lastAppleBatteryHealth: ContinuousClock.Instant?
    private var lastNVMe: ContinuousClock.Instant?

    private enum Reader: Hashable { case cpu, memory, battery, powerSources }

    /// Fast cadence while something is watched or the fans are driven.
    static let fastInterval: TimeInterval = 1
    /// On-demand ticks (`requestTickSoon`, cadence changes) never come closer than this to the previous tick.
    private static let minimumSpacing: Duration = .milliseconds(250)
    /// Ticks per history summary in the log (.debug).
    private static let historyLogEvery: UInt64 = 60

    init(env: AppEnvironment, consumers: [TickConsumer]) { self.env = env; self.consumers = consumers }

    /// Discovery (sensors + machine + slow data), then the loop (SPEC §2.3.5 steps 4–6).
    func start() async {
        guard !started else { return }
        started = true
        await discoverSensors()
        let systemSampler = env.systemSampler
        env.system.setMachine(await systemSampler.start())
        // Boot history before the first tick: the abnormal-shutdown alert is evaluated once, on the first tick. A slow
        // reader (Intel `log show`) gets 3 s; its result is applied whenever it arrives.
        let system = env.system
        slowInFlight.insert(.boot)
        let bootReady = await waitAtMost(.seconds(3)) { [weak self] in
            let data = await systemSampler.slowData(.boot)
            system.apply(slow: data)
            self?.slowInFlight.remove(.boot)
        }
        if !bootReady { log.notice("boot history still loading after 3 s; starting the loop") }
        refreshSlowData(env.settings.driveTemperatures ? [.appleBatteryHealth, .nvme] : [.appleBatteryHealth])
        lastFast = needsFastCadence
        lastNeedsAll = env.visibility.needsAllSensors
        lastNeedsSoC = env.visibility.needsSoCMetrics
        lastInspected = env.visibility.inspectedSensor
        lastShowHidden = env.settings.showHiddenSensors
        lastIntervalSeconds = nominalSeconds
        observeCadenceInputs()
        runLoop()
    }

    func stop() {
        generation &+= 1
        task?.cancel(); task = nil
        sleeper?.cancel()
        staleWatchdog?.cancel()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        generation &+= 1
        staleWatchdog?.cancel()
        wakeLoop()
        log.info("sampling paused")
    }

    func resume(afterWake: Bool) {
        isPaused = false
        if afterWake {
            wakePending = true                 // next tick: isFirstAfterWake (filters restart)
            lastRead.removeAll()               // every reader runs on the first tick after wake
            powerSourcesDirty = true
            refreshSlowData(.boot)
            if !env.sensors.isLoaded {         // discovery failed at launch (SMC not ready): try again
                Task { @MainActor [weak self] in
                    await self?.discoverSensors()
                    self?.requestTickSoon()
                }
            }
        }
        log.info("sampling resumed\(afterWake ? " after wake" : "", privacy: .public)")
        tickRequested = true
        wakeLoop()
    }

    /// Extra tick ASAP (coalesced: at most one pending). Wired to AppRouter.requestTick by AppDelegate.
    func requestTickSoon() {
        guard !isPaused else { return }
        tickRequested = true
        wakeLoop()
    }

    /// IOPS notification (PowerEventMonitor): read the power sources on the next tick.
    func powerSourcesChanged() { powerSourcesDirty = true }

    /// Current tick interval (1 s while visible or controlling, else settings.updateInterval).
    var interval: Duration { .seconds(nominalSeconds) }

    private var nominalSeconds: TimeInterval {
        let user = env.settings.updateInterval
        return needsFastCadence ? min(user, Self.fastInterval) : user
    }

    /// SPEC §2.3.4: popover open, a live main-window page (Overview, Sensors, Fans, Battery, System) or the sensor
    /// inspector, or fan control engaged (the engine runs at 1 Hz).
    private var needsFastCadence: Bool {
        let v = env.visibility
        if v.popoverOpen || (v.mainWindowVisible && v.inspectedSensor != nil) { return true }
        if v.mainWindowVisible, let page = v.visiblePage, Self.livePages.contains(page) { return true }
        let fans = env.fans
        if fans.isOverriding || fans.needsFastTicks { return true }   // FanStore: lease held, fan test, thermal guard
        switch fans.status {
        case .engaging, .active, .safetyOverride: return true
        default: break
        }
        return fans.mode != .system && fans.canControl
    }
    private static let livePages: Set<Route.Page> = [.overview, .sensors, .fans, .battery, .system]

    // MARK: Loop

    private func runLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.step()
            }
        }
    }

    private func step() async {
        if isPaused {
            await sleep(until: clock.now.advanced(by: .seconds(3600)), tolerance: .seconds(60))   // resume() wakes it
            return
        }
        let iv = interval
        let now = clock.now
        var due = now
        if let slot = lastSlot, let end = lastTickEnd {
            // Fixed grid: a timer that fires late (tolerance) does not shift the following ticks.
            due = max(slot.advanced(by: iv), end.advanced(by: .milliseconds(100)))
            if tickRequested { due = min(due, max(now, end.advanced(by: Self.minimumSpacing))) }
        }
        if due <= now.advanced(by: .milliseconds(2)) {
            // Requested ticks, and ticks more than half an interval late (a stall, a resume), start a new grid:
            // the next tick then comes a full interval later, never in a burst to catch up.
            lastSlot = (tickRequested || lastSlot == nil || now > due.advanced(by: iv / 2)) ? now : due
            tickRequested = false
            await tick(interval: iv)
        } else {
            await sleep(until: due, tolerance: tickRequested ? .zero : iv / 10)
        }
    }

    private func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration) async {
        let clock = self.clock
        let t = Task { _ = try? await clock.sleep(until: deadline, tolerance: tolerance) }
        sleeper = t
        await t.value
        if sleeper == t { sleeper = nil }
    }

    private func wakeLoop() { sleeper?.cancel() }

    private func tick(interval iv: Duration) async {
        let gen = generation
        let nominal = iv.timeInterval
        let start = clock.now
        let (ids, allVisible) = sensorRequest()
        let request = SampleRequest(sensorIDs: ids, includeFans: env.fans.hasFans, includePower: true)
        let systemRequest = self.systemRequest(at: start)
        let sensorSampler = env.sensorSampler, systemSampler = env.systemSampler
        async let frameResult = sensorSampler.sample(request)
        async let systemResult = systemSampler.sample(systemRequest)
        let frame = await frameResult
        var system = await systemResult
        // IOReport is read only while the System page shows it: the first sample after a stretch without one averages
        // that whole stretch. Drop it; the next tick has a current one.
        if let soc = system.soc, soc.interval > 3 * nominal { system.soc = nil }
        let sampled = clock.now
        guard gen == generation, !Task.isCancelled else {
            log.debug("tick dropped: paused while sampling")
            return
        }
        markRead(systemRequest, at: start, frame: system)

        // dt is measured; after wake, or after a gap of 5 nominal intervals (a stall, a 60 s → 1 s cadence switch is
        // judged by the slower one), the tick is "first after wake" and carries the nominal dt (SPEC §2.3.4).
        let hadPrevious = lastTick != nil
        let measured = lastTick.map { $0.duration(to: start).timeInterval } ?? nominal
        let afterGap = hadPrevious && (wakePending || measured > SensorSmoothing.gapFactor * max(nominal, lastNominal ?? nominal))
        let dt = (!hadPrevious || afterGap) ? nominal : max(measured, 0.05)
        lastTick = start
        lastNominal = nominal
        sequence &+= 1
        env.sensors.nominalInterval = nominal
        let t = Tick(sequence: sequence, date: Date(), dt: dt, sensors: frame, system: system, isFirstAfterWake: afterGap)
        for c in consumers { c.consume(t) }
        let end = clock.now
        lastTickEnd = end
        wakePending = false
        armStaleWatchdog()
        scheduleSlowData(at: end)

        let sampleMs = start.duration(to: sampled).timeInterval * 1000
        let consumeMs = sampled.duration(to: end).timeInterval * 1000
        log.debug("""
            tick \(self.sequence, privacy: .public) dt=\(dt, format: .fixed(precision: 2), privacy: .public)s \
            interval=\(nominal, format: .fixed(precision: 0), privacy: .public)s keys=\(ids.count, privacy: .public) \
            all=\(allVisible, privacy: .public) valid=\(frame.values.count, privacy: .public) \
            gated=\(frame.gated.count, privacy: .public) sample=\(sampleMs, format: .fixed(precision: 1), privacy: .public)ms \
            consumers=\(consumeMs, format: .fixed(precision: 2), privacy: .public)ms\(afterGap ? " firstAfterWake" : "", privacy: .public)
            """)
        if sequence % Self.historyLogEvery == 0 {
            let history = env.history
            log.debug("history \(history.debugSummary(), privacy: .public)")
        }
    }

    // MARK: Requests

    /// Sensor ids for this tick + whether every listed sensor is read.
    private func sensorRequest() -> (ids: [SensorID], allVisible: Bool) {
        let settings = env.settings, vis = env.visibility
        var extra = Set<SensorID>()
        var all = vis.needsAllSensors
        func add(_ source: TemperatureSource) {
            switch source {
            case .sensor(let id): extra.insert(id)
            case .aggregate(let k): if k == .highestAll || k == .averageAll { all = true }   // defined over every visible sensor
            }
        }
        for metric in [settings.menuBar.primary, settings.menuBar.secondary] {
            if case .temperature(let source) = metric { add(source) }
        }
        // `.anySensor` rules see what is read: the hottest keys (die, memory, SSD, battery) are always in the headline
        // and safety sets, so they do not force the full list every tick.
        if settings.alertsEnabled {
            for rule in settings.alertRules where rule.enabled {
                switch rule.subject {
                case .sensor(let id): extra.insert(id)
                case .aggregate(let k): add(.aggregate(k))
                case .group(let g):
                    for s in env.sensors.sensors where !s.isHidden && s.sensor.displayGroup == g { extra.insert(s.id) }
                default: break
                }
            }
        }
        if env.fans.mode != .system || settings.fans.mode == .curve {
            add(settings.fans.curveAC.input)
            if let battery = settings.fans.curveBattery { add(battery.input) }
        }
        // FanStore's own per-sensor inputs while its engine runs (a fan test, or a lease that is still held).
        if env.fans.needsFastTicks { extra.formUnion(env.fans.requiredSensorIDs) }
        if settings.log.enabled, settings.log.include.contains(.sensors) {
            if settings.log.sensorIDs.isEmpty { all = true } else { extra.formUnion(settings.log.sensorIDs) }
        }
        if let inspected = vis.inspectedSensor { extra.insert(inspected) }
        return (env.sensors.requestedSensorIDs(includeAllVisible: all, extra: extra), all)
    }

    private func systemRequest(at now: ContinuousClock.Instant) -> SystemSampleRequest {
        let vis = env.visibility
        let visible = vis.isAnyUIVisible
        let log = env.settings.log
        // The CSV log keeps its per-tick usage and IOReport power columns while UI is visible, as before.
        let logged = { (g: LogColumnGroup) in visible && log.enabled && log.include.contains(g) }
        var r = SystemSampleRequest()
        r.cpuLoad = vis.showsSystemPage || logged(.usage) || isDue(.cpu, every: 5, now)
        r.gpuUsage = r.cpuLoad
        r.memory = isDue(.memory, every: visible ? 2 : 10, now)
        r.soc = vis.needsSoCMetrics || logged(.power)
        r.battery = batteryMissing ? isDue(.battery, every: 60, now) : (vis.needsBatteryDetail || isDue(.battery, every: 5, now))
        r.powerSources = powerSourcesDirty || isDue(.powerSources, every: 30, now)
        return r
    }

    /// 0.25 s of slack so a 2 s reader on 1 s ticks runs every second tick despite timer tolerance.
    private func isDue(_ reader: Reader, every seconds: TimeInterval, _ now: ContinuousClock.Instant) -> Bool {
        guard let last = lastRead[reader] else { return true }
        return last.duration(to: now).timeInterval >= seconds - 0.25
    }

    private func markRead(_ r: SystemSampleRequest, at t: ContinuousClock.Instant, frame: SystemFrame) {
        if r.cpuLoad { lastRead[.cpu] = t }
        if r.memory { lastRead[.memory] = t }
        if r.battery {
            lastRead[.battery] = t
            if batteryMissing != (frame.battery == nil) { batteryMissing = frame.battery == nil }
        }
        if r.powerSources { lastRead[.powerSources] = t; powerSourcesDirty = false }
    }

    // MARK: Slow data (system_profiler, SMART, boot history): never awaited by a tick

    private func scheduleSlowData(at now: ContinuousClock.Instant) {
        var due: SlowDataRequest = []
        // system_profiler SPPowerDataType: every 6 h, laptops only once the battery reader has answered.
        if !batteryMissing, lastAppleBatteryHealth.map({ $0.duration(to: now) >= .seconds(6 * 3600) }) ?? true {
            due.insert(.appleBatteryHealth)
        }
        if env.settings.driveTemperatures, lastNVMe.map({ $0.duration(to: now) >= .seconds(60) }) ?? true {
            due.insert(.nvme)
        }
        refreshSlowData(due)
    }

    private func refreshSlowData(_ request: SlowDataRequest) {
        let req = request.subtracting(slowInFlight)
        guard !req.isEmpty else { return }
        slowInFlight.formUnion(req)
        let now = clock.now
        if req.contains(.appleBatteryHealth) { lastAppleBatteryHealth = now }
        if req.contains(.nvme) { lastNVMe = now }
        let sampler = env.systemSampler
        Task { @MainActor [weak self] in
            let data = await sampler.slowData(req)
            guard let self else { return }
            self.slowInFlight.subtract(req)
            self.env.system.apply(slow: data)
        }
    }

    // MARK: Discovery, staleness, cadence observation

    private func discoverSensors() async {
        do {
            let inventory = try await env.sensorSampler.start()
            env.sensors.load(inventory: inventory)
            env.fans.load(profile: inventory.fanProfile, names: inventory.fanNames)
            log.info("""
                inventory: \(inventory.sensors.count, privacy: .public) sensors, \
                \(inventory.fanProfile.fans.count, privacy: .public) fans, smc=\(inventory.smcAvailable, privacy: .public) \
                keys=\(inventory.smcKeyCount, privacy: .public) platform=\(inventory.identity.platformName, privacy: .public)
                """)
        } catch {
            env.sensors.loadFailed(error)
            env.events.record(.error("sensors unavailable: \(error)"))
            log.error("sensor discovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// No frame for > 3 nominal intervals (a hung reader, a stuck loop) → SensorStore shows stale readings. The limit
    /// is re-read after every sleep, so a cadence change (popover closed: 1 s → 60 s) never fires it early.
    /// Fan control needs nothing from here: without ticks FanStore stops calling `apply`, so FanControlCoordinator
    /// stops renewing the helper's lease and the helper hands the fans back to macOS (I3) instead of holding them.
    private func armStaleWatchdog() {
        staleWatchdog?.cancel()
        let clock = self.clock
        staleWatchdog = Task { @MainActor [weak self] in
            var limit: TimeInterval = 0
            while true {
                guard let self, let end = self.lastTickEnd else { return }
                limit = SensorSmoothing.staleFactor * self.nominalSeconds + 0.5
                let deadline = end.advanced(by: .seconds(limit))
                if clock.now >= deadline { break }
                do { try await clock.sleep(until: deadline, tolerance: .milliseconds(500)) } catch { return }
            }
            guard let self, !self.isPaused else { return }
            self.env.sensors.markStale()
            self.log.notice("no sensor frame for \(limit, format: .fixed(precision: 1), privacy: .public) s: readings marked stale")
        }
    }

    private func observeCadenceInputs() {
        observeContinuously({ [weak self] in
            guard let self else { return }
            // Every input of needsFastCadence / sensorRequest, read explicitly (the computed properties short-circuit).
            let v = self.env.visibility, fans = self.env.fans
            _ = v.popoverOpen; _ = v.mainWindowVisible; _ = v.visiblePage; _ = v.inspectedSensor
            _ = fans.isOverriding; _ = fans.status; _ = fans.mode; _ = fans.canControl; _ = fans.needsFastTicks
            _ = self.env.settings.updateInterval; _ = self.env.settings.showHiddenSensors
        }) { [weak self] in
            guard let self else { return false }
            self.cadenceInputsChanged()
            return true
        }
    }

    private func cadenceInputsChanged() {
        let fast = needsFastCadence
        let needsAll = env.visibility.needsAllSensors
        let needsSoC = env.visibility.needsSoCMetrics
        let inspected = env.visibility.inspectedSensor
        let showHidden = env.settings.showHiddenSensors
        let seconds = nominalSeconds
        // Something new is on screen (popover opened, a page switched, a sensor inspected, hidden sensors listed, the
        // System page's IOReport baseline): read it right away. A newly inspected sensor that is already read with
        // every listed one (arrowing through the Sensors table) waits for the regular tick.
        let inspectedHasReading = needsAll && inspected.flatMap { env.sensors.sensor($0)?.value } != nil
        if (needsAll && !lastNeedsAll) || (fast && !lastFast) || (needsSoC && !lastNeedsSoC)
            || (inspected != nil && inspected != lastInspected && !inspectedHasReading)
            || (needsAll && showHidden && !lastShowHidden) {
            tickRequested = true
        }
        if fast != lastFast || needsAll != lastNeedsAll {
            log.info("""
                cadence: interval \(seconds, format: .fixed(precision: 0), privacy: .public) s, \
                all sensors \(needsAll, privacy: .public), fast \(fast, privacy: .public)
                """)
        }
        let intervalChanged = seconds != lastIntervalSeconds
        lastFast = fast; lastNeedsAll = needsAll; lastNeedsSoC = needsSoC; lastInspected = inspected; lastShowHidden = showHidden
        lastIntervalSeconds = seconds
        // A store that re-assigns an unchanged value (e.g. a status every tick) must not wake the loop each time.
        if !isPaused, tickRequested || intervalChanged { wakeLoop() }
    }
}
