// main.swift — Thermik privileged helper (root LaunchDaemon `app.thermik.helper`).
// Wiring only, in the order of SPEC §2.6.5; the logic lives in ThermikHelperCore.
//   thermik-helper          real mode: must be root (launchd), drives the SMC through SMCFanController
//   thermik-helper --mock   foreground developer run without root: MockFanController, never touches the SMC
//   thermik-helper --peer-requirement <Thermik.app>
//                           build-time self-check (scripts/lib/build.sh), no root, touches nothing: prints the client
//                           requirement THIS binary would enforce once the legacy installer pinned that app
// Logs: log stream --predicate 'subsystem == "app.thermik.helper"' --info
import Foundation
import ThermikHelperCore
import ThermikHelperShared
import ThermikSMC
import ThermikSMCWriter

/// Build-time options of this helper binary.
enum HelperBuild {
    /// Debuggable clients (get-task-allow, or a debugger attached) are refused in EVERY configuration unless the
    /// developer opted in with THERMIK_DEBUGGABLE = YES (Debug only, Config/Debug.xcconfig), which also makes the
    /// app debuggable. A plain Debug build is not enough: this binary is what gets installed as root, and accepting
    /// a debuggable client lets any same-user process attach to Thermik (Developer Mode) and drive the fans.
    static let allowDebuggableClients: Bool = {
        #if THERMIK_ALLOW_DEBUGGABLE_CLIENTS
        return true
        #else
        return false
        #endif
    }()
}

private func runRealHelper() -> Never {
    requireRoot()
    let installKind = HelperRuntime.detectInstallKind()
    let service = HelperService(fans: makeRealFans(), installKind: installKind, config: HelperService.Config())
    // I13: exit 0 → KeepAlive{SuccessfulExit=false} does not relaunch; the next Mach lookup does.
    service.onIdleExit = { exit(0) }
    start(service)
    serve(service, installKind: installKind, announce: logRealStartup)
}

private func runMockHelper() -> Never {
    let installKind = HelperRuntime.detectInstallKind()
    let fans: FanControlling = MockFanController()
    var config = HelperService.Config()
    config.markerPath = HelperRuntime.mockMarkerPath
    let service = HelperService(fans: fans, installKind: installKind, config: config)
    // No idle exit: a hand-started --mock has nobody to relaunch it, so it stays up until Ctrl-C.
    start(service)
    serve(service, installKind: installKind, announce: logMockStartup)
}

// 1. Root for the real daemon (EX_NOPERM; KeepAlive retries, throttled by launchd).
private func requireRoot() {
    guard geteuid() != 0 else { return }
    FileHandle.standardError.write(Data("thermik-helper must run as root (launchd daemon); use --mock for a dry run\n".utf8))
    exit(HelperRuntime.notRootExitCode)
}

// 3. Without an SMC the helper still answers (no fans, every write refused) instead of crash-looping.
private func makeRealFans() -> FanControlling {
    do { return SMCFanController(smc: try SMCConnection()) }
    catch {
        HelperRuntime.log.error("cannot open the SMC: \(String(describing: error), privacy: .public); fan control unavailable")
        return UnavailableFanController()
    }
}

// 4. Service + crash recovery (I7: restore only if the per-boot marker exists).
private func start(_ service: HelperService) {
    service.start()
    guard service.needsFanRediscovery else { return }
    // Min-only Intel after a crash: the originals are back now; exit before the listener is up so the next
    // launchd connection rediscovers the real minimums.
    HelperRuntime.log.notice("original fan minimums restored: exiting so that the next launch rediscovers the fans")
    exit(0)
}

private func serve(_ service: HelperService, installKind: HelperInstallKind,
                   announce: (HelperInstallKind, PeerPolicy) -> Void) -> Never {
    // 5. Peer policy from the helper's own signature (I12).
    let policy = PeerValidator.makePolicy(installKind: installKind)
    let validator = PeerValidator(policy: policy, allowDebuggable: HelperBuild.allowDebuggableClients)
    announce(installKind, policy)
    let signalSources = observeSignals(service)
    let power = observePower(service)
    let server = makeServer(service: service, validator: validator, installKind: installKind)
    let listener = makeListener(server: server)
    // 10. Serve forever; keep the sources, observer, weakly-held delegate and listener alive.
    withExtendedLifetime((signalSources, power, server, listener)) { dispatchMain() }
}

private func logRealStartup(installKind: HelperInstallKind, policy: PeerPolicy) {
    let version = HelperRuntime.version
    HelperRuntime.log.notice("""
        thermik-helper \(version.short, privacy: .public) (\(version.build, privacy: .public)) pid \(getpid(), privacy: .public) \
        kind \(installKind.rawValue, privacy: .public) policy \(policy.description, privacy: .public)
        """)
    if HelperBuild.allowDebuggableClients {
        HelperRuntime.log.warning("developer build (THERMIK_DEBUGGABLE): debuggable clients are accepted; reinstall a normal build when done")
    }
}

private func logMockStartup(installKind: HelperInstallKind, policy: PeerPolicy) {
    let version = HelperRuntime.version
    HelperRuntime.log.notice("""
        thermik-helper \(version.short, privacy: .public) (\(version.build, privacy: .public)) pid \(getpid(), privacy: .public) \
        kind \(installKind.rawValue, privacy: .public) MOCK policy \(policy.description, privacy: .public)
        """)
    if HelperBuild.allowDebuggableClients {
        HelperRuntime.log.warning("developer build (THERMIK_DEBUGGABLE): debuggable clients are accepted; reinstall a normal build when done")
    }
    print("thermik-helper --mock: pid \(getpid()), policy \(policy.description); Ctrl-C to stop")
}

// 6. SIGTERM (launchd stop, bootout, unregister, shutdown) / SIGINT / SIGHUP → restore, exit 0 (I5).
private func observeSignals(_ service: HelperService) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        sources.append(makeSignalSource(signal: sig, service: service))
    }
    return sources
}

private func makeSignalSource(signal sig: Int32, service: HelperService) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        service.shutdown(reason: "signal \(sig)")
        HelperRuntime.log.notice("exiting on signal \(sig, privacy: .public)")
        exit(0)
    }
    source.resume()
    return source
}

// 7. Sleep / wake (I6): restore before the sleep is acknowledged.
private func observePower(_ service: HelperService) -> PowerObserver {
    let power = PowerObserver()
    power.onWillSleep = { service.systemWillSleep() }
    power.onDidWake = { service.systemDidWake() }
    power.start()
    return power
}

// 8. Legacy self-uninstall hook (nil for other install kinds).
private func makeServer(service: HelperService, validator: PeerValidator,
                        installKind: HelperInstallKind) -> HelperXPCServer {
    HelperXPCServer(service: service, validator: validator,
                    uninstallHandler: LegacyUninstall.makeHandler(installKind: installKind, service: service))
}

// 9. Only launchd can publish the Mach service; a hand-started --mock simply receives no connections.
private func makeListener(server: HelperXPCServer) -> NSXPCListener {
    let listener = NSXPCListener(machServiceName: ThermikHelper.machServiceName)
    listener.delegate = server
    listener.activate()
    return listener
}

/// Prints the requirement this helper binary would put on its client once the legacy installer pinned `appPath`'s
/// cdhashes (every slice, `CodeIdentity.cdhashes` as in `LegacyHelperInstaller.makePlan`), then exits: 0 printed,
/// 1 no requirement (deny all). scripts/lib/build.sh feeds it to `codesign --verify -R` for every slice of the built
/// app, so a build whose app this helper would reject (e.g. a get-task-allow entitlement the helper forbids) fails
/// at build time, not at runtime.
func printPeerRequirement(appPath: String?) -> Never {
    guard let appPath else { peerRequirementFailure("usage: thermik-helper --peer-requirement <Thermik.app>", 64) }
    let app = URL(fileURLWithPath: appPath)
    let name = executableName(app: app, appPath: appPath)
    let clientHashes = CodeIdentity.cdhashes(ofCodeAt: app.appending(path: "Contents/MacOS/\(name)"))
    guard !clientHashes.isEmpty else { peerRequirementFailure("cannot read the code signature of \(appPath)") }
    let policy = PeerValidator.makePolicy(installKind: .legacy, trustedCDHashes: clientHashes)
    let requirement = clientRequirement(policy: policy)
    print(requirement)
    exit(0)
}

private func clientRequirement(policy: PeerPolicy) -> String {
    guard let requirement = policy.requirement(allowDebuggable: HelperBuild.allowDebuggableClients) else {
        peerRequirementFailure("no client requirement: policy \(policy.description)")
    }
    return requirement
}

// Not `Bundle(url:)`: this binary lives in Contents/MacOS of that very bundle, so Foundation hands back Bundle.main.
private func executableName(app: URL, appPath: String) -> String {
    guard let data = FileManager.default.contents(atPath: app.appending(path: "Contents/Info.plist").path),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else {
        peerRequirementFailure("not an app bundle: \(appPath)")
    }
    return name
}

private func peerRequirementFailure(_ message: String, _ status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--peer-requirement") {
    printPeerRequirement(appPath: arguments.dropFirst(flag + 1).first)
}
if arguments.contains("--mock") { runMockHelper() }
runRealHelper()
