// Probe+Diagnostics.swift — `thermik-probe diagnostics [--demo] [--seconds N]` — READ-ONLY;
// `thermik-probe diagnostics selftest` — synthetic frames through every DiagnosticsEngine rule (no hardware).
// Discovers sensors and system data through the real samplers (the demo samplers with --demo), observes fans and
// sensors at 1 Hz for N s (default 12; foreign fan control needs 10 s), prints every DiagnosticItem with its raw
// details, then the Markdown report, and checks that the report contains neither this Mac's serial number nor its
// platform UUID (both are read here only for that comparison and never printed). Nothing is written anywhere; the
// SMC is only read.
import Foundation
import IOKit
import ThermikCore
import ThermikHelperShared
import ThermikSMC

extension Probe {
    static func diagnostics(_ args: [String]) async {
        if args.first == "selftest" { return await DiagnosticsSelfTest.run() }
        let demo = args.contains("--demo")
        let seconds = args.firstIndex(of: "--seconds").flatMap { i in args.indices.contains(i + 1) ? Int(args[i + 1]) : nil } ?? 12
        let sensorSampler: any SensorSampling = demo ? DemoSensorSampler() : SensorSampler()
        let systemSampler: any SystemSampling = demo ? DemoSystemSampler() : SystemSampler()
        let report = await diagnosticReport(sensorSampler: sensorSampler, systemSampler: systemSampler, seconds: seconds)
        if !demo { checkReportRedaction(report) }
    }

    private static func diagnosticReport(sensorSampler: any SensorSampling,
                                         systemSampler: any SystemSampling, seconds: Int) async -> String {
        let snapshot = await loadSnapshot(sensorSampler: sensorSampler, systemSampler: systemSampler)
        var engine = DiagnosticsEngine()
        if let inventory = snapshot.inventory { engine.load(inventory: inventory) }
        await observe(&engine, sampler: sensorSampler, inventory: snapshot.inventory, seconds: seconds)
        let helper = helperHealth(inventory: snapshot.inventory)
        configureForeignController(&engine)
        let items = engine.items(context: snapshot.context(helper: helper), now: Date())
        printDiagnostics(notes: snapshot.notes, items: items)
        return makeReport(&engine, items: items, machine: snapshot.machine, inventory: snapshot.inventory)
    }

    private static func loadSnapshot(sensorSampler: any SensorSampling,
                                     systemSampler: any SystemSampling) async -> DiagnosticsSnapshot {
        let discovery = await discoverInventory(sensorSampler)
        let machine = await systemSampler.start()
        let slow = await systemSampler.slowData(.all)
        let frame = await systemSampler.sample([.battery, .powerSources])
        return DiagnosticsSnapshot(inventory: discovery.inventory, notes: discovery.notes, machine: machine, slow: slow,
                                   battery: frame.battery, pressure: frame.pressure)
    }

    private static func discoverInventory(_ sampler: any SensorSampling) async
        -> (inventory: SensorInventory?, notes: [String]) {
        do { return (try await sampler.start(), []) } catch {
            return (nil, ["sensor discovery failed (\(error)): no sensor or fan checks"])
        }
    }

    private static func observe(_ engine: inout DiagnosticsEngine, sampler: any SensorSampling,
                                inventory: SensorInventory?, seconds: Int) async {
        let profile = inventory?.fanProfile ?? .none
        let ids = inventory?.sensors.map(\.id) ?? []
        print("observing fans and sensors for \(max(seconds, 1)) s …")
        for i in 0..<max(seconds, 1) {
            let frame = await sampler.sample(SampleRequest(sensorIDs: ids))
            engine.observe(frame: frame, commands: [:], profile: profile)
            if i < seconds - 1 { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    private static func helperHealth(inventory: SensorInventory?) -> HelperHealth {
        // Thermik's helper: the probe never connects to it; the legacy install leaves a launchd plist.
        var helper: HelperHealth = FileManager.default.fileExists(atPath: ThermikHelper.Legacy.plistPath)
            ? .unreachable("installed (legacy plist present); the probe does not connect to it") : .notInstalled
        if inventory?.fanProfile.fans.isEmpty == true, inventory?.smcAvailable == true { helper = .notApplicable }
        return helper
    }

    private static func configureForeignController(_ engine: inout DiagnosticsEngine) {
        guard engine.foreignControlSuspected else { return }
        // Name it: SMC clients that are plausible fan controllers, else installed known fan-control helpers.
        let live = SMCClientInspector.suspectedFanControllers().filter(DiagnosticsEngine.isPlausibleFanController)
        engine.foreignControllerName = live.first ?? DiagnosticsEngine.installedFanControlProducts().first
    }

    private static func printDiagnostics(notes: [String], items: [DiagnosticItem]) {
        for note in notes { print("note: \(note)") }
        print("")
        for item in items {
            print("[\(DiagnosticsEngine.statusName(item.status).uppercased())] \(item.id.rawValue) — \(DiagnosticsEngine.summary(item.finding))")
            for detail in item.details { print("    \(detail.label): \(detail.value)") }
        }
    }

    private static func makeReport(_ engine: inout DiagnosticsEngine, items: [DiagnosticItem],
                                   machine: MachineInfo, inventory: SensorInventory?) -> String {
        let report = engine.report(items: items, machine: machine, inventory: inventory, appVersion: "probe")
            + DiagnosticsEngine.eventsMarkdown([AppEvent(payload: .appLaunched(version: "probe"))])
        print("\n----- report -----\n" + report + "----- end of report -----")
        return report
    }

    private static func checkReportRedaction(_ report: String) {
        let serial = ProbeLive.platformString("IOPlatformSerialNumber")
        let uuid = ProbeLive.platformString("IOPlatformUUID")
        print((serial.map { !report.contains($0) } ?? true) ? "PASS the report does not contain this Mac's serial number"
                                                             : "FAIL the report contains the serial number")
        print((uuid.map { !report.contains($0) } ?? true) ? "PASS the report does not contain the platform UUID"
                                                           : "FAIL the report contains the platform UUID")
    }
}

private struct DiagnosticsSnapshot {
    let inventory: SensorInventory?
    let notes: [String]
    let machine: MachineInfo
    let slow: SlowSystemData
    let battery: BatterySnapshot?
    let pressure: ThermalPressure

    func context(helper: HelperHealth) -> DiagnosticsContext {
        DiagnosticsContext(slow: slow, battery: battery, helper: helper, inventory: inventory, pressure: pressure,
                           pressureEventsToday: pressure > .nominal ? 1 : 0)
    }
}

/// Small read-only helpers shared by the probes: header facts for `log write`, the redaction check, and the bundled
/// catalog without hardware for the per-tick cost test. Sources: sysctl(3), IORegistry properties, the bundled DB.
enum ProbeLive {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func sysctlDate(_ name: String) -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }

    /// "27.0.1 (26A434)".
    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" + (sysctlString("kern.osversion").map { " (\($0))" } ?? "")
    }

    private static func withService<T>(_ className: String, _ body: (io_registry_entry_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return body(service)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// IOPlatformExpertDevice string property (serial / UUID are read only to verify the report never contains them).
    static func platformString(_ key: String) -> String? {
        withService("IOPlatformExpertDevice") { property($0, key) as? String }
    }

    /// Device-tree data property ("platform-name", "target-type") as its first C string.
    private static func platformData(_ key: String) -> String? {
        withService("IOPlatformExpertDevice") { e in
            (property(e, key) as? Data).flatMap { d in d.split(separator: 0).first.map { String(decoding: $0, as: UTF8.self) } }
        }
    }

    static func inventory(smc: SMCConnection?) -> SensorInventory {
        let platform = platformData("platform-name") ?? "unknown"
        let catalog = bundledCatalog(platform: platform)
        let keyCount = (try? smc?.keyCount()) ?? 0
        let fans = smc.map { FanHardwareProfile.discover($0) } ?? .none
        return SensorInventory(identity: identity(platform: platform), sensors: catalog.sensors, headline: catalog.headline,
                               safetySet: (catalog.headline[.cpuHotspot] ?? []) + (catalog.headline[.gpu] ?? []), fanProfile: fans,
                               catalogStatus: catalog.status, smcAvailable: smc != nil, smcKeyCount: keyCount,
                               dieLayout: [], fanNames: nil)
    }

    private static func identity(platform: String) -> ChipIdentity {
        ChipIdentity(platformName: platform, targetType: platformData("target-type"),
                     modelIdentifier: HostInfo.modelIdentifier,
                     chipName: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                     isAppleSilicon: HostInfo.isAppleSilicon, smcPlatform: nil)
    }

    private static func bundledCatalog(platform: String)
        -> (sensors: [Sensor], headline: [HeadlineSet: [SensorID]], status: CatalogStatus) {
        guard let db = bundledDatabase(platform: platform) else { return ([], [:], .heuristic(platform: platform)) }
        let sensors = db.sensors.filter { !$0.role.isNeverShown }.map {
            Sensor(id: SensorID(databaseKey: $0.key), quantity: .temperature, descriptor: $0, smcType: nil, isHeuristic: false)
        }
        let headline = Dictionary(uniqueKeysWithValues: HeadlineSet.allCases.map { set in
            (set, db.headlineKeys(set).map { SensorID(databaseKey: $0) })
        })
        let status: CatalogStatus = db.verified ? .verified(platform: platform) : .unverified(platform: platform)
        return (sensors, headline, status)
    }

    /// The bundled per-chip database (same lookup as the demo sampler; resources sit next to the executable).
    private static func bundledDatabase(platform: String) -> ChipSensorDatabase? {
        let bundleURL = Bundle.main.bundleURL.appendingPathComponent("ThermikCore_ThermikCore.bundle")
        guard let bundle = Bundle(url: bundleURL),
              let url = bundle.url(forResource: platform, withExtension: "json", subdirectory: "SensorDB")
                ?? bundle.url(forResource: platform, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChipSensorDatabase.self, from: data)
    }
}

/// `diagnostics selftest`: synthetic 1 Hz frames through the engine rules (SPEC §2.13) and the report redaction.
/// Exits with status 1 when a check fails.
private struct DiagnosticsSelfTest {
    static let t0 = Date(timeIntervalSince1970: 1_793_016_000)       // 2026-10-26T12:00:00Z
    var failed = 0

    mutating func check(_ ok: Bool, _ what: String) {
        print("  \(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failed += 1 }
    }

    static func run() async {
        var test = DiagnosticsSelfTest()
        test.fans()
        test.sensors()
        await test.items()
        test.redaction()
        perf()
        print(test.failed == 0 ? "\nall checks passed" : "\n\(test.failed) check(s) failed")
        if test.failed > 0 { exit(1) }
    }

    static let profile = FanHardwareProfile(
        fans: (0..<2).map { FanDescriptor(index: $0, name: "Fan \($0)", minRPM: 1350, maxRPM: 5777, targetType: .flt,
                                          modeKey: .fan(FanHardwareProfile.modeUpper, $0)) },
        scheme: .appleSilicon(modeKeyTemplate: FanHardwareProfile.modeUpper, hasFtst: true))

    static func frame(_ t: Int, fans: [FanSnapshot], ftst: UInt8 = 0, values: [SensorID: Double] = [:],
                      raw: [SensorID: Double] = [:], gated: Set<SensorID> = []) -> SensorFrame {
        SensorFrame(date: t0.addingTimeInterval(Double(t)), values: values, raw: raw.merging(values) { a, _ in a }, gated: gated,
                    fans: FanControlState(ftst: ftst, forceBits: nil, fans: fans), power: .empty, isPostWake: false)
    }

    static func snap(_ i: Int, _ actual: Double, _ target: Double, _ mode: FanModeValue = .manual) -> FanSnapshot {
        FanSnapshot(index: i, actualRPM: actual, targetRPM: target, mode: mode, dutyCycle: nil, timestamp: t0)
    }

    static func sensor(_ id: SensorID, _ group: SensorGroup) -> Sensor {
        Sensor(id: id, quantity: .temperature, descriptor: SensorDescriptor(key: id.key, name: id.key, group: group),
               smcType: "flt ", isHeuristic: false)
    }

    static func inventory(_ sensors: [Sensor]) -> SensorInventory {
        SensorInventory(identity: ChipIdentity(platformName: "test", targetType: nil, modelIdentifier: "Test1,1", chipName: "Test",
                                               isAppleSilicon: true, smcPlatform: nil),
                        sensors: sensors, headline: [:], safetySet: [], fanProfile: profile, catalogStatus: .verified(platform: "test"),
                        smcAvailable: true, smcKeyCount: 100, dieLayout: [], fanNames: nil)
    }

    mutating func fans() {
        commandFans()
        systemStoppedFans()
        let engine = foreignFanDetection()
        checkForeignController(engine)
    }

    private mutating func commandFans() {
        print("== fans: Thermik commands 3000 rpm; fan 0 reads 0 rpm (stalled), fan 1 reads 2000 rpm (33 % short)")
        var engine = DiagnosticsEngine()
        var stalledAt: Int?, mismatchAt: Int?
        for t in 0...70 {
            observeCommandFan(&engine, t: t)
            if stalledAt == nil, !engine.stalledFans.isEmpty { stalledAt = t }
            if mismatchAt == nil, !engine.fansNotReachingTarget.isEmpty { mismatchAt = t }
        }
        checkCommandFan(engine, stalledAt: stalledAt, mismatchAt: mismatchAt)
    }

    private func observeCommandFan(_ engine: inout DiagnosticsEngine, t: Int) {
        engine.observe(frame: Self.frame(t, fans: [Self.snap(0, 0, 3000), Self.snap(1, 2000, 3000)], ftst: 1),
                       commands: [0: .rpm(3000), 1: .rpm(3000)], profile: Self.profile)
    }

    private mutating func checkCommandFan(_ engine: DiagnosticsEngine, stalledAt: Int?, mismatchAt: Int?) {
        check(stalledAt == 31 && engine.stalledFans == [0], "fan 0 stalled after > 30 s (t=+\(stalledAt ?? -1)s), not before")
        check(mismatchAt == 61 && engine.fansNotReachingTarget == [1], "fan 1 not reaching target after > 60 s (t=+\(mismatchAt ?? -1)s)")
        check(!engine.foreignControlSuspected, "Thermik's own manual control is not a foreign controller")
    }

    private mutating func systemStoppedFans() {
        print("== fans: System mode, macOS stopped both fans (target 0, 0 rpm) for 5 min")
        var engine = DiagnosticsEngine()
        for t in 0...300 {
            engine.observe(frame: Self.frame(t, fans: [Self.snap(0, 0, 0, .auto), Self.snap(1, 0, 0, .auto)]), commands: [:], profile: Self.profile)
        }
        check(engine.stalledFans.isEmpty && engine.fansNotReachingTarget.isEmpty, "\"off by macOS\" is not a stall")
    }

    private mutating func foreignFanDetection() -> DiagnosticsEngine {
        print("== fans: another app forces both fans (Ftst=1, mode manual) while Thermik commands nothing")
        var engine = DiagnosticsEngine()
        var foreignAt: Int?
        for t in 0...15 {
            observeForeignFan(&engine, t: t)
            if foreignAt == nil, engine.foreignControlSuspected { foreignAt = t }
        }
        check(foreignAt == 10, "foreign fan control suspected after 10 s (t=+\(foreignAt ?? -1)s)")
        engine.foreignControllerName = "TG Pro"
        return engine
    }

    private func observeForeignFan(_ engine: inout DiagnosticsEngine, t: Int) {
        engine.observe(frame: Self.frame(t, fans: [Self.snap(0, 3000, 3052), Self.snap(1, 3010, 3052)], ftst: 1),
                       commands: [0: .system, 1: .system], profile: Self.profile)
    }

    private mutating func checkForeignController(_ original: DiagnosticsEngine) {
        let engine = original
        let context = DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled, inventory: nil, pressure: .nominal,
                                         pressureEventsToday: 0)
        let helperItem = engine.items(context: context, now: Self.t0).first { $0.id == .helper }
        check(helperItem?.status == .warning && helperItem?.finding == .helper(.foreignController("TG Pro"))
              && helperItem?.details.contains(DiagnosticDetail("Thermik helper", "not installed")) == true,
              "helper item → warning, foreign controller \"TG Pro\" (Thermik helper: not installed kept in the details)")
        check(!DiagnosticsEngine.isPlausibleFanController("com.apphousekitchen.aldente-pro.helper")
              && DiagnosticsEngine.isPlausibleFanController("com.tunabellysoftware.TGFanHelper"),
              "a battery charge limiter's helper (AlDente) is never named as a fan controller")
    }

    private struct SensorFixture {
        let a = SensorID.smc("TpA1"), b = SensorID.smc("TpB1"), c = SensorID.smc("TpC1"), d = SensorID.smc("TbD1")
        let x = SensorID.smc("TpE1"), y = SensorID.smc("TpF1"), z = SensorID.smc("TpH1"), g = SensorID.smc("TpG1")
        let inventory: SensorInventory

        init() {
            inventory = DiagnosticsSelfTest.inventory([a, b, c, x, y, z, g].map { DiagnosticsSelfTest.sensor($0, .cpuPerformance) }
                + [DiagnosticsSelfTest.sensor(d, .battery)])
        }
    }

    mutating func sensors() {
        print("== sensors: 11 min; A constant while sibling B swings 5 °C, C invalid (5/6 of its group valid), "
              + "D out of range, G power-gated")
        let fixture = SensorFixture()
        var engine = DiagnosticsEngine()
        engine.load(inventory: fixture.inventory)
        let early = observeSensors(&engine, fixture: fixture)
        checkSensors(engine, early: early, fixture: fixture)
    }

    private func observeSensors(_ engine: inout DiagnosticsEngine, fixture: SensorFixture) -> [SensorID] {
        var early: [SensorID] = []
        for t in 0...660 {
            let values = sensorValues(fixture: fixture, t: t)
            engine.observe(frame: Self.frame(t, fans: [Self.snap(0, 1400, 1400, .auto), Self.snap(1, 1400, 1400, .auto)], values: values,
                                             raw: [fixture.c: 40.0, fixture.d: -60, fixture.g: 0], gated: [fixture.g]),
                           commands: [:], profile: Self.profile)
            if t == 590 { early = engine.suspectSensors().map(\.id) }
        }
        return early
    }

    private func sensorValues(fixture: SensorFixture, t: Int) -> [SensorID: Double] {
        let wave = Double(t % 120) / 120 * 5
        return [fixture.a: 61.0, fixture.b: 60 + wave, fixture.x: 62 + wave / 10,
                fixture.y: 63 - wave / 10, fixture.z: 64 + wave / 5]
    }

    private mutating func checkSensors(_ original: DiagnosticsEngine, early: [SensorID], fixture: SensorFixture) {
        let engine = original
        let suspects = engine.suspectSensors()
        for suspect in suspects { print("    \(suspect.id): \(suspect.reason)") }
        check(Set(suspects.map(\.id)) == [fixture.a, fixture.c, fixture.d], "suspects are exactly A (stuck), C (invalid), D (out of range)")
        check(!early.contains(fixture.a), "A is not flagged before 10 min of constant value")
        let item = engine.items(context: DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled,
                                                            inventory: fixture.inventory, pressure: .nominal, pressureEventsToday: 0),
                                now: Self.t0).first { $0.id == .sensors }
        check(item?.status == .warning && item?.finding == .sensorsSuspect([fixture.d, fixture.a, fixture.c].sorted()), "sensors item → warning")
    }

    mutating func items() async {
        print("== items: slow-data rules")
        let demo = DemoSystemSampler()
        let battery = await demo.sample(.battery).battery
        let health = await demo.slowData(.all).appleBatteryHealth
        shutdownItems()
        batteryItems(battery: battery, health: health)
        thermalItems()
        helperItems()
        inventoryItems()
    }

    private static func item(_ kind: DiagnosticKind, slow: SlowSystemData = SlowSystemData(), battery: BatterySnapshot? = nil,
                             helper: HelperHealth = .notInstalled, inventory: SensorInventory? = nil,
                             pressure: ThermalPressure = .nominal, events: Int = 0) -> DiagnosticItem? {
        DiagnosticsEngine().items(context: DiagnosticsContext(slow: slow, battery: battery, helper: helper, inventory: inventory,
                                                              pressure: pressure, pressureEventsToday: events), now: t0)
            .first { $0.id == kind }
    }

    private mutating func shutdownItems() {
        check(Self.item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .normalRestart))?.status == .ok, "normal restart → ok")
        check(Self.item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .powerLoss))?.status == .warning, "power loss → warning")
        check(Self.item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .kernelPanic))?.status == .error, "kernel panic → error")
        check(Self.item(.lastShutdown)?.status == .unknown, "no boot data → unknown")
    }

    private mutating func batteryItems(battery originalBattery: BatterySnapshot?, health originalHealth: AppleBatteryHealth?) {
        var battery = originalBattery
        var health = originalHealth
        check(Self.item(.battery, slow: SlowSystemData(appleBatteryHealth: health), battery: battery)?.status == .ok, "healthy battery → ok")
        health?.maximumCapacityPercent = 76
        battery?.nominalChargeCapacity_mAh = 6500
        check(Self.item(.battery, slow: SlowSystemData(appleBatteryHealth: health), battery: battery)?.status == .info, "health < 80 % → info")
        battery?.permanentFailureStatus = 0x10
        check(Self.item(.battery, battery: battery)?.status == .warning, "permanent failure → warning")
        check(Self.item(.battery)?.finding == .noBattery, "no battery data → noBattery (desktop)")
    }

    private mutating func thermalItems() {
        check(Self.item(.thermal, pressure: .heavy)?.status == .warning, "pressure heavy now → warning")
        check(Self.item(.thermal, events: 2)?.status == .info, "pressure events today → info")
        check(Self.item(.thermal)?.status == .ok, "nominal, no events → ok")
    }

    private mutating func helperItems() {
        check(Self.item(.helper, helper: .ready(version: "0.1.0"))?.status == .ok, "helper ready → ok")
        check(Self.item(.helper, helper: .requiresApproval)?.status == .warning, "helper needs approval → warning")
        check(Self.item(.helper)?.status == .info, "helper not installed → info")
    }

    private mutating func inventoryItems() {
        var inventory = Self.inventory([Self.sensor(.smc("Tp01"), .cpuPerformance)])
        check(Self.item(.smc, inventory: inventory)?.status == .ok, "verified catalog → ok")
        inventory.catalogStatus = .heuristic(platform: "t9999")
        check(Self.item(.smc, inventory: inventory)?.status == .info, "heuristic catalog → info")
        inventory.smcAvailable = false
        check(Self.item(.smc, inventory: inventory)?.status == .error, "SMC unavailable → error")
        inventory.smcAvailable = true
        inventory.fanProfile = .none
        check(Self.item(.fans, inventory: inventory)?.finding == .fanless, "no fans → fanless (info)")
    }

    /// Per-tick cost on the main actor with this Mac's real catalog (the bundled DB; every visible sensor valid).
    static func perf() {
        let inventory = ProbeLive.inventory(smc: nil)
        let visible = inventory.sensors.filter(\.isVisibleByDefault)
        print("== per-tick cost (\(inventory.sensors.count) catalog sensors, \(visible.count) visible; debug build, other builds running)")
        let values = perfValues(visible)
        let groups = Dictionary(visible.map { ($0.id, $0.displayGroup) }, uniquingKeysWith: { a, _ in a })
        var engine = performanceEngine(inventory: inventory)
        let observe = measureObserve(&engine, values: values, n: 2_000)
        let items = measureItems(&engine, inventory: inventory)
        let evaluate = measureAlerts(values: values, groups: groups, n: 2_000)
        printPerf(observe: observe, items: items, evaluate: evaluate, n: 2_000)
    }

    private static func perfValues(_ visible: [Sensor]) -> [SensorID: Double] {
        Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, 50 + Double($0.offset % 30)) })
    }

    private static func performanceEngine(inventory: SensorInventory) -> DiagnosticsEngine {
        var engine = DiagnosticsEngine()
        engine.load(inventory: inventory)
        return engine
    }

    private static func measureObserve(_ engine: inout DiagnosticsEngine, values: [SensorID: Double], n: Int) -> Duration {
        ContinuousClock().measure {
            for t in 0..<n {
                engine.observe(frame: frame(t, fans: [snap(0, 1400, 1400, .auto), snap(1, 1400, 1400, .auto)], values: values),
                               commands: [:], profile: profile)
            }
        }
    }

    private static func measureItems(_ engine: inout DiagnosticsEngine, inventory: SensorInventory) -> Duration {
        let context = DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled, inventory: inventory,
                                         pressure: .nominal, pressureEventsToday: 0)
        return ContinuousClock().measure { for _ in 0..<200 { _ = engine.items(context: context, now: t0) } }
    }

    private static func measureAlerts(values: [SensorID: Double], groups: [SensorID: DisplayGroup], n: Int) -> Duration {
        var alerts = AlertEngine()
        return ContinuousClock().measure {
            for t in 0..<n {
                _ = alerts.evaluate(rules: AlertRule.defaultRules,
                                    inputs: AlertInputs(date: t0.addingTimeInterval(Double(t)), sensorValues: values, sensorGroups: groups,
                                                        aggregates: .empty, stalledFans: [], fanModeChange: nil, pressure: .nominal,
                                                        abnormalShutdown: nil, batteryNeedsService: false))
            }
        }
    }

    private static func printPerf(observe: Duration, items: Duration, evaluate: Duration, n: Int) {
        print("    DiagnosticsEngine.observe  \(us(observe, n)) per tick (frame building included)")
        print("    DiagnosticsEngine.items    \(us(items, 200)) per evaluation (every 5 s)")
        print("    AlertEngine.evaluate       \(us(evaluate, n)) per tick (7 default rules)")
    }

    private static func us(_ duration: Duration, _ count: Int) -> String {
        String(format: "%.1f µs", Double(duration.components.attoseconds) / 1e12 / Double(count)
            + Double(duration.components.seconds) * 1e6 / Double(count))
    }

    mutating func redaction() {
        print("== report redaction")
        let raw = "serial C02XL0GZJGH5 / FVFXK123AB, uuid 6F1C0001-0000-4000-8000-000000000001, mac a4:83:e7:12:34:56, "
            + "path /Users/alice/Library/x, keep: J616cAP Mac16,5 26A434 0x70070000 TG0B APPLESSDAB"
        let red = DiagnosticsEngine.redact(raw)
        print("    \(red)")
        check(!red.contains("C02XL0GZJGH5") && !red.contains("FVFXK123AB"), "serial-like tokens redacted")
        check(!red.contains("6F1C0001-0000") && !red.contains("a4:83:e7") && !red.contains("alice"), "UUID, MAC and user name redacted")
        check(red.contains("J616cAP") && red.contains("Mac16,5") && red.contains("26A434") && red.contains("0x70070000")
              && red.contains("APPLESSDAB"), "model ids, build numbers, hex values and letter-only words are kept")
    }
}
