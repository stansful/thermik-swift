// Probe+Helper.swift — OWNER: Unit 4. Manual verification of the privileged-helper stack (NOT a test target).
//   thermik-probe helper selftest [Thermik.app]   HelperService + HelperXPCServer + PeerValidator + HelperConnection
//                                                 in ONE process over NSXPCListener.anonymous() with MockFanController.
//                                                 Never touches the SMC, needs no root, installs nothing.
//   thermik-probe helper status [Thermik.app]     read-only: install state, trust file, marker, conflicting helpers,
//                                                 and what HelperManager decides for that app (mode, state)
//   thermik-probe helper plan [Thermik.app]       print the legacy install plan and root script (NOT executed)
import Foundation
import ServiceManagement
import ThermikHelperCore
import ThermikHelperShared
import ThermikSMC
import ThermikSMCWriter

extension Probe {
    static func helper(_ args: [String]) async {
        let sub = args.first ?? "selftest"
        let rest = Array(args.dropFirst())
        switch sub {
        case "selftest": await HelperSelfTest.run(appPath: rest.first)
        case "status": HelperProbeTools.status(appPath: rest.first)
        case "plan": HelperProbeTools.plan(appPath: rest.first)
        default: print("thermik-probe helper selftest [Thermik.app] | status [Thermik.app] | plan [Thermik.app]")
        }
    }
}

// MARK: - Shared probe utilities

/// NSXPCListenerEndpoint is not annotated Sendable; it is an immutable handle, safe to share.
private struct EndpointBox: @unchecked Sendable { let endpoint: NSXPCListenerEndpoint }

/// Thread-safe flag for callbacks.
private final class LockedFlag: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private enum HelperProbeTools {
    /// Thermik.app to inspect: the argument, else the Debug build of scripts/lib/build.sh relative to the working
    /// directory.
    static func findApp(_ path: String?) -> URL? {
        let fm = FileManager.default
        let candidates = path.map { [$0] } ?? [
            "build/DerivedData/Build/Products/Debug/Thermik.app",
            "../../build/DerivedData/Build/Products/Debug/Thermik.app",
        ]
        for c in candidates {
            let url = URL(fileURLWithPath: c, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL
            if fm.fileExists(atPath: url.appending(path: "Contents/MacOS/\(ThermikHelper.helperExecutableName)").path) { return url }
        }
        return nil
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func status(appPath: String?) {
        let L = ThermikHelper.Legacy.self
        let fm = FileManager.default
        print("probe identity:      \(CodeIdentity.ofSelf().map(String.init(describing:)) ?? "unreadable")")
        print("legacy plist:        \(fm.fileExists(atPath: L.plistPath) ? "present" : "absent") (\(L.plistPath))")
        let legacyStatus = SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: L.plistPath))
        print("statusForLegacyPlist: \(legacyStatus.rawValue) (0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound)")
        print("legacy helper:       \(fm.fileExists(atPath: L.helperPath) ? "present, build \(LegacyHelperInstaller.installedHelperBuild() ?? "?")" : "absent")")
        if let hashes = LegacyHelperInstaller.trustedClientCDHashes() {
            print("trust file:          \(hashes.count) cdhash(es): \(hashes.joined(separator: ", "))")
        } else {
            print("trust file:          absent (\(L.trustFilePath))")
        }
        print("crash marker:        \(fm.fileExists(atPath: ThermikHelper.manualMarkerPath) ? "PRESENT" : "absent") (\(ThermikHelper.manualMarkerPath))")
        print("conflicting helpers: \(KnownFanControlHelpers.installed()) (known labels: \(KnownFanControlHelpers.all.map(\.label).joined(separator: ", ")))")

        // What HelperManager.refresh() decides for that app before any XPC (same rules as App/Helper/HelperManager.swift).
        guard let app = findApp(appPath) else { print("app:                 none found (pass a Thermik.app path)"); return }
        let appID = Bundle(url: app)?.executableURL.flatMap { CodeIdentity.ofCode(at: $0) }
        let helperPath = app.appending(path: "Contents/MacOS/\(ThermikHelper.helperExecutableName)").path
        let mode = (appID?.teamID?.isEmpty == false) ? "appService (Team ID \(appID?.teamID ?? ""))" : "legacy (ad-hoc, no Team ID)"
        print("app:                 \(app.path)")
        print("app identity:        \(appID.map(String.init(describing:)) ?? "unreadable")")
        print("HelperManager.mode:  \(mode)")
        print("bundled helper:      \(CodeIdentity.ofCode(at: URL(fileURLWithPath: helperPath)).map(String.init(describing:)) ?? "unreadable"), build \(LegacyHelperInstaller.installedHelperBuild(at: helperPath) ?? "?")")
        if appID?.teamID?.isEmpty == false {
            print("predicted state:     from SMAppService.daemon status (Team-ID build)")
        } else if !fm.fileExists(atPath: L.plistPath) {
            print("predicted state:     notInstalled (no \(L.plistPath))")
        } else if legacyStatus == .requiresApproval {
            print("predicted state:     requiresApproval (disabled in Login Items)")
        } else if let mine = appID?.cdhashHex, !(LegacyHelperInstaller.trustedClientCDHashes() ?? []).contains(mine) {
            print("predicted state:     needsUpgrade (this build's cdhash is not in the trust file: re-authorize)")
        } else {
            print("predicted state:     hello over XPC decides (ready / needsUpgrade / unreachable)")
        }
    }

    static func plan(appPath: String?) {
        guard let app = findApp(appPath) else {
            print("no Thermik.app found (pass its path, or run scripts/lib/build.sh Debug first)")
            return
        }
        do {
            let plan = try LegacyHelperInstaller.makePlan(appBundle: app)
            print("# app:                \(app.path)")
            print("# helper source:      \(plan.helperSource)")
            print("# helper requirement: \(plan.helperRequirement)")
            print("# trusted cdhashes:   \(plan.clientCDHashes.joined(separator: ", "))")
            print("# helper icon:        \(plan.helperIcon.map { "\($0.count)-byte resource fork" } ?? "none")")
            print("# NOT executed. The user may run it: sudo /bin/sh <this file>")
            print(try LegacyHelperInstaller.installScript(plan))
        } catch {
            print("makePlan(\(app.path)) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Self-test

private enum HelperSelfTest {
    nonisolated(unsafe) static var passed = 0   // probe main task only (sequential awaits)
    nonisolated(unsafe) static var failed = 0

    static func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1 }
        print(ok ? "PASS" : "FAIL", what)
    }

    static func codeString(_ e: any Error) -> String { let n = e as NSError; return "\(n.domain)#\(n.code)" }
    static func isHelperError(_ e: any Error, _ code: HelperErrorCode) -> Bool { (e as NSError).thermikHelperCode == code }

    /// Polls `condition` every 50 ms; returns the elapsed seconds, or nil on timeout.
    static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let start = ContinuousClock.now
        while true {
            if condition() { return seconds(ContinuousClock.now - start) }
            if seconds(ContinuousClock.now - start) > timeout { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func f1(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "nil" }

    static func run(appPath: String?) async {
        guard let me = CodeIdentity.ofSelf(), let myHash = me.cdhashHex else {
            print("FAIL cannot read this probe's code signature"); exit(1)
        }
        print("self: \(me)")
        let fm = FileManager.default
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("thermik-helper-selftest-\(getpid())")
        try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        let markerPath = work + "/manual-marker"
        defer { try? fm.removeItem(atPath: work) }
        print("work dir: \(work)")

        // In-process helper: mock fans, fast watchdog, marker in the work dir, no idle exit.
        let mock = MockFanController()
        var cfg = HelperService.Config()
        cfg.watchdogInterval = 0.2
        cfg.markerPath = markerPath
        cfg.idleExitSeconds = 10_000
        let service = HelperService(fans: mock, installKind: .development, config: cfg)
        service.start()

        // The probe is the client: pin its own cdhash + identifier. `swift build` debug binaries carry no hardened
        // runtime and DO carry get-task-allow, so the CS-status bits are relaxed to VALID and debuggable clients are
        // allowed — exactly what a DEBUG helper tolerates. The production validator is checked separately below.
        let ownID = me.identifier ?? "thermik-probe"
        let policy = PeerPolicy.pinnedCDHashes([myHash])
        let validator = PeerValidator(policy: policy, allowDebuggable: true, clientIdentifiers: [ownID], requiredStatus: [.valid])
        print("client requirement: \(validator.requirement ?? "nil")")
        let server = HelperXPCServer(service: service, validator: validator)
        let listener = NSXPCListener.anonymous()
        listener.delegate = server
        listener.activate()
        let box = EndpointBox(endpoint: listener.endpoint)
        let client = HelperConnection(factory: { NSXPCConnection(listenerEndpoint: box.endpoint) },
                                      helperRequirement: "identifier \"\(ownID)\"", timeout: .seconds(5))
        let interrupted = LockedFlag()
        client.onDisconnect = { invalidated in if !invalidated { interrupted.set() } }

        func ownedFans() -> Set<Int> { service.withController { $0.ownedFans } }
        func applied() -> [Int: Double] { service.withController { $0.appliedRPM } }
        func mockLog() -> [String] { service.withController { ($0 as? MockFanController)?.log ?? [] } }
        func setMock(_ body: @escaping (MockFanController) -> Void) { service.withController { if let m = $0 as? MockFanController { body(m) } } }
        func drainRateWindow() async { try? await Task.sleep(for: .milliseconds(1100)) }

        do {
            // 1. hello / version
            let info = try await client.hello()
            check(info.protocolVersion == ThermikHelper.protocolVersion && info.fanCount == 2 && info.installKind == .development,
                  "hello → protocol \(info.protocolVersion), \(info.fanCount) fans, \(info.scheme), kind \(info.installKind.rawValue), pid \(info.pid)")
            let s0 = try await client.state()
            check(s0.fans.count == 2 && !s0.isControlling && s0.fans.allSatisfy { $0.minRPM == 1350 && $0.maxRPM == 5777 },
                  "getState → \(s0.fans.map { "fan\($0.index) \(Int($0.minRPM))…\(Int($0.maxRPM))" }), controlling \(s0.isControlling)")

            // 2. clamp (I1) + marker (I7)
            let high = try await client.setFanTarget(0, rpm: 99_999, leaseSeconds: 5)
            check(high == 5777 && applied()[0] == 5777, "clamp 99999 → \(Int(high)) rpm")
            let low = try await client.setFanTarget(1, rpm: 10, leaseSeconds: 5)
            check(low == 1350, "clamp 10 → \(Int(low)) rpm")
            let markerData = fm.contents(atPath: markerPath)
            let decoded = markerData.flatMap { d -> RecoveryMarker? in
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                return try? dec.decode(RecoveryMarker.self, from: d)
            }
            check(decoded?.fans == [0, 1] && decoded?.pid == getpid(),
                  "marker written before control: \(markerData.map { String(decoding: $0, as: UTF8.self) } ?? "missing")")
            let leaseStart = ContinuousClock.now

            // 3. argument validation
            do { _ = try await client.setFanTarget(7, rpm: 2000, leaseSeconds: 5); check(false, "bad index accepted") }
            catch { check(isHelperError(error, .fanNotFound), "bad index 7 → \(codeString(error)) (fanNotFound)") }
            do { _ = try await client.setFanTarget(1, rpm: .nan, leaseSeconds: 5); check(false, "NaN accepted") }
            catch { check(isHelperError(error, .invalidArgument), "NaN rpm → \(codeString(error)) (invalidArgument)") }
            do { _ = try await client.setFanTarget(1, rpm: -5, leaseSeconds: 5); check(false, "negative rpm accepted") }
            catch { check(isHelperError(error, .invalidArgument), "negative rpm → \(codeString(error)) (invalidArgument)") }
            do { _ = try await client.renewLease(seconds: .infinity); check(false, "infinite lease accepted") }
            catch { check(isHelperError(error, .invalidArgument), "infinite lease → \(codeString(error)) (invalidArgument)") }

            // 4. lease expiry (I3): lease 5 s, nothing renewed since leaseStart.
            let restoredAfter = await waitUntil(8) { ownedFans().isEmpty }
            let leaseElapsed = seconds(ContinuousClock.now - leaseStart)
            check(restoredAfter != nil && leaseElapsed <= 5 + 1 && leaseElapsed >= 4.7,
                  "lease expiry restored System after \(f1(leaseElapsed)) s (lease 5 s, limit 6 s)")
            check(!fm.fileExists(atPath: markerPath), "marker removed after the full restore")
            let afterLease = try await client.state()
            check(afterLease.lastRevertReason == "leaseExpired" && afterLease.ftst == 0,
                  "revert reason \(afterLease.lastRevertReason ?? "nil"), Ftst \(afterLease.ftst.map(String.init) ?? "nil")")
            let renewAfter = try await client.renewLease(seconds: 10)
            check(renewAfter == false, "renewLease after revert → \(renewAfter) (app must re-send)")

            // 5. rate limit (I11)
            await drainRateWindow()
            var limited = 0, accepted = 0
            for _ in 0..<30 {
                do { _ = try await client.setFanTarget(1, rpm: 3000, leaseSeconds: 10); accepted += 1 }
                catch { if isHelperError(error, .rateLimited) { limited += 1 } }
            }
            check(limited > 0 && accepted <= ThermikHelper.Limits.maxCommandsPerSecond,
                  "rate limit tripped: \(accepted) accepted, \(limited) rejected with rateLimited (limit \(ThermikHelper.Limits.maxCommandsPerSecond)/s)")
            try await client.resetAllFans()
            check(ownedFans().isEmpty, "resetAllFans → System")

            // 6. foreign controller (I10)
            await drainRateWindow()
            setMock { $0.simulatedForeignControl = true }
            do { _ = try await client.setFanTarget(0, rpm: 2000, leaseSeconds: 10); check(false, "took over a foreign-controlled fan") }
            catch { check(isHelperError(error, .foreignController), "foreign controller (mock flag) → \(codeString(error)) (foreignController)") }
            let sForeign = try await client.state()
            check(sForeign.foreignControllerSuspected && !sForeign.isControlling && mockLog().last?.hasPrefix("manual") != true,
                  "getState reports foreignControllerSuspected, fans untouched")
            setMock { $0.simulatedForeignControl = false }

            // 7. thermal override (I8)
            _ = try await client.setFanTarget(0, rpm: 2000, leaseSeconds: 10)
            setMock { $0.simulatedHottestC = 110 }
            let overrideAfter = await waitUntil(2) { service.stateSnapshot().safetyOverrideActive }
            let a = applied()
            check(overrideAfter != nil && a[0] == 5777 && a[1] == 5777 && ownedFans() == [0, 1],
                  "override (mock 110 °C) engaged after \(f1(overrideAfter)) s: fans at \(a.sorted { $0.key < $1.key }.map { Int($0.value) })")
            do {
                _ = try await client.setFanTarget(0, rpm: 2500, leaseSeconds: 10)
                check(false, "lower target accepted during override")
            } catch {
                check(isHelperError(error, .safetyOverride) && applied()[0] == 5777,
                      "lower target during override → \(codeString(error)) (safetyOverride), fan 0 stays 5777")
            }
            setMock { $0.simulatedHottestC = 60 }
            let releasedAfter = await waitUntil(2) { !service.stateSnapshot().safetyOverrideActive }
            let held = applied()
            check(releasedAfter != nil && held[0] == 5777 && held[1] == 5777,
                  "override released after \(f1(releasedAfter)) s: both fans hold maximum (no dip to an older request)")
            let holdEndedAfter = await waitUntil(8) { applied()[0] == 2500 && ownedFans() == [0] }
            check(holdEndedAfter != nil,
                  "…after the 5 s hold (\(f1(holdEndedAfter)) s): fan 0 → last request 2500 rpm, fan 1 back to System")
            try await client.resetAllFans()

            // 7b. fan stop: 0 rpm accepted when cool, a hot die restarts the stopped fan, and stop is refused while hot
            await drainRateWindow()
            _ = try await client.setFanTarget(0, rpm: 2000, leaseSeconds: 10)
            try? await Task.sleep(for: .milliseconds(1300))                                   // one watchdog reading
            let stopped = try await client.setFanTarget(0, rpm: 0, leaseSeconds: 10)
            check(stopped == 0 && applied()[0] == 0, "rpm 0 stops fan 0 at 60 °C (applied \(Int(stopped)) rpm)")
            setMock { $0.simulatedHottestC = 96 }
            let restartAfter = await waitUntil(3) { (applied()[0] ?? 0) >= 1350 }
            check(restartAfter != nil, "stopped fan restarted at its minimum by the watchdog at 96 °C after \(f1(restartAfter)) s")
            let refused = try await client.setFanTarget(0, rpm: 0, leaseSeconds: 10)
            check(refused >= 1350, "stop held at the minimum at 96 °C: fan 0 runs at \(Int(refused)) rpm")
            setMock { $0.simulatedHottestC = 80 }
            let resumedAfter = await waitUntil(3) { applied()[0] == 0 }
            check(resumedAfter != nil, "…and stopped again by the watchdog once the die is at 80 °C (\(f1(resumedAfter)) s), no resend needed")
            setMock { $0.simulatedHottestC = nil }
            let noReadingAfter = await waitUntil(3) { (applied()[0] ?? 0) >= 1350 || ownedFans().isEmpty }
            check(noReadingAfter != nil, "no readable die: a stopped fan never stays at 0 rpm (\(f1(noReadingAfter)) s)")
            setMock { $0.simulatedHottestC = 60 }
            try await client.resetAllFans()

            // 8. sensor failure (I9)
            _ = try await client.setFanTarget(0, rpm: 2000, leaseSeconds: 10)
            setMock { $0.simulatedHottestC = nil }
            let failAfter = await waitUntil(2) { ownedFans().isEmpty }
            check(failAfter != nil && service.stateSnapshot().lastRevertReason == "sensorFailure",
                  "no readable die sensor → System after \(f1(failAfter)) s (reason \(service.stateSnapshot().lastRevertReason ?? "nil"))")
            setMock { $0.simulatedHottestC = 60 }

            // 9. sleep / wake (I6)
            await drainRateWindow()
            _ = try await client.setFanTarget(1, rpm: 2200, leaseSeconds: 10)
            service.systemWillSleep()
            let asleep = service.stateSnapshot()
            check(ownedFans().isEmpty && asleep.sleeping && asleep.lastRevertReason == "sleep", "systemWillSleep → System before the sleep ack, sleeping flag set")
            do { _ = try await client.setFanTarget(1, rpm: 2200, leaseSeconds: 10); check(false, "command accepted while asleep") }
            catch { check(isHelperError(error, .sleeping), "setFanTarget while asleep → \(codeString(error)) (sleeping)") }
            service.systemDidWake()
            let woke = try await client.setFanTarget(1, rpm: 2200, leaseSeconds: 10)
            check(woke == 2200 && !service.stateSnapshot().sleeping, "after systemDidWake commands are accepted again")

            // 10. single-fan release; the last owned fan triggers the full restore (Ftst cleared)
            _ = try await client.setFanTarget(0, rpm: 3000, leaseSeconds: 10)
            try await client.setFanAutomatic(1)
            check(ownedFans() == [0], "setFanAutomatic(1) → only fan 0 still manual")
            try await client.setFanAutomatic(0)
            let released = try await client.state()
            check(!released.isControlling && !released.ftstSetByThermik && !fm.fileExists(atPath: markerPath),
                  "releasing the last fan → full restore, Ftst cleared, marker removed")
            let still = try await client.renewLease(seconds: 10)
            check(!still, "renewLease when nothing is controlled → false")

            // 10b. applicationWillTerminate path: bounded synchronous reset
            _ = try await client.setFanTarget(0, rpm: 2400, leaseSeconds: 10)
            let blockingStart = ContinuousClock.now
            client.resetAllFansBlocking(timeout: 2)
            check(ownedFans().isEmpty && seconds(ContinuousClock.now - blockingStart) < 1,
                  "resetAllFansBlocking(timeout: 2) → System in \(String(format: "%.0f", seconds(ContinuousClock.now - blockingStart) * 1000)) ms")
            let never = HelperConnection(factory: { NSXPCConnection(listenerEndpoint: box.endpoint) }, helperRequirement: nil)
            let neverStart = ContinuousClock.now
            never.resetAllFansBlocking(timeout: 2)
            check(seconds(ContinuousClock.now - neverStart) < 0.05, "resetAllFansBlocking without a connection returns at once (does not launch the helper)")

            // 10c. client-side reply timeout: the helper's state queue is busy for 1.5 s, the client waits 0.5 s.
            let slow = HelperConnection(factory: { NSXPCConnection(listenerEndpoint: box.endpoint) },
                                        helperRequirement: "identifier \"\(ownID)\"", timeout: .milliseconds(500))
            _ = try await slow.hello()
            DispatchQueue.global().async { service.withController { _ in Thread.sleep(forTimeInterval: 1.5) } }
            try? await Task.sleep(for: .milliseconds(50))
            let timeoutStart = ContinuousClock.now
            do { _ = try await slow.hello(); check(false, "a blocked helper replied") }
            catch {
                let waited = seconds(ContinuousClock.now - timeoutStart)
                check((error as NSError).code == NSXPCConnectionReplyInvalid && waited >= 0.4 && waited < 1.2,
                      "reply timeout → \(codeString(error)) after \(String(format: "%.2f", waited)) s (timeout 0.5 s)")
            }
            slow.reset()
            try? await Task.sleep(for: .milliseconds(1500))   // let the busy block finish

            // 11. client disconnect (I4): restore after the 3 s grace, not before.
            await drainRateWindow()
            _ = try await client.setFanTarget(1, rpm: 2500, leaseSeconds: 30)
            client.reset()                                   // the app quits / crashes
            let goneAt = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(1500))
            check(ownedFans() == [1], "1.5 s after the client vanished: still manual (grace period)")
            let goneAfter = await waitUntil(4) { ownedFans().isEmpty }
            let goneElapsed = seconds(ContinuousClock.now - goneAt)
            check(goneAfter != nil && goneElapsed >= 2.9 && goneElapsed <= 4.0 && service.stateSnapshot().lastRevertReason == "clientGone",
                  "client disconnect → System after \(f1(goneElapsed)) s (reason \(service.stateSnapshot().lastRevertReason ?? "nil"))")

            // 12. protocol mismatch, straight through a raw proxy
            let raw = NSXPCConnection(listenerEndpoint: box.endpoint)
            raw.remoteObjectInterface = HelperWire.makeInterface()
            raw.activate()
            let mismatch: String = await withCheckedContinuation { cont in
                let once = LockedFlag()
                let resume: @Sendable (String) -> Void = { s in
                    if !once.isSet { once.set(); cont.resume(returning: s) }
                }
                guard let p = raw.remoteObjectProxyWithErrorHandler({ e in resume("xpc \(codeString(e))") }) as? any ThermikHelperXPC else {
                    resume("bad proxy"); return
                }
                p.hello(clientProtocolVersion: 999) { _, e in resume(e.map { codeString($0) } ?? "no error") }
            }
            check(mismatch == "\(ThermikHelper.errorDomain)#\(HelperErrorCode.unsupportedProtocol.rawValue)",
                  "protocol mismatch (999) → \(mismatch) (unsupportedProtocol)")
            raw.invalidate()

            // 13. self-uninstall only exists for legacy installs
            do { try await client.uninstallLegacyHelper(); check(false, "uninstall accepted on a development helper") }
            catch { check(isHelperError(error, .notPermitted), "uninstallLegacyHelper (development kind) → \(codeString(error)) (notPermitted)") }
        } catch {
            check(false, "unexpected error \(codeString(error)): \(error.localizedDescription)")
        }

        // 14. peer validation (I12)
        await peerChecks(service: service, myHash: myHash, ownID: ownID, box: box)

        // 15. crash recovery at start, and no touching without a marker (I7)
        recoveryChecks(work: work)
        await stoppedFanRecoveryChecks(work: work)

        // 16. idle exit (I13)
        await idleCheck()

        // 17. shutdown on signal (I5) — terminal for this service instance
        do {
            _ = try await client.setFanTarget(0, rpm: 2600, leaseSeconds: 10)
            service.shutdown(reason: "signal 15")
            let s = service.stateSnapshot()
            check(ownedFans().isEmpty && s.lastRevertReason == "signal 15", "shutdown(reason: \"signal 15\") → System synchronously")
            do { _ = try await client.setFanTarget(0, rpm: 2600, leaseSeconds: 10); check(false, "command accepted after shutdown") }
            catch { check(isHelperError(error, .internalError), "command after shutdown → \(codeString(error)) (internalError)") }
        } catch {
            check(false, "shutdown check: \(codeString(error))")
        }
        client.reset()

        // 18. legacy installer artefacts (generated, linted, never executed)
        legacyScriptChecks(appPath: appPath, work: work, me: me)

        // 19. conflicting fan-control helpers (plist presence only) and install-kind detection
        let conflicts = KnownFanControlHelpers.installed()
        let tgProPlist = fm.fileExists(atPath: "/Library/LaunchDaemons/com.tunabellysoftware.TGFanHelper.plist")
        check((conflicts.contains("TG Pro") == tgProPlist) && !conflicts.contains { $0.localizedCaseInsensitiveContains("aldente") },
              "conflictingHelpers → \(conflicts) (TG Pro plist \(tgProPlist ? "present" : "absent"); battery limiters such as AlDente are never listed)")
        let kinds = [HelperRuntime.detectInstallKind(executablePath: ThermikHelper.Legacy.helperPath),
                     HelperRuntime.detectInstallKind(executablePath: "/Applications/Thermik.app/Contents/MacOS/thermik-helper"),
                     HelperRuntime.detectInstallKind(executablePath: "/tmp/build/thermik-helper")]
        check(kinds == [.legacy, .appService, .development], "detectInstallKind → \(kinds.map(\.rawValue))")

        print("mock log (last 6): \(mockLog().suffix(6))")
        print("helper selftest: \(passed)/\(passed + failed) PASS")
        if failed > 0 { exit(1) }
    }

    // MARK: Peer validation

    static func peerChecks(service: HelperService, myHash: String, ownID: String, box: EndpointBox) async {
        /// Starts a throw-away server with `validator` and tries `hello` through a fresh client.
        func attempt(_ validator: PeerValidator, helperRequirement: String? = nil) async -> String {
            let server = HelperXPCServer(service: service, validator: validator)
            let l = NSXPCListener.anonymous()
            l.delegate = server
            l.activate()
            let b = EndpointBox(endpoint: l.endpoint)
            let c = HelperConnection(factory: { NSXPCConnection(listenerEndpoint: b.endpoint) }, helperRequirement: helperRequirement, timeout: .seconds(3))
            defer { c.reset(); l.invalidate() }
            do { _ = try await c.hello(); return "accepted" }
            catch { return codeString(error) }
        }

        let wrongHash = await attempt(PeerValidator(policy: .pinnedCDHashes([String(repeating: "0", count: 40)]), allowDebuggable: true,
                                                    clientIdentifiers: [ownID], requiredStatus: [.valid]))
        check(wrongHash == "\(NSCocoaErrorDomain)#4097", "wrong-cdhash client rejected → \(wrongHash)")

        let production = PeerValidator(policy: .pinnedCDHashes([myHash]), allowDebuggable: false)   // app identifier + valid|hard|kill|runtime
        let strict = await attempt(production)
        check(strict != "accepted", "production validator rejects this probe (identifier \(ownID), no hardened runtime) → \(strict)")

        let deny = await attempt(PeerValidator(policy: .denyAll(reason: "selftest"), allowDebuggable: true, clientIdentifiers: [ownID], requiredStatus: [.valid]))
        check(deny != "accepted", "denyAll policy rejects every client → \(deny)")

        let wrongHelper = await attempt(PeerValidator(policy: .pinnedCDHashes([myHash]), allowDebuggable: true, clientIdentifiers: [ownID], requiredStatus: [.valid]),
                                        helperRequirement: "identifier \"\(ThermikHelper.helperSigningIdentifier)\"")
        check(wrongHelper == "\(NSCocoaErrorDomain)#4102" || wrongHelper.hasPrefix(NSCocoaErrorDomain),
              "client-side requirement on the helper (identifier \(ThermikHelper.helperSigningIdentifier)) fails → \(wrongHelper)")

        let appServicePolicy = PeerValidator.makePolicy(installKind: .appService)
        check(appServicePolicy == .denyAll(reason: "ad-hoc helper registered via SMAppService is unsupported"),
              "ad-hoc + appService policy → \(appServicePolicy)")
        let noTrust = PeerValidator.makePolicy(installKind: .legacy, trustFile: "/nonexistent/trusted-clients.plist")
        if case .denyAll = noTrust { check(true, "ad-hoc + legacy without a trust file → \(noTrust)") }
        else { check(false, "ad-hoc + legacy without a trust file → \(noTrust)") }

        // A trust file the user can write (not root-owned) must be ignored.
        let userTrust = NSTemporaryDirectory() + "thermik-selftest-trust-\(getpid()).plist"
        if let data = try? LegacyHelperInstaller.trustFile([myHash]) {
            FileManager.default.createFile(atPath: userTrust, contents: data)
            let read = PeerValidator.readTrustFile(userTrust)
            check(read.isEmpty && LegacyHelperInstaller.trustedClientCDHashes(at: userTrust) == [myHash],
                  "user-owned trust file is parsed but NOT trusted by the helper (owner must be root)")
            try? FileManager.default.removeItem(atPath: userTrust)
        }
        let req = PeerPolicy.sameTeam(teamID: "ABCDE12345").requirement(allowDebuggable: false) ?? "nil"
        check(req == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and (identifier \"\(ThermikHelper.appBundleIdentifier)\") and !(entitlement[\"com.apple.security.get-task-allow\"] /* exists */)",
              "Team-ID requirement (Release): \(req)")
    }

    // MARK: Recovery

    static func recoveryChecks(work: String) {
        let path = work + "/recovery-marker"
        let store = RecoveryMarkerStore(path: path)
        var cfg = HelperService.Config()
        cfg.markerPath = path
        cfg.idleExitSeconds = 10_000
        do {
            try store.write(RecoveryMarker(pid: 4242, ftstSetByUs: true, fans: [0, 1], createdAt: Date()))
            let crashed = HelperService(fans: MockFanController(), installKind: .development, config: cfg)
            crashed.start()
            let log = crashed.withController { ($0 as? MockFanController)?.log ?? [] }
            let s = crashed.stateSnapshot()
            check(log.contains("restoreAll(force: true, reason: startupRecovery)") && !store.exists && s.lastRevertReason == "startupRecovery",
                  "marker at start (crashed pid 4242) → restoreAll(force: true), marker removed")
            crashed.shutdown(reason: "selftest")
        } catch {
            check(false, "cannot write a test marker: \(error.localizedDescription)")
        }
        let clean = HelperService(fans: MockFanController(), installKind: .development, config: cfg)
        clean.start()
        let cleanLog = clean.withController { ($0 as? MockFanController)?.log ?? [] }
        check(cleanLog.isEmpty, "no marker at start → the fans are not touched (log \(cleanLog))")
        clean.shutdown(reason: "selftest")
    }

    /// 15b. M4 Max, 2026-10-27: a restore of STOPPED fans was refused (0x82 on F%dMd=0), the helper restarted, and its
    /// next plain revert skipped the fans it did not own, reported success and dropped the marker: both fans stayed
    /// manual at 0 rpm and the app blamed another fan-control app. Real SMCFanController on a FakeSMC that models it.
    static func stoppedFanRecoveryChecks(work: String) async {
        let path = work + "/stopped-marker"
        let store = RecoveryMarkerStore(path: path)
        let clock = SimulatedClock()
        let smc = FakeSMC(.m1Direct, clock: clock)
        smc.refusesReleaseWhileStopped = true
        smc.spinUpDelay = 3_600                                  // at first the fans do not turn again in time
        for i in 0..<2 {
            try? smc.writeRaw(.fan("F%dMd", i), [1])
            try? smc.writeRaw(.fan("F%dTg", i), SMCCodec.encodeFloat32LE(0))
        }
        let fans = SMCFanController(device: smc, appleSilicon: true, clock: clock, log: { _ in })
        fans.markerPath = path
        var cfg = HelperService.Config()
        cfg.markerPath = path
        cfg.watchdogInterval = 0.1
        cfg.idleExitSeconds = 10_000
        do { try store.write(RecoveryMarker(pid: 4243, ftstSetByUs: true, fans: [0, 1], createdAt: Date())) } catch {
            check(false, "cannot write a test marker: \(error.localizedDescription)")
            return
        }
        let service = HelperService(fans: fans, installKind: .development, config: cfg)
        func modes() -> [UInt8?] { service.withController { _ in [smc.bytes("F0Md")?.first, smc.bytes("F1Md")?.first] } }
        service.start()
        check(store.exists && modes() == [1, 1] && !service.stateSnapshot().foreignControllerSuspected,
              "stopped fans that refuse the release at start: marker kept, not reported as another app")
        service.systemWillSleep()                                // a plain revert, like a lease running out
        check(store.exists && modes() == [1, 1], "a later non-forced revert keeps the marker while the fans are still manual")
        service.systemDidWake()
        service.withController { _ in smc.spinUpDelay = 1 }      // the fans turn again a second after a target
        let after = await waitUntil(15) { !store.exists }
        check(after != nil && modes() == [0, 0] && !service.stateSnapshot().foreignControllerSuspected,
              "the next revert spins the stopped fans up and hands them back to macOS (after \(f1(after)) s)")
        service.shutdown(reason: "selftest")
    }

    static func idleCheck() async {
        var cfg = HelperService.Config()
        cfg.watchdogInterval = 0.1
        cfg.idleExitSeconds = 0.5
        cfg.markerPath = nil
        let idle = HelperService(fans: MockFanController(), installKind: .development, config: cfg)
        let fired = LockedFlag()
        idle.onIdleExit = { fired.set() }
        idle.start()
        let after = await waitUntil(2) { fired.isSet }
        check(after != nil, "idle exit fires with no clients and no manual fans (after \(f1(after)) s at a 0.5 s setting)")
        idle.shutdown(reason: "selftest")
    }

    // MARK: Legacy installer

    static func legacyScriptChecks(appPath: String?, work: String, me: CodeIdentity) {
        let plan: LegacyHelperInstaller.Plan
        if let app = HelperProbeTools.findApp(appPath) {
            do {
                plan = try LegacyHelperInstaller.makePlan(appBundle: app)
                check(true, "makePlan(\(app.lastPathComponent)): helper \(plan.helperRequirement); trusted \(plan.clientCDHashes)")
                check(plan.helperIcon != nil, "makePlan: helper icon from the app's .icns (\(plan.helperIcon?.count ?? 0)-byte resource fork)")
            } catch {
                check(false, "makePlan(\(app.path)): \(error.localizedDescription)")
                return
            }
        } else {
            // No app bundle built: a synthetic plan over this probe's own binary still exercises generation + lint.
            let exe = HelperRuntime.executablePath
            plan = LegacyHelperInstaller.Plan(helperSource: exe, helperRequirement: "cdhash H\"\(me.cdhashHex ?? "")\"",
                                              clientCDHashes: [me.cdhashHex ?? ""])
            print("note: no Thermik.app found (run scripts/lib/build.sh Debug); using a synthetic plan over \(exe)")
        }
        do {
            let install = work + "/generated-install.sh", uninstall = work + "/generated-uninstall.sh"
            let plistPath = work + "/generated-launchd.plist", trustPath = work + "/generated-trust.plist"
            try LegacyHelperInstaller.installScript(plan).write(toFile: install, atomically: true, encoding: .utf8)
            try LegacyHelperInstaller.uninstallScript().write(toFile: uninstall, atomically: true, encoding: .utf8)
            try LegacyHelperInstaller.launchdPlist().write(to: URL(fileURLWithPath: plistPath))
            try LegacyHelperInstaller.trustFile(plan.clientCDHashes).write(to: URL(fileURLWithPath: trustPath))
            let shInstall = HelperProbeTools.run("/bin/sh", ["-n", install])
            let shUninstall = HelperProbeTools.run("/bin/sh", ["-n", uninstall])
            check(shInstall.status == 0 && shUninstall.status == 0, "legacy scripts generated: sh -n install OK, sh -n uninstall OK")
            let lint = HelperProbeTools.run("/usr/bin/plutil", ["-lint", plistPath, trustPath])
            check(lint.status == 0, "plutil -lint: \(lint.output.replacingOccurrences(of: work + "/", with: ""))")
            let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)), format: nil)) as? [String: Any]
            let keepAlive = plist?["KeepAlive"] as? [String: Bool]
            check(plist?["Label"] as? String == ThermikHelper.label && plist?["Program"] as? String == ThermikHelper.Legacy.helperPath
                    && (plist?["MachServices"] as? [String: Bool])?[ThermikHelper.machServiceName] == true && keepAlive?["SuccessfulExit"] == false,
                  "launchd plist: Label, Program=\(ThermikHelper.Legacy.helperPath), MachServices, KeepAlive{SuccessfulExit=false}")
            let verify = HelperProbeTools.run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=" + plan.helperRequirement, plan.helperSource])
            check(verify.status == 0, "codesign --verify --strict -R '=<plan requirement>' on the bundled helper → exit \(verify.status)\(verify.output.isEmpty ? "" : ": " + verify.output)")
            let script = try LegacyHelperInstaller.installScript(plan)
            let verifyAt = script.range(of: "/usr/bin/codesign --verify --strict -R")?.lowerBound
            let activateAt = script.range(of: "/bin/mv -f \"$T\" \"$DST\"")?.lowerBound
            let bootstrapAt = script.range(of: "/bin/launchctl bootstrap system")?.lowerBound
            check(verifyAt != nil && activateAt != nil && bootstrapAt != nil && verifyAt! < activateAt! && activateAt! < bootstrapAt!,
                  "install script verifies the root-owned copy before activating it (\(script.count) bytes, base64 \(Data(script.utf8).base64EncodedString().count) bytes)")
            if plan.helperIcon != nil {
                // `codesign --verify --strict` rejects a resource fork: the icon goes on only after the verification.
                let iconAt = script.range(of: "\"$T/..namedfork/rsrc\"")?.lowerBound
                check(iconAt != nil && verifyAt != nil && activateAt != nil && verifyAt! < iconAt! && iconAt! < activateAt!,
                      "install script sets the helper icon between verification and activation")
            }
        } catch {
            check(false, "legacy script generation: \(error.localizedDescription)")
        }
    }
}
