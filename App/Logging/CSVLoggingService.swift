// CSVLoggingService.swift — Thermik (MIT). OWNER: Unit 6. Surface FROZEN; additions marked. SPEC §2.12.
//
// Tick consumer that turns the stores into CSV rows for the `CSVLogWriter` actor. Rows are due every
// `settings.log.intervalSeconds` (0 = every tick); a tick that carries events writes an extra row at once so the
// event keeps its exact time. All writer calls go through ONE AsyncStream drained by one task, so they reach the
// actor in order (separate `Task {}`s would not guarantee that). The service watches `settings.log` itself (no
// explicit `reconfigure()` needed) and flushes on sleep and, bounded to 1 s, on quit.
import AppKit
import Foundation
import os
import ThermikCore

@MainActor final class CSVLoggingService: TickConsumer {
    let settings: SettingsStore
    let sensors: SensorStore
    let fans: FanStore
    let system: SystemStore
    let events: EventLogStore

    /// ADDED (Unit 6): the file being written (nil until the first row), and the writer's last I/O problem.
    private(set) var currentFileURL: URL?
    private(set) var lastError: String?

    private enum Ack: Sendable {
        case none
        case semaphore(DispatchSemaphore)
        func signal() {
            switch self {
            case .none: break
            case .semaphore(let s): s.signal()
            }
        }
    }

    private enum Command: Sendable {
        case configure(LogConfig, CSVLogHeader)
        case append(CSVLogRow)
        case flush
        case close(Ack)
    }

    /// Everything the column layout depends on; a change re-configures the writer (a new file if the columns differ).
    private struct LayoutKey: Equatable {
        var config: LogConfig
        var fanIndices: [Int]
        var sensorIDs: [SensorID]
        var model: String
        var chip: String
        var os: String
    }

    private var commands: AsyncStream<Command>.Continuation?
    private var writerActive = false
    private var layoutKey: LayoutKey?
    private var columns: [CSVColumn] = []
    private var nextRowDate: Date?
    private var pendingEvents: [String] = []
    private var lastTick: Tick?
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "logging")
    static let maxPendingEvents = 64

    init(settings: SettingsStore, sensors: SensorStore, fans: FanStore, system: SystemStore, events: EventLogStore) {
        self.settings = settings; self.sensors = sensors; self.fans = fans; self.system = system; self.events = events
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // As a main-actor job (after this notification's other observers ran), so the "sleep" event is queued too.
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeBlocking(timeout: 1) }
        })
    }

    /// ADDED (Unit 6): sensor columns the log needs read every tick (SamplingCoordinator's `extra`).
    var requiredSensorIDs: Set<SensorID> {
        let config = settings.log
        guard config.enabled, config.include.contains(.sensors) else { return [] }
        return Set(chosenSensorIDs(config))
    }

    // MARK: Tick

    func consume(_ tick: Tick) {
        lastTick = tick
        let tokens = events.drainCSVTokens()                     // always drain: the store's queue never grows
        let config = settings.log
        guard config.enabled else {
            if writerActive { reconfigure() }
            pendingEvents.removeAll()
            return
        }
        if config.include.contains(.events) {
            pendingEvents += tokens
            if pendingEvents.count > Self.maxPendingEvents { pendingEvents.removeFirst(pendingEvents.count - Self.maxPendingEvents) }
        }
        // Wait for discovery: the header comment names the machine and the columns need the inventory.
        guard sensors.isLoaded, let machine = system.machine else { return }
        updateLayout(config, machine: machine)

        let interval = max(config.intervalSeconds, 0)
        let tolerance = min(max(tick.dt, 0.1), max(interval, 0.1)) * 0.25     // ticks may arrive a little early
        let due = interval == 0 || nextRowDate.map { tick.date >= $0.addingTimeInterval(-tolerance) } ?? true
        guard due || !pendingEvents.isEmpty else { return }
        send(.append(makeRow(tick)))
        pendingEvents.removeAll()
        if due {
            let next = (nextRowDate ?? tick.date).addingTimeInterval(interval)
            nextRowDate = next < tick.date ? tick.date.addingTimeInterval(interval) : next   // never burst to catch up
        }
    }

    /// Sampling pauses while asleep: write the pending events (the "sleep" token) now, with the latest values and the
    /// real time, then flush to disk.
    private func systemWillSleep() {
        guard writerActive, settings.log.enabled else { return }
        if settings.log.include.contains(.events) { pendingEvents += events.drainCSVTokens() }
        if !pendingEvents.isEmpty, let tick = lastTick {
            send(.append(makeRow(tick, date: Date())))
            pendingEvents.removeAll()
        }
        send(.flush)
    }

    /// Re-read settings.log (enable/disable, folder, columns) — call after the Logging settings change.
    func reconfigure() {
        let config = settings.log
        layoutKey = nil
        nextRowDate = nil
        if !config.enabled {
            guard writerActive else { return }
            // An empty header is fine: a disabled writer closes and is dropped.
            send(.configure(config, CSVLogLayout.header(config: config, columns: [], hasFans: false, modelIdentifier: "",
                                                        chip: "", osVersion: "", appVersion: "")))
            writerActive = false
            log.info("CSV logging disabled")
        } else if sensors.isLoaded, let machine = system.machine {
            updateLayout(config, machine: machine)
        }
    }

    func revealInFinder() {
        if let url = currentFileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let folder = URL(fileURLWithPath: (settings.log.folderPath as NSString).expandingTildeInPath, isDirectory: true)
        // An explicit user action: creating the chosen (empty) log folder so Finder can show it is fine.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Layout and rows

    private func updateLayout(_ config: LogConfig, machine: MachineInfo) {
        let fanIndices = fans.fans.map(\.id).sorted()
        let chosen = config.include.contains(.sensors) ? chosenSensorIDs(config) : []
        let key = LayoutKey(config: config, fanIndices: fanIndices, sensorIDs: chosen, model: machine.modelIdentifier,
                            chip: machine.chip, os: machine.osVersion)
        guard key != layoutKey else { return }                    // the common case: one cheap comparison per tick
        let intervalChanged = layoutKey?.config.intervalSeconds != config.intervalSeconds
        layoutKey = key
        if intervalChanged { nextRowDate = nil }
        let sensorColumns = chosen.compactMap { sensors.sensor($0).map { CSVLogLayout.sensorColumn($0.sensor) } }
        columns = CSVLogLayout.columns(include: config.include, fanIndices: fanIndices, sensors: sensorColumns)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = CSVLogLayout.header(config: config, columns: columns, hasFans: !fanIndices.isEmpty,
                                         modelIdentifier: machine.modelIdentifier, chip: machine.chip, osVersion: machine.osVersion,
                                         appVersion: version)
        send(.configure(config, header))
        if !writerActive { log.info("CSV logging enabled (\(self.columns.count, privacy: .public) columns)") }
        writerActive = true
    }

    /// LogConfig.sensorIDs in their order (unknown ids dropped), or every visible sensor when the list is empty.
    private func chosenSensorIDs(_ config: LogConfig) -> [SensorID] {
        if config.sensorIDs.isEmpty { return sensors.sensors.filter { !$0.isHidden }.map(\.id) }
        return config.sensorIDs.filter { sensors.sensor($0) != nil }
    }

    private func makeRow(_ tick: Tick, date: Date? = nil) -> CSVLogRow {
        var fanValues: [Int: CSVLogSample.Fan] = [:]
        for f in fans.fans { fanValues[f.id] = CSVLogSample.Fan(actualRPM: f.actualRPM, targetRPM: f.targetRPM) }
        // Sensor columns: the smoothed value when the sensor was read this tick, else an empty cell (never a stale value).
        var sensorValues: [SensorID: Double] = [:]
        for c in columns where c.id.contains(":") {
            guard let id = SensorID(c.id), let raw = tick.sensors.values[id] else { continue }
            sensorValues[id] = sensors.sensor(id)?.value ?? raw
        }
        let soc = tick.system?.soc?.power                       // only while IOReport is sampled (UI visible)
        let sample = CSVLogSample(
            aggregates: sensors.aggregates, fans: fanValues, power: sensors.power, cpuW: soc?.cpuW, gpuW: soc?.gpuW,
            cpuUsagePercent: system.cpuTotalPercent, gpuUsagePercent: system.gpu?.devicePercent.map(Double.init),
            memoryUsedGB: system.memory.map { Double($0.used) / 1_073_741_824 }, pressure: system.pressure,
            batteryPercent: system.battery?.chargePercent,
            onAC: system.battery.map(\.externalConnected) ?? system.powerSource.map { $0.kind == .ac },
            sensors: sensorValues)
        let config = settings.fans
        let curve = system.powerSourceKind == .battery ? (config.curveBattery ?? config.curveAC) : config.curveAC
        let mode = fans.hasFans ? CSVLogLayout.fanModeToken(fans.mode, curve: curve, fixedPercent: config.fixedPercent) : nil
        return CSVLogRow(date: date ?? tick.date, numbers: CSVLogLayout.numbers(for: columns, sample: sample), fanMode: mode,
                         events: pendingEvents)
    }

    // MARK: Writer pump

    private func send(_ command: Command) {
        if commands == nil { startPump() }
        commands?.yield(command)
    }

    private func startPump() {
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        let report: @Sendable (URL?, String?) -> Void = { [weak self] url, error in
            Task { @MainActor in self?.writerReported(url: url, error: error) }
        }
        Task.detached(priority: .utility) {
            var writer: CSVLogWriter?
            var reported: (URL?, String?) = (nil, nil)
            for await command in stream {
                switch command {
                case .configure(let config, let header):
                    if let w = writer {
                        await w.update(config: config, header: header)
                        if !config.enabled { writer = nil }
                    } else if config.enabled {
                        writer = CSVLogWriter(config: config, header: header)
                    }
                case .append(let row): await writer?.append(row)
                case .flush: await writer?.flush()
                case .close(let ack):
                    await writer?.close()
                    ack.signal()
                }
                if let w = writer {
                    let now = (await w.currentFileURL, await w.lastError)
                    if now.0 != reported.0 || now.1 != reported.1 { reported = now; report(now.0, now.1) }
                }
            }
        }
    }

    private func writerReported(url: URL?, error: String?) {
        if url != currentFileURL { currentFileURL = url }
        if error != lastError {
            lastError = error
            if let error {
                log.error("CSV logging: \(error, privacy: .public)")
                events.record(.error("CSV log: \(error)"))          // visible on the Logs page (once per new error)
            }
        }
    }

    /// applicationShouldTerminate / applicationWillTerminate: flush and close, waiting at most `timeout` (the writer
    /// actor never needs main).
    func closeBlocking(timeout: TimeInterval) {
        guard writerActive, let commands else { return }
        let done = DispatchSemaphore(value: 0)
        commands.yield(.close(.semaphore(done)))
        if done.wait(timeout: .now() + timeout) == .timedOut { log.error("CSV logging: close timed out at quit") }
    }
}
