// SamplingCoordinator.swift — Thermik (MIT). Basic loop by Unit 0; OWNER: Unit 5 (adaptive cadence §2.3.4,
// per-reader cadences, sleep/wake pause, request building from every consumer's needs). Surface FROZEN.
import Foundation
import ThermikCore

@MainActor final class SamplingCoordinator {
    private let env: AppEnvironment
    private let consumers: [TickConsumer]
    private var task: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var lastTick: ContinuousClock.Instant?
    private(set) var isPaused = false

    init(env: AppEnvironment, consumers: [TickConsumer]) { self.env = env; self.consumers = consumers }

    /// Discovery (sensors + machine + slow data), then the loop.
    func start() async {
        if let inv = try? await env.sensorSampler.start() {
            env.sensors.load(inventory: inv)
            env.fans.load(profile: inv.fanProfile, names: inv.fanNames)
        }
        env.system.setMachine(await env.systemSampler.start())
        env.system.apply(slow: await env.systemSampler.slowData(.all))
        runLoop()
    }

    func stop() { task?.cancel(); task = nil }
    func pause() { isPaused = true }
    func resume(afterWake: Bool) { isPaused = false }

    /// Extra tick ASAP (coalesced: at most one pending). Wired to AppRouter.requestTick by AppDelegate.
    func requestTickSoon() {
        guard !isPaused, !extraTickPending else { return }
        extraTickPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tick(clock: ContinuousClock())
            self.extraTickPending = false
        }
    }
    private var extraTickPending = false

    /// Current tick interval (Unit 5: 1 s while visible or controlling, else settings.updateInterval).
    var interval: Duration { .seconds(env.settings.updateInterval) }

    private func runLoop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let iv = self.interval
                next = next.advanced(by: iv)
                if next < clock.now { next = clock.now.advanced(by: iv) }      // never burst to catch up
                if !self.isPaused { await self.tick(clock: clock) }
                try? await clock.sleep(until: next, tolerance: iv / 10)
            }
        }
    }

    private func tick(clock: ContinuousClock) async {
        let ids = env.sensors.requestedSensorIDs(includeAllVisible: true, extra: [])
        let frame = await env.sensorSampler.sample(SampleRequest(sensorIDs: ids))
        let sys = await env.systemSampler.sample(SystemSampleRequest(cpuLoad: true, gpuUsage: true, battery: true, powerSources: true))
        let now = clock.now
        let dt = lastTick.map { Double(($0.duration(to: now)).components.seconds) } ?? env.settings.updateInterval
        lastTick = now
        sequence &+= 1
        let t = Tick(sequence: sequence, date: Date(), dt: max(dt, 0.1), sensors: frame, system: sys, isFirstAfterWake: false)
        for c in consumers { c.consume(t) }
    }
}
