// SensorSampler.swift — Thermik (MIT). Public `SensorSampling` actor.
// + `init()`. Discovery and one read pass per tick, off the main actor (SPEC §2.3.1, §2.5.2, §2.5.3).
//
// The actor owns every non-Sendable piece: the SMC provider (one `SMCConnection`), the HID reader (one full
// IOHIDEventSystemClient), the resolved catalog lookups, the HID value cache and the post-wake window.
// Everything is READ-ONLY: this module links ThermikSMC, which has no SMC write command.
import Foundation
import os
import ThermikSMC

/// Why `start()` failed.
public enum SensorSamplerError: Error, Sendable, CustomStringConvertible {
    /// Neither the SMC nor the HID event system could be opened (the app shows "Sensors unavailable").
    case noSensorSource
    public var description: String { "Neither the SMC nor the HID temperature services are available" }
}

public actor SensorSampler: SensorSampling {
    /// HID services cost ≈ 1 ms each (SENS §3.4): read at most this often, reuse the values in between.
    public static let hidInterval: Duration = .seconds(5)
    /// After wake the P-cluster keys show the 40.0 "not sampled yet" placeholder (SENS §5.3).
    public static let postWakeWindow: Duration = .seconds(3)
    /// Groups forced invalid during the post-wake window, and the groups whose clusters can be power-gated.
    static let gatingGroups: Set<SensorGroup> = [.cpuPerformance, .cpuFabric, .cpuAggregate]

    private struct ClusterKey: Hashable { let group: SensorGroup; let cluster: Int }

    private let log = Logger(subsystem: "app.thermik.Thermik", category: "sensors")
    private var smc: SMCSensorProvider?
    private var hid: HIDSensorReader?
    private var inventory: SensorInventory?
    private var filter = SanityFilter(appleSilicon: HostInfo.isAppleSilicon)
    private var descriptors: [SensorID: SensorDescriptor] = [:]
    private var keyOf: [SensorID: FourCC] = [:]
    private var idOf: [FourCC: SensorID] = [:]
    private var clusterOf: [SensorID: ClusterKey] = [:]
    private var postWakeUntil: ContinuousClock.Instant?
    private var hidCache: [SensorID: Double] = [:]
    private var hidCached: Set<SensorID> = []
    private var hidReadAt: ContinuousClock.Instant?
    /// SMC link state as last logged: the connection reopens itself (with backoff), so only transitions are logged.
    private var smcLinkDown = false
    private var smcReopens = 0
    /// Wall time of the last `start()` (bench / diagnostics).
    package private(set) var startDuration: Duration?

    public init() {}

    // MARK: Discovery

    public func start() async throws -> SensorInventory {
        if let inventory { return inventory }
        let clock = ContinuousClock()
        let started = clock.now
        let discovered = try discoverInventory()
        inventory = discovered.inventory
        logStart(discovered.inventory, hardware: discovered.hardware, started: started, clock: clock)
        return discovered.inventory
    }

    private func discoverInventory() throws -> (inventory: SensorInventory, hardware: SensorCatalog.Hardware) {
        // 1–2. SMC (optional: HID-only mode when it cannot be opened) and identity.
        let provider = discoverSMC()
        let identity = ChipIdentity.read(smc: provider?.connection)
        filter = SanityFilter(appleSilicon: identity.isAppleSilicon)
        let discovered = try discoverCatalog(provider: provider, identity: identity)
        smc = provider
        indexSensors(discovered.catalog.sensors, provider: provider)
        let inv = makeInventory(identity: identity, catalog: discovered.catalog, provider: provider)
        return (inv, discovered.hardware)
    }

    private func discoverSMC() -> SMCSensorProvider? {
        do {
            let provider = try SMCSensorProvider()
            try provider.discover()
            return provider
        } catch {
            log.error("SMC unavailable: \(String(describing: error), privacy: .public); continuing with HID only")
            return nil
        }
    }

    private func discoverCatalog(provider: SMCSensorProvider?, identity: ChipIdentity) throws
        -> (catalog: SensorCatalog, hardware: SensorCatalog.Hardware) {
        let db = SensorCatalog.loadDatabase(platform: SensorCatalog.databaseName(for: identity))
        prepareHID(provider: provider, database: db)
        let hw = SensorCatalog.hardware(provider: provider, hidProducts: hid?.products ?? [], identity: identity, database: db)
        let catalog = SensorCatalog(database: db, hardware: hw)
        try requireSource(provider: provider, catalog: catalog)
        return (catalog, hw)
    }

    /// HID is opened only when something can come from it: DB `hid:` entries, an unknown chip, no SMC die keys, or no SMC.
    private func prepareHID(provider: SMCSensorProvider?, database: ChipSensorDatabase?) {
        let smcKeys = provider?.temperatureKeys.map { (key: $0.key.description, type: $0.info.type.description) } ?? []
        let needsHID = provider == nil || database == nil || !Heuristics.hasSMCDieKeys(smcKeys.map(\.key))
            || database?.sensors.contains { $0.key.hasPrefix("hid:") } == true
        if needsHID { hid = HIDSensorReader(kind: .temperature) }
    }

    private func requireSource(provider: SMCSensorProvider?, catalog: SensorCatalog) throws {
        guard provider != nil || catalog.sensors.contains(where: { $0.id.source == .hid }) else {
            log.error("no sensor source (SMC and HID unavailable)")
            throw SensorSamplerError.noSensorSource
        }
    }

    private func indexSensors(_ sensors: [Sensor], provider: SMCSensorProvider?) {
        let fourCC = Dictionary(provider?.temperatureKeys.map { ($0.key.description, $0.key) } ?? [], uniquingKeysWith: { a, _ in a })
        for sensor in sensors { index(sensor, fourCC: fourCC) }
    }

    private func index(_ sensor: Sensor, fourCC: [String: FourCC]) {
        descriptors[sensor.id] = sensor.descriptor
        if sensor.id.source == .smc, let key = fourCC[sensor.id.key] {
            keyOf[sensor.id] = key
            idOf[key] = sensor.id
        }
        guard Self.gatingGroups.contains(sensor.group), let cluster = sensor.descriptor.cluster else { return }
        clusterOf[sensor.id] = ClusterKey(group: sensor.group, cluster: cluster)
    }

    private func makeInventory(identity: ChipIdentity, catalog: SensorCatalog,
                               provider: SMCSensorProvider?) -> SensorInventory {
        // 6. Fans (read-only discovery). 7. Headline / safety sets come resolved from the catalog.
        let fans = provider.map { FanHardwareProfile.discover($0.connection) } ?? .none
        return SensorInventory(identity: identity, sensors: catalog.sensors, headline: catalog.headline,
                               safetySet: catalog.safetySet, fanProfile: fans, catalogStatus: catalog.status,
                               smcAvailable: provider != nil, smcKeyCount: provider?.keyCount ?? 0,
                               dieLayout: catalog.dieLayout, fanNames: catalog.fanNames)
    }

    private func logStart(_ inv: SensorInventory, hardware: SensorCatalog.Hardware?, started: ContinuousClock.Instant,
                          clock: ContinuousClock) {
        let elapsed = clock.now - started
        startDuration = elapsed
        let visible = inv.sensors.filter(\.isVisibleByDefault).count
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        log.info("""
            sensors: \(inv.sensors.count, privacy: .public) (\(visible, privacy: .public) visible), \
            catalog \(String(describing: inv.catalogStatus), privacy: .public), \
            smc keys \(inv.smcKeyCount, privacy: .public), hid products \(hardware?.hidProducts.count ?? 0, privacy: .public), \
            fans \(inv.fanProfile.fans.count, privacy: .public), start \(ms, format: .fixed(precision: 1), privacy: .public) ms
            """)
    }

    // MARK: One tick

    private struct SamplingPass {
        var values: [SensorID: Double] = [:]
        var raw: [SensorID: Double] = [:]
        var read = Set<SensorID>()               // decoded this tick (valid or not)
        var smcKeys: [FourCC] = []
        var hidIDs: [SensorID] = []
        var seen = Set<SensorID>()

        init(capacity: Int) {
            values.reserveCapacity(capacity)
            raw.reserveCapacity(capacity)
        }
    }

    public func sample(_ request: SampleRequest) async -> SensorFrame {
        let date = Date()
        let now = ContinuousClock.now
        guard inventory != nil else { return .empty(date) }
        let postWake = isPostWake(at: now)
        var pass = SamplingPass(capacity: request.sensorIDs.count)
        split(request, into: &pass)
        let smcFailures = smc?.connection.connectionFailureCount ?? 0
        let smcHealthy = readSMC(&pass, postWake: postWake)
        readHID(&pass, now: now, postWake: postWake)
        return makeFrame(pass, request: request, date: date, postWake: postWake, smcHealthy: smcHealthy, smcFailures: smcFailures)
    }

    private func isPostWake(at now: ContinuousClock.Instant) -> Bool {
        guard let until = postWakeUntil else { return false }
        if now < until { return true }
        postWakeUntil = nil
        return false
    }

    /// Split the request; ignore ids this inventory does not know and duplicates.
    private func split(_ request: SampleRequest, into pass: inout SamplingPass) {
        for id in request.sensorIDs where pass.seen.insert(id).inserted {
            switch id.source {
            case .smc: if let key = keyOf[id] { pass.smcKeys.append(key) }
            case .hid: if descriptors[id] != nil { pass.hidIDs.append(id) }
            }
        }
    }

    /// The connection replaces a stale client itself (once, then with backoff); a lost pass is abandoned for this tick.
    private func readSMC(_ pass: inout SamplingPass, postWake: Bool) -> Bool {
        guard let smc, !pass.smcKeys.isEmpty else { return smc != nil }
        return smc.readPass(pass.smcKeys) { key, value, _ in
            guard let id = idOf[key], let descriptor = descriptors[id] else { return }
            pass.read.insert(id)
            if value.isFinite { pass.raw[id] = value }
            guard filter.isValid(value, descriptor) else { return }
            if postWake && Self.gatingGroups.contains(descriptor.group) { return }   // 40.0 placeholders right after wake
            pass.values[id] = value
        }
    }

    /// HID: at most every `hidInterval`; a newly requested product is read at once.
    private func readHID(_ pass: inout SamplingPass, now: ContinuousClock.Instant, postWake: Bool) {
        guard let hid, !pass.hidIDs.isEmpty else { return }
        refreshHIDCache(hid, ids: pass.hidIDs, now: now)
        for id in pass.hidIDs { recordHID(id, into: &pass, postWake: postWake) }
    }

    private func refreshHIDCache(_ hid: HIDSensorReader, ids: [SensorID], now: ContinuousClock.Instant) {
        let due = hidReadAt.map { now - $0 >= Self.hidInterval } ?? true
        let fresh = due ? ids : ids.filter { !hidCached.contains($0) }
        guard !fresh.isEmpty else { return }
        let got = hid.read(products: fresh.map(\.key))
        if due { resetHIDCache(now: now) }
        for id in fresh { cacheHID(id, value: got[id.key]) }
    }

    private func resetHIDCache(now: ContinuousClock.Instant) {
        hidCache.removeAll(keepingCapacity: true)
        hidCached.removeAll(keepingCapacity: true)
        hidReadAt = now
    }

    private func cacheHID(_ id: SensorID, value: Double?) {
        hidCached.insert(id)
        hidCache[id] = value
    }

    private func recordHID(_ id: SensorID, into pass: inout SamplingPass, postWake: Bool) {
        guard let value = hidCache[id], let descriptor = descriptors[id] else { return }
        pass.read.insert(id)
        pass.raw[id] = value
        guard filter.isValid(value, descriptor), !(postWake && Self.gatingGroups.contains(descriptor.group)) else { return }
        pass.values[id] = value
    }

    private struct ClusterReadings {
        var ids: [SensorID] = []
        var anyValid = false
    }

    /// Gating requires every requested cluster key read to be invalid by value; post-wake forcing alone does not count.
    private func clusters(_ pass: SamplingPass) -> [ClusterKey: ClusterReadings] {
        var clusters: [ClusterKey: ClusterReadings] = [:]
        for id in pass.read {
            guard let cluster = clusterOf[id], let descriptor = descriptors[id] else { continue }
            let validByValue = pass.raw[id].map { filter.isValid($0, descriptor) } ?? false
            var entry = clusters[cluster] ?? ClusterReadings()
            entry.ids.append(id)
            entry.anyValid = entry.anyValid || validByValue
            clusters[cluster] = entry
        }
        return clusters
    }

    private func gatedClusters(_ pass: SamplingPass) -> Set<SensorID> {
        let clusters = clusters(pass)
        var gated = Set<SensorID>()
        for (_, entry) in clusters where !entry.anyValid { gated.formUnion(entry.ids) }
        return gated
    }

    private func makeFrame(_ pass: SamplingPass, request: SampleRequest, date: Date, postWake: Bool,
                           smcHealthy: Bool, smcFailures: Int) -> SensorFrame {
        let gated = gatedClusters(pass)
        let components = readComponents(request, date: date, smcHealthy: smcHealthy)
        if let smc { noteSMCLink(smc.connection, failed: smc.connection.connectionFailureCount != smcFailures) }
        return SensorFrame(date: date, values: pass.values, raw: pass.raw, gated: gated,
                           fans: components.fans, power: components.power, isPostWake: postWake)
    }

    /// Fans and power are skipped when the SMC pass was abandoned: a dead connection would read as 0 rpm.
    private func readComponents(_ request: SampleRequest, date: Date, smcHealthy: Bool)
        -> (fans: FanControlState?, power: PowerValues) {
        guard let smc, smcHealthy, let inv = inventory else { return (nil, .empty) }
        let fans = readFans(smc, request: request, inventory: inv, date: date)
        let power = request.components.contains(.power) ? smc.power() : .empty
        return (fans, power)
    }

    private func readFans(_ smc: SMCSensorProvider, request: SampleRequest,
                          inventory: SensorInventory, date: Date) -> FanControlState? {
        guard request.components.contains(.fans), !inventory.fanProfile.fans.isEmpty else { return nil }
        let before = smc.connection.connectionFailureCount
        let snapshot = FanReader.snapshot(smc.connection, profile: inventory.fanProfile, now: date)
        // The link died during the snapshot (or there was no pass to notice it): its failed reads are 0 rpm.
        return smc.connection.connectionFailureCount == before ? snapshot : nil
    }

    /// Logs each SMC link transition once (`failed`: a call this tick found no usable client) instead of an error per
    /// tick while it is down.
    private func noteSMCLink(_ link: SMCConnection, failed: Bool) {
        let reopens = link.reopenCount
        defer { smcReopens = reopens }
        if failed {
            noteSMCLinkFailure()
            return
        }
        noteAvailableSMCLink(link, reopens: reopens)
    }

    private func noteSMCLinkFailure() {
        if !smcLinkDown { log.error("SMC connection lost: SMC readings, fans and power are skipped until it can be reopened (retried with backoff)") }
        smcLinkDown = true
    }

    private func noteAvailableSMCLink(_ link: SMCConnection, reopens: Int) {
        if smcLinkDown, link.isOpen {
            smcLinkDown = false
            log.notice("SMC connection restored")
            return
        }
        if reopens != smcReopens { log.notice("SMC connection was stale: reopened") }
    }

    // MARK: Sleep / wake

    public func willSleep() async {
        // Cached HID values would otherwise be served after wake as if they were current.
        hidCache.removeAll(); hidCached.removeAll(); hidReadAt = nil
    }

    public func didWake() async {
        postWakeUntil = ContinuousClock.now.advanced(by: Self.postWakeWindow)
        smc?.reopenIfNeeded()
        hid?.refresh()
        hidCache.removeAll(); hidCached.removeAll(); hidReadAt = nil
        log.info("didWake: post-wake window \(Self.postWakeWindow.components.seconds, privacy: .public) s")
    }

    // MARK: Probe support (same package only)

    /// Every HID service instance with its current value (NaN kept), for `thermik-probe sensors snapshot`.
    package func hidInstances() -> [(product: String, location: String, registryID: UInt64, value: Double)] {
        (hid?.readAllInstances() ?? []).map { ($0.0.product, $0.0.locationFourCC, $0.0.registryID, $0.1) }
            .sorted { ($0.product, $0.registryID) < ($1.product, $1.registryID) }
    }

    /// Validity of a value for an inventory sensor, exactly as `sample(_:)` decides it (probe output).
    package func isValid(_ value: Double, for id: SensorID) -> Bool {
        guard let d = descriptors[id] else { return false }
        return filter.isValid(value, d)
    }
}
