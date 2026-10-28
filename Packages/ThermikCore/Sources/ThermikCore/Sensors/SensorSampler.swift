// SensorSampler.swift — Thermik (MIT). OWNER: Unit 1. Public API is FROZEN: `public actor SensorSampler: SensorSampling`
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
        let t0 = clock.now

        // 1–2. SMC (optional: HID-only mode when it cannot be opened) and identity.
        var provider: SMCSensorProvider?
        do {
            let p = try SMCSensorProvider()
            try p.discover()
            provider = p
        } catch {
            log.error("SMC unavailable: \(String(describing: error), privacy: .public); continuing with HID only")
        }
        let identity = ChipIdentity.read(smc: provider?.connection)
        filter = SanityFilter(appleSilicon: identity.isAppleSilicon)

        // 3. Catalog inputs. HID is opened only when something can come from it: DB `hid:` entries, an unknown chip,
        //    a chip without SMC die keys, or no SMC at all.
        let dbName = SensorCatalog.databaseName(for: identity)
        let db = SensorCatalog.loadDatabase(platform: dbName)
        let smcKeys = provider?.temperatureKeys.map { (key: $0.key.description, type: $0.info.type.description) } ?? []
        let needsHID = provider == nil || db == nil || !Heuristics.hasSMCDieKeys(smcKeys.map(\.key))
            || db?.sensors.contains { $0.key.hasPrefix("hid:") } == true
        if needsHID { hid = HIDSensorReader(kind: .temperature) }

        let hw = SensorCatalog.hardware(provider: provider, hidProducts: hid?.products ?? [], identity: identity, database: db)
        let catalog = SensorCatalog(database: db, hardware: hw)
        guard provider != nil || catalog.sensors.contains(where: { $0.id.source == .hid }) else {
            log.error("no sensor source (SMC and HID unavailable)")
            throw SensorSamplerError.noSensorSource
        }

        // 4–5. Lookups for the hot path.
        smc = provider
        let fourCC = Dictionary(provider?.temperatureKeys.map { ($0.key.description, $0.key) } ?? [], uniquingKeysWith: { a, _ in a })
        for s in catalog.sensors {
            descriptors[s.id] = s.descriptor
            if s.id.source == .smc, let k = fourCC[s.id.key] { keyOf[s.id] = k; idOf[k] = s.id }
            if Self.gatingGroups.contains(s.group), let c = s.descriptor.cluster { clusterOf[s.id] = ClusterKey(group: s.group, cluster: c) }
        }

        // 6. Fans (read-only discovery). 7. Headline / safety sets come resolved from the catalog.
        let fans = provider.map { FanHardwareProfile.discover($0.connection) } ?? .none
        let inv = SensorInventory(identity: identity, sensors: catalog.sensors, headline: catalog.headline,
                                  safetySet: catalog.safetySet, fanProfile: fans, catalogStatus: catalog.status,
                                  smcAvailable: provider != nil, smcKeyCount: provider?.keyCount ?? 0,
                                  dieLayout: catalog.dieLayout, fanNames: catalog.fanNames)
        inventory = inv
        let elapsed = clock.now - t0
        startDuration = elapsed
        let visible = inv.sensors.filter(\.isVisibleByDefault).count
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        log.info("""
            sensors: \(inv.sensors.count, privacy: .public) (\(visible, privacy: .public) visible), \
            catalog \(String(describing: catalog.status), privacy: .public), \
            smc keys \(inv.smcKeyCount, privacy: .public), hid products \(hw.hidProducts.count, privacy: .public), \
            fans \(fans.fans.count, privacy: .public), start \(ms, format: .fixed(precision: 1), privacy: .public) ms
            """)
        return inv
    }

    // MARK: One tick

    public func sample(_ request: SampleRequest) async -> SensorFrame {
        let date = Date()
        let now = ContinuousClock.now
        guard inventory != nil else { return .empty(date) }
        let postWake: Bool
        if let until = postWakeUntil, now < until { postWake = true } else { postWake = false; postWakeUntil = nil }

        var values: [SensorID: Double] = [:]
        var raw: [SensorID: Double] = [:]
        var read = Set<SensorID>()               // decoded this tick (valid or not)
        values.reserveCapacity(request.sensorIDs.count)
        raw.reserveCapacity(request.sensorIDs.count)

        // Split the request; ignore ids this inventory does not know and duplicates.
        var smcKeys: [FourCC] = []
        var hidIDs: [SensorID] = []
        var seen = Set<SensorID>()
        for id in request.sensorIDs where seen.insert(id).inserted {
            switch id.source {
            case .smc: if let k = keyOf[id] { smcKeys.append(k) }
            case .hid: if descriptors[id] != nil { hidIDs.append(id) }
            }
        }

        // SMC pass. The connection replaces a stale client itself (once, then with backoff while it cannot be opened);
        // a pass that still finds it lost is abandoned for this tick.
        var smcHealthy = smc != nil
        let smcFailures = smc?.connection.connectionFailureCount ?? 0
        if let smc, !smcKeys.isEmpty {
            smcHealthy = smc.readPass(smcKeys) { k, v, _ in
                guard let id = idOf[k], let d = descriptors[id] else { return }
                read.insert(id)
                if v.isFinite { raw[id] = v }
                guard filter.isValid(v, d) else { return }
                if postWake && Self.gatingGroups.contains(d.group) { return }   // 40.0 placeholders right after wake
                values[id] = v
            }
        }

        // HID: at most every `hidInterval`; a newly requested product is read at once.
        if let hid, !hidIDs.isEmpty {
            let due = hidReadAt.map { now - $0 >= Self.hidInterval } ?? true
            let fresh = due ? hidIDs : hidIDs.filter { !hidCached.contains($0) }
            if !fresh.isEmpty {
                let got = hid.read(products: fresh.map(\.key))
                if due { hidCache.removeAll(keepingCapacity: true); hidCached.removeAll(keepingCapacity: true); hidReadAt = now }
                for id in fresh { hidCached.insert(id); hidCache[id] = got[id.key] }
            }
            for id in hidIDs {
                guard let v = hidCache[id], let d = descriptors[id] else { continue }
                read.insert(id)
                raw[id] = v
                if filter.isValid(v, d) && !(postWake && Self.gatingGroups.contains(d.group)) { values[id] = v }
            }
        }

        // Gated clusters: every requested key of a (group, cluster) that was read is invalid by value (the post-wake
        // forcing alone does not count as gating).
        var clusters: [ClusterKey: (ids: [SensorID], anyValid: Bool)] = [:]
        for id in read {
            guard let c = clusterOf[id], let d = descriptors[id] else { continue }
            let validByValue = raw[id].map { filter.isValid($0, d) } ?? false
            var e = clusters[c] ?? ([], false)
            e.ids.append(id)
            e.anyValid = e.anyValid || validByValue
            clusters[c] = e
        }
        var gated = Set<SensorID>()
        for (_, e) in clusters where !e.anyValid { gated.formUnion(e.ids) }

        // Fans and power (skipped when the SMC pass was abandoned: a dead connection would read as 0 rpm).
        var fans: FanControlState?
        var power = PowerValues.empty
        if let smc, smcHealthy, let inv = inventory {
            if request.includeFans, !inv.fanProfile.fans.isEmpty {
                let before = smc.connection.connectionFailureCount
                fans = FanReader.snapshot(smc.connection, profile: inv.fanProfile, now: date)
                // The link died during the snapshot (or there was no pass to notice it): its failed reads are 0 rpm.
                if smc.connection.connectionFailureCount != before { fans = nil }
            }
            if request.includePower { power = smc.power() }
        }
        if let smc { noteSMCLink(smc.connection, failed: smc.connection.connectionFailureCount != smcFailures) }
        return SensorFrame(date: date, values: values, raw: raw, gated: gated, fans: fans, power: power, isPostWake: postWake)
    }

    /// Logs each SMC link transition once (`failed`: a call this tick found no usable client) instead of an error per
    /// tick while it is down.
    private func noteSMCLink(_ link: SMCConnection, failed: Bool) {
        let reopens = link.reopenCount
        defer { smcReopens = reopens }
        if failed {
            if !smcLinkDown { log.error("SMC connection lost: SMC readings, fans and power are skipped until it can be reopened (retried with backoff)") }
            smcLinkDown = true
        } else if smcLinkDown, link.isOpen {
            smcLinkDown = false
            log.notice("SMC connection restored")
        } else if reopens != smcReopens {
            log.notice("SMC connection was stale: reopened")
        }
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
