// SamplingCoordinator.swift — Thermik (MIT). Adaptive cadence, per-reader schedules,
// sleep/wake pause, and request building from every consumer's needs.
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
        await loadBootHistory()
        refreshSlowData(env.settings.driveTemperatures ? [.appleBatteryHealth, .nvme] : [.appleBatteryHealth])
        snapshotCadenceInputs()
        observeCadenceInputs()
        runLoop()
    }

    /// Boot history comes before the first tick: the abnormal-shutdown alert is evaluated once, on the first tick.
    /// A slow reader (Intel `log show`) gets 3 s; its result is applied whenever it arrives.
    private func loadBootHistory() async {
        let systemSampler = env.systemSampler
        let system = env.system
        slowInFlight.insert(.boot)
        let bootReady = await waitAtMost(.seconds(3)) { [weak self] in
            let data = await systemSampler.slowData(.boot)
            system.apply(slow: data)
            self?.slowInFlight.remove(.boot)
        }
        if !bootReady { log.notice("boot history still loading after 3 s; starting the loop") }
    }

    private func snapshotCadenceInputs() {
        lastFast = needsFastCadence
        lastNeedsAll = env.visibility.needsAllSensors
        lastNeedsSoC = env.visibility.needsSoCMetrics
        lastInspected = env.visibility.inspectedSensor
        lastShowHidden = env.settings.showHiddenSensors
        lastIntervalSeconds = nominalSeconds
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
        if afterWake { prepareAfterWake() }
        log.info("sampling resumed\(afterWake ? " after wake" : "", privacy: .public)")
        tickRequested = true
        wakeLoop()
    }

    private func prepareAfterWake() {
        wakePending = true                 // next tick: isFirstAfterWake (filters restart)
        lastRead.removeAll()               // every reader runs on the first tick after wake
        powerSourcesDirty = true
        refreshSlowData(.boot)
        if !env.sensors.isLoaded { rediscoverSensorsAfterWake() }
    }

    /// Discovery can fail at launch when SMC is not ready; wake is the next opportunity to retry it.
    private func rediscoverSensorsAfterWake() {
        Task { @MainActor [weak self] in
            await self?.discoverSensors()
            self?.requestTickSoon()
        }
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

    private struct TickRequests {
        let ids: [SensorID]
        let allVisible: Bool
        let sensor: SampleRequest
        let system: SystemSampleRequest
    }

    private struct TickSample {
        let requests: TickRequests
        let frame: SensorFrame
        let system: SystemFrame
        let sampled: ContinuousClock.Instant
    }

    private struct TickTiming {
        let dt: TimeInterval
        let afterGap: Bool
    }

    private func step() async {
        if isPaused { await sleepPaused(); return }
        let iv = interval
        let now = clock.now
        let due = nextDeadline(at: now, interval: iv)
        guard due <= now.advanced(by: .milliseconds(2)) else {
            await sleep(until: due, tolerance: tickRequested ? .zero : iv / 10)
            return
        }
        prepareTick(at: now, due: due, interval: iv)
        await tick(interval: iv)
    }

    private func sleepPaused() async {
        await sleep(until: clock.now.advanced(by: .seconds(3600)), tolerance: .seconds(60))   // resume() wakes it
    }

    private func nextDeadline(at now: ContinuousClock.Instant, interval iv: Duration) -> ContinuousClock.Instant {
        guard let slot = lastSlot, let end = lastTickEnd else { return now }
        // Fixed grid: a timer that fires late (tolerance) does not shift the following ticks.
        var due = max(slot.advanced(by: iv), end.advanced(by: .milliseconds(100)))
        if tickRequested { due = min(due, max(now, end.advanced(by: Self.minimumSpacing))) }
        return due
    }

    private func prepareTick(at now: ContinuousClock.Instant, due: ContinuousClock.Instant, interval iv: Duration) {
        // Requested ticks, and ticks more than half an interval late (a stall, a resume), start a new grid:
        // the next tick then comes a full interval later, never in a burst to catch up.
        lastSlot = (tickRequested || lastSlot == nil || now > due.advanced(by: iv / 2)) ? now : due
        tickRequested = false
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
        let sampledTick = await sample(at: start, nominal: nominal)
        guard gen == generation, !Task.isCancelled else {
            log.debug("tick dropped: paused while sampling")
            return
        }
        deliver(sampledTick, at: start, nominal: nominal)
    }

    private func sample(at start: ContinuousClock.Instant, nominal: TimeInterval) async -> TickSample {
        let requests = makeRequests(at: start)
        let sensorSampler = env.sensorSampler, systemSampler = env.systemSampler
        async let frameResult = sensorSampler.sample(requests.sensor)
        async let systemResult = systemSampler.sample(requests.system)
        let frame = await frameResult
        var system = await systemResult
        discardStaleSoC(in: &system, nominal: nominal)
        let sampled = clock.now
        return TickSample(requests: requests, frame: frame, system: system, sampled: sampled)
    }

    private func makeRequests(at start: ContinuousClock.Instant) -> TickRequests {
        let (ids, allVisible) = sensorRequest()
        let request = SampleRequest(sensorIDs: ids, components: env.fans.hasFans ? [.fans, .power] : [.power])
        let systemRequest = self.systemRequest(at: start)
        return TickRequests(ids: ids, allVisible: allVisible, sensor: request, system: systemRequest)
    }

    /// IOReport averages the whole stretch since its last read; drop that sample after a stretch without the System page.
    private func discardStaleSoC(in system: inout SystemFrame, nominal: TimeInterval) {
        if let soc = system.soc, soc.interval > 3 * nominal { system.soc = nil }
    }

    private func deliver(_ sample: TickSample, at start: ContinuousClock.Instant, nominal: TimeInterval) {
        markRead(sample.requests.system, at: start, frame: sample.system)
        let timing = tickTiming(at: start, nominal: nominal)
        let end = publish(sample, timing: timing, at: start, nominal: nominal)
        logTick(sample, timing: timing, start: start, end: end, nominal: nominal)
        logHistoryIfNeeded()
    }

    /// After wake or a long gap, carry nominal dt and restart filtering; otherwise use measured dt (SPEC §2.3.4).
    private func tickTiming(at start: ContinuousClock.Instant, nominal: TimeInterval) -> TickTiming {
        let hadPrevious = lastTick != nil
        let measured = lastTick.map { $0.duration(to: start).timeInterval } ?? nominal
        let afterGap = hadPrevious && (wakePending || measured > SensorSmoothing.gapFactor * max(nominal, lastNominal ?? nominal))
        let dt = (!hadPrevious || afterGap) ? nominal : max(measured, 0.05)
        return TickTiming(dt: dt, afterGap: afterGap)
    }

    private func publish(_ sample: TickSample, timing: TickTiming,
                         at start: ContinuousClock.Instant, nominal: TimeInterval) -> ContinuousClock.Instant {
        lastTick = start
        lastNominal = nominal
        sequence &+= 1
        env.sensors.nominalInterval = nominal
        let tick = Tick(sequence: sequence, date: Date(), dt: timing.dt, sensors: sample.frame, system: sample.system,
                        isFirstAfterWake: timing.afterGap)
        for consumer in consumers { consumer.consume(tick) }
        return finishTick()
    }

    private func finishTick() -> ContinuousClock.Instant {
        let end = clock.now
        lastTickEnd = end
        wakePending = false
        armStaleWatchdog()
        scheduleSlowData(at: end)
        return end
    }

    private func logTick(_ sample: TickSample, timing: TickTiming, start: ContinuousClock.Instant,
                         end: ContinuousClock.Instant, nominal: TimeInterval) {
        let sampleMs = start.duration(to: sample.sampled).timeInterval * 1000
        let consumeMs = sample.sampled.duration(to: end).timeInterval * 1000
        log.debug("""
            tick \(self.sequence, privacy: .public) dt=\(timing.dt, format: .fixed(precision: 2), privacy: .public)s \
            interval=\(nominal, format: .fixed(precision: 0), privacy: .public)s keys=\(sample.requests.ids.count, privacy: .public) \
            all=\(sample.requests.allVisible, privacy: .public) valid=\(sample.frame.values.count, privacy: .public) \
            gated=\(sample.frame.gated.count, privacy: .public) sample=\(sampleMs, format: .fixed(precision: 1), privacy: .public)ms \
            consumers=\(consumeMs, format: .fixed(precision: 2), privacy: .public)ms\(timing.afterGap ? " firstAfterWake" : "", privacy: .public)
            """)
    }

    private func logHistoryIfNeeded() {
        guard sequence % Self.historyLogEvery == 0 else { return }
        let history = env.history
        log.debug("history \(history.debugSummary(), privacy: .public)")
    }

    // MARK: Requests

    private struct SensorRequestBuilder {
        var extra: Set<SensorID> = []
        var allVisible: Bool

        mutating func add(_ source: TemperatureSource) {
            switch source {
            case .sensor(let id): extra.insert(id)
            case .aggregate(let kind): add(kind)
            }
        }

        mutating func add(_ kind: AggregateKind) {
            if kind == .highestAll || kind == .averageAll { allVisible = true }   // defined over every visible sensor
        }
    }

    /// Sensor ids for this tick + whether every listed sensor is read.
    private func sensorRequest() -> (ids: [SensorID], allVisible: Bool) {
        var request = SensorRequestBuilder(allVisible: env.visibility.needsAllSensors)
        addMenuBarSources(to: &request)
        addAlertSources(to: &request)
        addFanSources(to: &request)
        addLoggingSources(to: &request)
        if let inspected = env.visibility.inspectedSensor { request.extra.insert(inspected) }
        return (env.sensors.requestedSensorIDs(includeAllVisible: request.allVisible, extra: request.extra), request.allVisible)
    }

    private func addMenuBarSources(to request: inout SensorRequestBuilder) {
        let metrics = [env.settings.menuBar.primary, env.settings.menuBar.secondary]
        for metric in metrics {
            if case .temperature(let source) = metric { request.add(source) }
        }
    }

    private func addAlertSources(to request: inout SensorRequestBuilder) {
        // `.anySensor` rules see what is read: the hottest keys (die, memory, SSD, battery) are always in the headline
        // and safety sets, so they do not force the full list every tick.
        guard env.settings.alertsEnabled else { return }
        for rule in env.settings.alertRules where rule.enabled {
            addAlertSubject(rule.subject, to: &request)
        }
    }

    private func addAlertSubject(_ subject: AlertRule.Subject, to request: inout SensorRequestBuilder) {
        switch subject {
        case .sensor(let id): request.extra.insert(id)
        case .aggregate(let kind): request.add(kind)
        case .group(let group): addAlertGroup(group, to: &request)
        default: break
        }
    }

    private func addAlertGroup(_ group: DisplayGroup, to request: inout SensorRequestBuilder) {
        for sensor in env.sensors.sensors where !sensor.isHidden && sensor.sensor.displayGroup == group {
            request.extra.insert(sensor.id)
        }
    }

    private func addFanSources(to request: inout SensorRequestBuilder) {
        let settings = env.settings
        if env.fans.mode != .system || settings.fans.mode == .curve {
            request.add(settings.fans.curveAC.input)
            if let battery = settings.fans.curveBattery { request.add(battery.input) }
        }
        // FanStore's own per-sensor inputs while its engine runs (a fan test, or a lease that is still held).
        if env.fans.needsFastTicks { request.extra.formUnion(env.fans.requiredSensorIDs) }
    }

    private func addLoggingSources(to request: inout SensorRequestBuilder) {
        let log = env.settings.log
        guard log.enabled, log.include.contains(.sensors) else { return }
        if log.sensorIDs.isEmpty {
            request.allVisible = true
        } else {
            request.extra.formUnion(log.sensorIDs)
        }
    }

    private func systemRequest(at now: ContinuousClock.Instant) -> SystemSampleRequest {
        var request: SystemSampleRequest = []
        if needsCPUReaders(at: now) { request.formUnion([.cpuLoad, .gpuUsage]) }
        if needsMemoryReader(at: now) { request.insert(.memory) }
        if needsSoCReader() { request.insert(.soc) }
        if needsBatteryReader(at: now) { request.insert(.battery) }
        if needsPowerSources(at: now) { request.insert(.powerSources) }
        return request
    }

    private func needsCPUReaders(at now: ContinuousClock.Instant) -> Bool {
        env.visibility.showsSystemPage || isLogging(.usage) || isDue(.cpu, every: 5, now)
    }

    private func needsMemoryReader(at now: ContinuousClock.Instant) -> Bool {
        isDue(.memory, every: env.visibility.isAnyUIVisible ? 2 : 10, now)
    }

    private func needsSoCReader() -> Bool {
        env.visibility.needsSoCMetrics || isLogging(.power)
    }

    private func needsBatteryReader(at now: ContinuousClock.Instant) -> Bool {
        batteryMissing ? isDue(.battery, every: 60, now) : (env.visibility.needsBatteryDetail || isDue(.battery, every: 5, now))
    }

    private func needsPowerSources(at now: ContinuousClock.Instant) -> Bool {
        powerSourcesDirty || isDue(.powerSources, every: 30, now)
    }

    /// The CSV log keeps per-tick usage and IOReport power columns while UI is visible.
    private func isLogging(_ group: LogColumnGroup) -> Bool {
        let log = env.settings.log
        return env.visibility.isAnyUIVisible && log.enabled && log.include.contains(group)
    }

    /// 0.25 s of slack so a 2 s reader on 1 s ticks runs every second tick despite timer tolerance.
    private func isDue(_ reader: Reader, every seconds: TimeInterval, _ now: ContinuousClock.Instant) -> Bool {
        guard let last = lastRead[reader] else { return true }
        return last.duration(to: now).timeInterval >= seconds - 0.25
    }

    private func markRead(_ r: SystemSampleRequest, at t: ContinuousClock.Instant, frame: SystemFrame) {
        if r.contains(.cpuLoad) { lastRead[.cpu] = t }
        if r.contains(.memory) { lastRead[.memory] = t }
        if r.contains(.battery) {
            lastRead[.battery] = t
            if batteryMissing != (frame.battery == nil) { batteryMissing = frame.battery == nil }
        }
        if r.contains(.powerSources) { lastRead[.powerSources] = t; powerSourcesDirty = false }
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
        markSlowDataRequested(req)
        let sampler = env.systemSampler
        Task { @MainActor [weak self] in
            let data = await sampler.slowData(req)
            self?.applySlowData(data, request: req)
        }
    }

    private func markSlowDataRequested(_ request: SlowDataRequest) {
        let now = clock.now
        if request.contains(.appleBatteryHealth) { lastAppleBatteryHealth = now }
        if request.contains(.nvme) { lastNVMe = now }
    }

    private func applySlowData(_ data: SlowSystemData, request: SlowDataRequest) {
        slowInFlight.subtract(request)
        env.system.apply(slow: data)
    }

    // MARK: Discovery, staleness, cadence observation

    private func discoverSensors() async {
        do {
            let inventory = try await env.sensorSampler.start()
            applyInventory(inventory)
        } catch {
            discoveryFailed(with: error)
        }
    }

    private func applyInventory(_ inventory: SensorInventory) {
        env.sensors.load(inventory: inventory)
        env.fans.load(profile: inventory.fanProfile, names: inventory.fanNames)
        log.info("""
            inventory: \(inventory.sensors.count, privacy: .public) sensors, \
            \(inventory.fanProfile.fans.count, privacy: .public) fans, smc=\(inventory.smcAvailable, privacy: .public) \
            keys=\(inventory.smcKeyCount, privacy: .public) platform=\(inventory.identity.platformName, privacy: .public)
            """)
    }

    private func discoveryFailed(with error: any Error) {
        env.sensors.loadFailed(error)
        env.events.record(.error("sensors unavailable: \(error)"))
        log.error("sensor discovery failed: \(String(describing: error), privacy: .public)")
    }

    /// No frame for > 3 nominal intervals (a hung reader, a stuck loop) → SensorStore shows stale readings. The limit
    /// is re-read after every sleep, so a cadence change (popover closed: 1 s → 60 s) never fires it early.
    /// Fan control needs nothing from here: without ticks FanStore stops calling `apply`, so FanControlCoordinator
    /// stops renewing the helper's lease and the helper hands the fans back to macOS (I3) instead of holding them.
    private func armStaleWatchdog() {
        staleWatchdog?.cancel()
        staleWatchdog = Task { @MainActor [weak self] in
            guard let limit = await self?.waitForStaleDeadline() else { return }
            guard let self, !self.isPaused else { return }
            self.env.sensors.markStale()
            self.log.notice("no sensor frame for \(limit, format: .fixed(precision: 1), privacy: .public) s: readings marked stale")
        }
    }

    private func waitForStaleDeadline() async -> TimeInterval? {
        var limit: TimeInterval = 0
        while true {
            guard let end = lastTickEnd else { return nil }
            limit = SensorSmoothing.staleFactor * nominalSeconds + 0.5
            let deadline = end.advanced(by: .seconds(limit))
            if clock.now >= deadline { break }
            do { try await clock.sleep(until: deadline, tolerance: .milliseconds(500)) } catch { return nil }
        }
        return limit
    }

    private struct CadenceInputs {
        let fast: Bool
        let needsAll: Bool
        let needsSoC: Bool
        let inspected: SensorID?
        let showHidden: Bool
        let seconds: TimeInterval
    }

    private func observeCadenceInputs() {
        observeContinuously({ [weak self] in
            self?.readCadenceInputs()
        }) { [weak self] in
            guard let self else { return false }
            self.cadenceInputsChanged()
            return true
        }
    }

    private func readCadenceInputs() {
        // Every input of needsFastCadence / sensorRequest, read explicitly (the computed properties short-circuit).
        let visibility = env.visibility, fans = env.fans
        _ = visibility.popoverOpen; _ = visibility.mainWindowVisible; _ = visibility.visiblePage; _ = visibility.inspectedSensor
        _ = fans.isOverriding; _ = fans.status; _ = fans.mode; _ = fans.canControl; _ = fans.needsFastTicks
        _ = env.settings.updateInterval; _ = env.settings.showHiddenSensors
    }

    private func currentCadenceInputs() -> CadenceInputs {
        let fast = needsFastCadence
        let needsAll = env.visibility.needsAllSensors
        let needsSoC = env.visibility.needsSoCMetrics
        let inspected = env.visibility.inspectedSensor
        let showHidden = env.settings.showHiddenSensors
        let seconds = nominalSeconds
        return CadenceInputs(fast: fast, needsAll: needsAll, needsSoC: needsSoC,
                             inspected: inspected, showHidden: showHidden, seconds: seconds)
    }

    private func cadenceInputsChanged() {
        let inputs = currentCadenceInputs()
        if shouldRequestTick(for: inputs) { tickRequested = true }
        logCadenceChange(inputs)
        let intervalChanged = inputs.seconds != lastIntervalSeconds
        rememberCadenceInputs(inputs)
        // A store that re-assigns an unchanged value (e.g. a status every tick) must not wake the loop each time.
        if !isPaused, tickRequested || intervalChanged { wakeLoop() }
    }

    /// Read newly visible data now, except when an inspected sensor already has a reading from the full visible list.
    private func shouldRequestTick(for inputs: CadenceInputs) -> Bool {
        let inspectedHasReading = inputs.needsAll && inputs.inspected.flatMap { env.sensors.sensor($0)?.value } != nil
        return (inputs.needsAll && !lastNeedsAll) || (inputs.fast && !lastFast) || (inputs.needsSoC && !lastNeedsSoC)
            || (inputs.inspected != nil && inputs.inspected != lastInspected && !inspectedHasReading)
            || (inputs.needsAll && inputs.showHidden && !lastShowHidden)
    }

    private func logCadenceChange(_ inputs: CadenceInputs) {
        guard inputs.fast != lastFast || inputs.needsAll != lastNeedsAll else { return }
        log.info("""
            cadence: interval \(inputs.seconds, format: .fixed(precision: 0), privacy: .public) s, \
            all sensors \(inputs.needsAll, privacy: .public), fast \(inputs.fast, privacy: .public)
            """)
    }

    private func rememberCadenceInputs(_ inputs: CadenceInputs) {
        lastFast = inputs.fast
        lastNeedsAll = inputs.needsAll
        lastNeedsSoC = inputs.needsSoC
        lastInspected = inputs.inspected
        lastShowHidden = inputs.showHidden
        lastIntervalSeconds = inputs.seconds
    }
}
