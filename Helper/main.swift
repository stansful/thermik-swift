// main.swift — Thermik privileged helper (root LaunchDaemon `app.thermik.helper`). OWNER: Unit 4.
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

func runHelper(mock: Bool) -> Never {
    let log = HelperRuntime.log

    // 1. Root unless --mock (EX_NOPERM; KeepAlive retries, throttled by launchd).
    guard geteuid() == 0 || mock else {
        FileHandle.standardError.write(Data("thermik-helper must run as root (launchd daemon); use --mock for a dry run\n".utf8))
        exit(HelperRuntime.notRootExitCode)
    }

    // 2. Install kind from the executable's location.
    let installKind = HelperRuntime.detectInstallKind()

    // 3. Fan backend. Without an SMC the helper still answers (no fans, every write refused) instead of crash-looping.
    let fans: FanControlling
    if mock {
        fans = MockFanController()
    } else {
        do {
            fans = SMCFanController(smc: try SMCConnection())
        } catch {
            log.error("cannot open the SMC: \(String(describing: error), privacy: .public); fan control unavailable")
            fans = UnavailableFanController()
        }
    }

    // 4. Service + crash recovery (I7: restore only if the per-boot marker exists).
    var config = HelperService.Config()
    if mock { config.markerPath = HelperRuntime.mockMarkerPath }
    let service = HelperService(fans: fans, installKind: installKind, config: config)
    if !mock {
        // I13: exit 0 → KeepAlive{SuccessfulExit=false} does not relaunch; the next Mach lookup does. A hand-started
        // --mock run has nobody to relaunch it, so it stays up until Ctrl-C.
        service.onIdleExit = { exit(0) }
    }
    service.start()
    if service.needsFanRediscovery {
        // Min-only Intel after a crash: the profile was discovered while the dead instance's raised F%dMn was still
        // in place. The originals are back now; exit 0 like the idle exit (before the listener is up), and launchd
        // relaunches on the next connection with a discovery that sees the real minimums.
        log.notice("original fan minimums restored: exiting so that the next launch rediscovers the fans")
        exit(0)
    }

    // 5. Peer policy from the helper's own signature (I12).
    let policy = PeerValidator.makePolicy(installKind: installKind)
    let validator = PeerValidator(policy: policy, allowDebuggable: HelperBuild.allowDebuggableClients)

    let version = HelperRuntime.version
    log.notice("""
        thermik-helper \(version.short, privacy: .public) (\(version.build, privacy: .public)) pid \(getpid(), privacy: .public) \
        kind \(installKind.rawValue, privacy: .public)\(mock ? " MOCK" : "", privacy: .public) \
        policy \(policy.description, privacy: .public)
        """)
    if HelperBuild.allowDebuggableClients {
        log.warning("developer build (THERMIK_DEBUGGABLE): debuggable clients are accepted; reinstall a normal build when done")
    }
    if mock { print("thermik-helper --mock: pid \(getpid()), policy \(policy.description); Ctrl-C to stop") }

    // 6. SIGTERM (launchd stop, bootout, unregister, shutdown) / SIGINT / SIGHUP → restore, exit 0 (I5).
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            service.shutdown(reason: "signal \(sig)")
            log.notice("exiting on signal \(sig, privacy: .public)")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    // 7. Sleep / wake (I6): restore before the sleep is acknowledged.
    let power = PowerObserver()
    power.onWillSleep = { service.systemWillSleep() }
    power.onDidWake = { service.systemDidWake() }
    power.start()

    // 8. Legacy self-uninstall hook (nil for other install kinds).
    let server = HelperXPCServer(service: service, validator: validator,
                                 uninstallHandler: LegacyUninstall.makeHandler(installKind: installKind, service: service))

    // 9. The daemon's Mach service. Only launchd can publish it: a hand-started process (e.g. --mock) checks in
    //    nowhere and simply never receives a connection.
    let listener = NSXPCListener(machServiceName: ThermikHelper.machServiceName)
    listener.delegate = server
    listener.activate()

    // 10. Serve forever; the sources, observer, delegate (held weakly by the listener) and listener stay alive.
    withExtendedLifetime((signalSources, power, server, listener)) { dispatchMain() }
}

/// Prints the requirement this helper binary would put on its client once the legacy installer pinned `appPath`'s
/// cdhashes (every slice, `CodeIdentity.cdhashes` as in `LegacyHelperInstaller.makePlan`), then exits: 0 printed,
/// 1 no requirement (deny all). scripts/lib/build.sh feeds it to `codesign --verify -R` for every slice of the built
/// app, so a build whose app this helper would reject (e.g. a get-task-allow entitlement the helper forbids) fails
/// at build time, not at runtime.
func printPeerRequirement(appPath: String?) -> Never {
    func fail(_ message: String, _ status: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(status)
    }
    guard let appPath else { fail("usage: thermik-helper --peer-requirement <Thermik.app>", 64) }   // EX_USAGE
    // Not `Bundle(url:)`: this binary lives in Contents/MacOS of that very bundle, so Foundation hands back
    // Bundle.main, whose executable is the helper itself.
    let app = URL(fileURLWithPath: appPath)
    guard let data = FileManager.default.contents(atPath: app.appending(path: "Contents/Info.plist").path),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else {
        fail("not an app bundle: \(appPath)")
    }
    let clientHashes = CodeIdentity.cdhashes(ofCodeAt: app.appending(path: "Contents/MacOS/\(name)"))
    guard !clientHashes.isEmpty else { fail("cannot read the code signature of \(appPath)") }
    let policy = PeerValidator.makePolicy(installKind: .legacy, trustedCDHashes: clientHashes)
    guard let requirement = policy.requirement(allowDebuggable: HelperBuild.allowDebuggableClients) else {
        fail("no client requirement: policy \(policy.description)")
    }
    print(requirement)
    exit(0)
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--peer-requirement") {
    printPeerRequirement(appPath: arguments.dropFirst(flag + 1).first)
}
runHelper(mock: arguments.contains("--mock"))
