// Probe+Diagnostics.swift — OWNER: Unit 6. `thermik-probe diagnostics [--demo] [--seconds N]` — READ-ONLY;
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
        var notes: [String] = []

        let inventory: SensorInventory?
        do { inventory = try await sensorSampler.start() } catch {
            inventory = nil
            notes.append("sensor discovery failed (\(error)): no sensor or fan checks")
        }
        let machine = await systemSampler.start()
        let slow = await systemSampler.slowData(.all)
        let systemFrame = await systemSampler.sample(SystemSampleRequest(battery: true, powerSources: true))
        let battery = systemFrame.battery
        let pressure = systemFrame.pressure

        var engine = DiagnosticsEngine()
        if let inv = inventory { engine.load(inventory: inv) }
        let profile = inventory?.fanProfile ?? .none
        let ids = inventory?.sensors.map(\.id) ?? []
        print("observing fans and sensors for \(max(seconds, 1)) s …")
        for i in 0..<max(seconds, 1) {
            let frame = await sensorSampler.sample(SampleRequest(sensorIDs: ids))
            engine.observe(frame: frame, commands: [:], profile: profile)
            if i < seconds - 1 { try? await Task.sleep(for: .seconds(1)) }
        }

        // Thermik's helper: the probe never connects to it; the legacy install leaves a launchd plist.
        var helper: HelperHealth = FileManager.default.fileExists(atPath: ThermikHelper.Legacy.plistPath)
            ? .unreachable("installed (legacy plist present); the probe does not connect to it") : .notInstalled
        if profile.fans.isEmpty, inventory?.smcAvailable == true { helper = .notApplicable }
        if engine.foreignControlSuspected {
            // Name it: SMC clients that are plausible fan controllers, else installed known fan-control helpers.
            let live = SMCClientInspector.suspectedFanControllers().filter(DiagnosticsEngine.isPlausibleFanController)
            engine.foreignControllerName = live.first ?? DiagnosticsEngine.installedFanControlProducts().first
        }

        let context = DiagnosticsContext(slow: slow, battery: battery, helper: helper, inventory: inventory, pressure: pressure,
                                         pressureEventsToday: pressure > .nominal ? 1 : 0)
        let items = engine.items(context: context, now: Date())
        for n in notes { print("note: \(n)") }
        print("")
        for item in items {
            print("[\(DiagnosticsEngine.statusName(item.status).uppercased())] \(item.id.rawValue) — \(DiagnosticsEngine.summary(item.finding))")
            for d in item.details { print("    \(d.label): \(d.value)") }
        }

        let report = engine.report(items: items, machine: machine, inventory: inventory, appVersion: "probe")
            + DiagnosticsEngine.eventsMarkdown([AppEvent(payload: .appLaunched(version: "probe"))])
        print("\n----- report -----\n" + report + "----- end of report -----")
        if !demo {
            let serial = ProbeLive.platformString("IOPlatformSerialNumber")
            let uuid = ProbeLive.platformString("IOPlatformUUID")
            print((serial.map { !report.contains($0) } ?? true) ? "PASS the report does not contain this Mac's serial number"
                                                                 : "FAIL the report contains the serial number")
            print((uuid.map { !report.contains($0) } ?? true) ? "PASS the report does not contain the platform UUID"
                                                               : "FAIL the report contains the platform UUID")
        }
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
        let identity = ChipIdentity(platformName: platform, targetType: platformData("target-type"),
                                    modelIdentifier: HostInfo.modelIdentifier,
                                    chipName: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                                    isAppleSilicon: HostInfo.isAppleSilicon, smcPlatform: nil)
        var sensors: [Sensor] = []
        var catalog = CatalogStatus.heuristic(platform: platform)
        var headline: [HeadlineSet: [SensorID]] = [:]
        // The bundled per-chip database (same lookup as the demo sampler; resources sit next to the executable).
        let bundleURL = Bundle.main.bundleURL.appendingPathComponent("ThermikCore_ThermikCore.bundle")
        if let bundle = Bundle(url: bundleURL),
           let url = bundle.url(forResource: platform, withExtension: "json", subdirectory: "SensorDB")
                ?? bundle.url(forResource: platform, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let db = try? JSONDecoder().decode(ChipSensorDatabase.self, from: data) {
            catalog = db.verified ? .verified(platform: platform) : .unverified(platform: platform)
            sensors = db.sensors.filter { !$0.role.isNeverShown }.map {
                Sensor(id: SensorID(databaseKey: $0.key), quantity: .temperature, descriptor: $0, smcType: nil, isHeuristic: false)
            }
            for set in HeadlineSet.allCases { headline[set] = db.headlineKeys(set).map { SensorID(databaseKey: $0) } }
        }
        let keyCount = (try? smc?.keyCount()) ?? 0
        let fans = smc.map { FanHardwareProfile.discover($0) } ?? .none
        return SensorInventory(identity: identity, sensors: sensors, headline: headline,
                               safetySet: (headline[.cpuHotspot] ?? []) + (headline[.gpu] ?? []), fanProfile: fans,
                               catalogStatus: catalog, smcAvailable: smc != nil, smcKeyCount: keyCount,
                               dieLayout: [], fanNames: nil)
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
        let profile = Self.profile
        print("== fans: Thermik commands 3000 rpm; fan 0 reads 0 rpm (stalled), fan 1 reads 2000 rpm (33 % short)")
        var e = DiagnosticsEngine()
        var stalledAt: Int?, mismatchAt: Int?
        for t in 0...70 {
            e.observe(frame: Self.frame(t, fans: [Self.snap(0, 0, 3000), Self.snap(1, 2000, 3000)], ftst: 1),
                      commands: [0: .rpm(3000), 1: .rpm(3000)], profile: profile)
            if stalledAt == nil, !e.stalledFans.isEmpty { stalledAt = t }
            if mismatchAt == nil, !e.fansNotReachingTarget.isEmpty { mismatchAt = t }
        }
        check(stalledAt == 31 && e.stalledFans == [0], "fan 0 stalled after > 30 s (t=+\(stalledAt ?? -1)s), not before")
        check(mismatchAt == 61 && e.fansNotReachingTarget == [1], "fan 1 not reaching target after > 60 s (t=+\(mismatchAt ?? -1)s)")
        check(!e.foreignControlSuspected, "Thermik's own manual control is not a foreign controller")

        print("== fans: System mode, macOS stopped both fans (target 0, 0 rpm) for 5 min")
        e = DiagnosticsEngine()
        for t in 0...300 {
            e.observe(frame: Self.frame(t, fans: [Self.snap(0, 0, 0, .auto), Self.snap(1, 0, 0, .auto)]), commands: [:], profile: profile)
        }
        check(e.stalledFans.isEmpty && e.fansNotReachingTarget.isEmpty, "\"off by macOS\" is not a stall")

        print("== fans: another app forces both fans (Ftst=1, mode manual) while Thermik commands nothing")
        e = DiagnosticsEngine()
        var foreignAt: Int?
        for t in 0...15 {
            e.observe(frame: Self.frame(t, fans: [Self.snap(0, 3000, 3052), Self.snap(1, 3010, 3052)], ftst: 1),
                      commands: [0: .system, 1: .system], profile: profile)
            if foreignAt == nil, e.foreignControlSuspected { foreignAt = t }
        }
        check(foreignAt == 10, "foreign fan control suspected after 10 s (t=+\(foreignAt ?? -1)s)")
        e.foreignControllerName = "TG Pro"
        let ctx = DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled, inventory: nil, pressure: .nominal,
                                     pressureEventsToday: 0)
        let helperItem = e.items(context: ctx, now: Self.t0).first { $0.id == .helper }
        check(helperItem?.status == .warning && helperItem?.finding == .helper(.foreignController("TG Pro"))
              && helperItem?.details.contains(DiagnosticDetail("Thermik helper", "not installed")) == true,
              "helper item → warning, foreign controller \"TG Pro\" (Thermik helper: not installed kept in the details)")
        check(!DiagnosticsEngine.isPlausibleFanController("com.apphousekitchen.aldente-pro.helper")
              && DiagnosticsEngine.isPlausibleFanController("com.tunabellysoftware.TGFanHelper"),
              "a battery charge limiter's helper (AlDente) is never named as a fan controller")
    }

    mutating func sensors() {
        print("== sensors: 11 min; A constant while sibling B swings 5 °C, C invalid (5/6 of its group valid), "
              + "D out of range, G power-gated")
        let a = SensorID.smc("TpA1"), b = SensorID.smc("TpB1"), c = SensorID.smc("TpC1"), d = SensorID.smc("TbD1")
        let x = SensorID.smc("TpE1"), y = SensorID.smc("TpF1"), z = SensorID.smc("TpH1"), g = SensorID.smc("TpG1")
        let inv = Self.inventory([a, b, c, x, y, z, g].map { Self.sensor($0, .cpuPerformance) } + [Self.sensor(d, .battery)])
        var e = DiagnosticsEngine()
        e.load(inventory: inv)
        var early: [SensorID] = []
        for t in 0...660 {
            let wave = Double(t % 120) / 120 * 5
            let values: [SensorID: Double] = [a: 61.0, b: 60 + wave, x: 62 + wave / 10, y: 63 - wave / 10, z: 64 + wave / 5]
            e.observe(frame: Self.frame(t, fans: [Self.snap(0, 1400, 1400, .auto), Self.snap(1, 1400, 1400, .auto)], values: values,
                                        raw: [c: 40.0, d: -60, g: 0], gated: [g]),
                      commands: [:], profile: Self.profile)
            if t == 590 { early = e.suspectSensors().map(\.id) }
        }
        let suspects = e.suspectSensors()
        for s in suspects { print("    \(s.id): \(s.reason)") }
        check(Set(suspects.map(\.id)) == [a, c, d], "suspects are exactly A (stuck), C (invalid), D (out of range)")
        check(!early.contains(a), "A is not flagged before 10 min of constant value")
        let item = e.items(context: DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled, inventory: inv,
                                                       pressure: .nominal, pressureEventsToday: 0), now: Self.t0).first { $0.id == .sensors }
        check(item?.status == .warning && item?.finding == .sensorsSuspect([d, a, c].sorted()), "sensors item → warning")
    }

    mutating func items() async {
        print("== items: slow-data rules")
        let demo = DemoSystemSampler()
        var battery = await demo.sample(SystemSampleRequest(battery: true)).battery
        var health = await demo.slowData(.all).appleBatteryHealth
        func item(_ kind: DiagnosticKind, slow: SlowSystemData = SlowSystemData(), battery: BatterySnapshot? = nil,
                  helper: HelperHealth = .notInstalled, inventory: SensorInventory? = nil, pressure: ThermalPressure = .nominal,
                  events: Int = 0) -> DiagnosticItem? {
            DiagnosticsEngine().items(context: DiagnosticsContext(slow: slow, battery: battery, helper: helper, inventory: inventory,
                                                                  pressure: pressure, pressureEventsToday: events), now: Self.t0)
                .first { $0.id == kind }
        }
        check(item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .normalRestart))?.status == .ok, "normal restart → ok")
        check(item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .powerLoss))?.status == .warning, "power loss → warning")
        check(item(.lastShutdown, slow: SlowSystemData(shutdownVerdict: .kernelPanic))?.status == .error, "kernel panic → error")
        check(item(.lastShutdown)?.status == .unknown, "no boot data → unknown")
        check(item(.battery, slow: SlowSystemData(appleBatteryHealth: health), battery: battery)?.status == .ok, "healthy battery → ok")
        health?.maximumCapacityPercent = 76
        battery?.nominalChargeCapacity_mAh = 6500
        check(item(.battery, slow: SlowSystemData(appleBatteryHealth: health), battery: battery)?.status == .info, "health < 80 % → info")
        battery?.permanentFailureStatus = 0x10
        check(item(.battery, battery: battery)?.status == .warning, "permanent failure → warning")
        check(item(.battery)?.finding == .noBattery, "no battery data → noBattery (desktop)")
        check(item(.thermal, pressure: .heavy)?.status == .warning, "pressure heavy now → warning")
        check(item(.thermal, events: 2)?.status == .info, "pressure events today → info")
        check(item(.thermal)?.status == .ok, "nominal, no events → ok")
        check(item(.helper, helper: .ready(version: "0.1.0"))?.status == .ok, "helper ready → ok")
        check(item(.helper, helper: .requiresApproval)?.status == .warning, "helper needs approval → warning")
        check(item(.helper)?.status == .info, "helper not installed → info")
        var inv = Self.inventory([Self.sensor(.smc("Tp01"), .cpuPerformance)])
        check(item(.smc, inventory: inv)?.status == .ok, "verified catalog → ok")
        inv.catalogStatus = .heuristic(platform: "t9999")
        check(item(.smc, inventory: inv)?.status == .info, "heuristic catalog → info")
        inv.smcAvailable = false
        check(item(.smc, inventory: inv)?.status == .error, "SMC unavailable → error")
        inv.smcAvailable = true
        inv.fanProfile = .none
        check(item(.fans, inventory: inv)?.finding == .fanless, "no fans → fanless (info)")
    }

    /// Per-tick cost on the main actor with this Mac's real catalog (the bundled DB; every visible sensor valid).
    static func perf() {
        let inv = ProbeLive.inventory(smc: nil)
        let visible = inv.sensors.filter(\.isVisibleByDefault)
        print("== per-tick cost (\(inv.sensors.count) catalog sensors, \(visible.count) visible; debug build, other builds running)")
        var values: [SensorID: Double] = [:]
        for (i, s) in visible.enumerated() { values[s.id] = 50 + Double(i % 30) }
        let groups = Dictionary(visible.map { ($0.id, $0.displayGroup) }, uniquingKeysWith: { a, _ in a })
        let n = 2_000
        let clock = ContinuousClock()
        var e = DiagnosticsEngine()
        e.load(inventory: inv)
        let observe = clock.measure {
            for t in 0..<n {
                e.observe(frame: frame(t, fans: [snap(0, 1400, 1400, .auto), snap(1, 1400, 1400, .auto)], values: values),
                          commands: [:], profile: profile)
            }
        }
        let ctx = DiagnosticsContext(slow: SlowSystemData(), battery: nil, helper: .notInstalled, inventory: inv, pressure: .nominal,
                                     pressureEventsToday: 0)
        let items = clock.measure { for _ in 0..<200 { _ = e.items(context: ctx, now: t0) } }
        var alerts = AlertEngine()
        let evaluate = clock.measure {
            for t in 0..<n {
                _ = alerts.evaluate(rules: AlertRule.defaultRules,
                                    inputs: AlertInputs(date: t0.addingTimeInterval(Double(t)), sensorValues: values, sensorGroups: groups,
                                                        aggregates: .empty, stalledFans: [], fanModeChange: nil, pressure: .nominal,
                                                        abnormalShutdown: nil, batteryNeedsService: false))
            }
        }
        func us(_ d: Duration, _ count: Int) -> String {
            String(format: "%.1f µs", Double(d.components.attoseconds) / 1e12 / Double(count) + Double(d.components.seconds) * 1e6 / Double(count))
        }
        print("    DiagnosticsEngine.observe  \(us(observe, n)) per tick (frame building included)")
        print("    DiagnosticsEngine.items    \(us(items, 200)) per evaluation (every 5 s)")
        print("    AlertEngine.evaluate       \(us(evaluate, n)) per tick (7 default rules)")
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
