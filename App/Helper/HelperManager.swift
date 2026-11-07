// HelperManager.swift — Thermik (MIT). Privileged helper lifecycle and connection management.
// Port of research/helper/skeleton/App/HelperManager.swift (HELP §A.10).
//
// App-side owner of the privileged helper's lifecycle: install state, install / approve / upgrade / uninstall, and
// the `client` FanStore talks to. The install mode comes from the app's OWN signature:
//   - Team ID (Apple Development / Developer ID) → SMAppService.daemon (plist inside Thermik.app, Login Items approval);
//   - ad-hoc ("Sign to Run Locally")              → legacy installer: one administrator prompt copies the helper to
//                                                   /Library/PrivilegedHelperTools and pins this build's cdhash.
// Every ad-hoc rebuild changes the cdhash, so the installed helper rejects the new build: `refresh()` reports that as
// `.needsUpgrade` (the trust file is world-readable) and the UI offers to re-authorize.
// `client` is the HelperConnection only while `.ready`; otherwise an UnavailableFanHelperClient (MockFanHelperClient
// in demo mode). SMAppService calls and XPC run off the main actor; only NSAppleScript (the admin prompt) must run
// on the main thread and blocks it while the dialog is up.
import AppKit
import Foundation
import Observation
import os
import ServiceManagement
import ThermikCore
import ThermikHelperShared

@MainActor @Observable final class HelperManager {
    enum Mode: String, Sendable { case appService, legacy }
    enum State: Equatable, Sendable {
        case unknown
        case notInstalled
        case requiresApproval                         // user must flip the switch in Login Items
        case needsUpgrade(installed: String, bundled: String)
        case ready(HelperInfo)
        case unreachable(String)
    }

    private(set) var state: State = .unknown
    let mode: Mode
    let isDemo: Bool
    /// Known fan-control daemons installed on this Mac (plist presence only), e.g. ["TG Pro"].
    private(set) var conflictingHelpers: [String] = []
    private(set) var lastHelperState: HelperState?
    /// The client FanStore talks to. Replaced on (re)connect; MockFanHelperClient in demo mode.
    private(set) var client: any FanHelperClient
    /// An install / upgrade / uninstall / approval wait is running (disable the buttons).
    private(set) var isBusy = false
    /// Localized message of the last failed operation (nil after a success).
    private(set) var lastError: String?
    /// CFBundleVersion (HELPER_BUILD_VERSION) of the helper embedded in this app (its __info_plist).
    let bundledHelperBuild: String?

    @ObservationIgnored private let connection: HelperConnection?
    @ObservationIgnored private let unavailable = UnavailableFanHelperClient()
    @ObservationIgnored private let ownIdentity: CodeIdentity?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: ThermikHelper.appBundleIdentifier, category: "helper")

    init(demo: Bool) {
        isDemo = demo
        let me = CodeIdentity.ofSelf()
        ownIdentity = me
        mode = (me?.teamID?.isEmpty == false) ? .appService : .legacy
        let helperURL = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(ThermikHelper.helperExecutableName)")
        bundledHelperBuild = (CFBundleCopyInfoDictionaryForURL(helperURL as CFURL) as? [String: Any])?["CFBundleVersion"] as? String
        if demo {
            connection = nil
            client = MockFanHelperClient()
            state = .ready(HelperInfo(protocolVersion: ThermikHelper.protocolVersion, helperVersion: "demo", helperBuild: "0",
                                      pid: 0, installKind: .development, fanCount: 2, scheme: "demo"))
        } else {
            connection = .privileged(helperRequirement: HelperConnection.requirementForHelper(appIdentity: me))
            client = unavailable
        }
        connection?.onDisconnect = { [weak self] invalidated in
            Task { @MainActor in self?.connectionDropped(invalidated: invalidated) }
        }
    }

    var isReady: Bool { if case .ready = state { return true }; return false }

    /// nil when ready.
    var availability: HelperAvailability? {
        switch state {
        case .ready: return nil
        case .unknown: return .connecting
        case .notInstalled: return .notInstalled
        case .requiresApproval: return .requiresApproval
        case .needsUpgrade: return .needsUpgrade
        case .unreachable: return .unreachable
        }
    }

    var health: HelperHealth {
        switch state {
        case .ready(let i): return .ready(version: i.helperVersion)
        case .unknown, .unreachable: return .unreachable(String(describing: state))
        case .notInstalled: return .notInstalled
        case .requiresApproval: return .requiresApproval
        case .needsUpgrade: return .needsUpgrade
        }
    }

    // MARK: Status

    /// Install status → `hello` → `.ready`, or `.needsUpgrade` when the build / protocol differs or (ad-hoc) this
    /// app build is not in the helper's trust file. Concurrent calls share one refresh.
    func refresh() async {
        guard !isDemo else {
            conflictingHelpers = KnownFanControlHelpers.installed()
            return
        }
        if let running = refreshTask { await running.value; return }
        let task = Task { @MainActor in await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        conflictingHelpers = KnownFanControlHelpers.installed()
        apply(await probeState())
    }

    private func probeState() async -> State {
        if let installState = await probeInstallState() {
            return installState
        }
        guard let connection else { return .unreachable("no helper connection") }
        return await probeConnectionState(connection)
    }

    private func probeInstallState() async -> State? {
        switch mode {
        case .appService: return await appServiceInstallState()
        case .legacy: return await legacyInstallState()
        }
    }

    private func appServiceInstallState() async -> State? {
        switch await Self.daemonStatus() {
        case .notRegistered, .notFound: return .notInstalled              // .notFound == never registered (HELP §2.3)
        case .requiresApproval: return .requiresApproval
        case .enabled: return nil
        @unknown default: return .unreachable("unknown SMAppService status")
        }
    }

    private func legacyInstallState() async -> State? {
        guard FileManager.default.fileExists(atPath: ThermikHelper.Legacy.plistPath) else { return .notInstalled }
        guard FileManager.default.fileExists(atPath: ThermikHelper.Legacy.helperPath) else {
            return .needsUpgrade(installed: LegacyHelperInstaller.installedHelperBuild(at: ThermikHelper.Legacy.previousHelperPath) ?? "?",
                                 bundled: bundledHelperBuild ?? "?")
        }
        if await Self.legacyStatus() == .requiresApproval { return .requiresApproval }   // disabled in Login Items
        return legacyTrustState()
    }

    private func legacyTrustState() -> State? {
        guard let mine = ownIdentity?.cdhashHex else { return nil }
        let trusted = LegacyHelperInstaller.trustedClientCDHashes() ?? []
        guard !trusted.contains(mine) else { return nil }
        // Installed for another (ad-hoc) build of Thermik: it would reject us (4097) → re-authorize.
        return .needsUpgrade(installed: LegacyHelperInstaller.installedHelperBuild() ?? "?", bundled: bundledHelperBuild ?? "?")
    }

    private func probeConnectionState(_ connection: HelperConnection) async -> State {
        do {
            let info = try await connection.hello()
            return stateForHello(info)
        } catch let e as NSError where e.thermikHelperCode == .unsupportedProtocol {
            return .needsUpgrade(installed: "protocol mismatch", bundled: bundledHelperBuild ?? "?")
        } catch {
            // 4097 rejected / crashed, 4099 not running, 4101 timeout, 4102 the helper's signature is unexpected.
            return .unreachable(error.localizedDescription)
        }
    }

    private func stateForHello(_ info: HelperInfo) -> State {
        guard let bundled = bundledHelperBuild, bundled != info.helperBuild else { return .ready(info) }
        return .needsUpgrade(installed: info.helperBuild, bundled: bundled)
    }

    private func apply(_ new: State) {
        let old = state
        state = new
        if case .ready = new, let connection {
            client = connection
        } else {
            client = unavailable
            lastHelperState = nil
        }
        if old != new { log.notice("helper state: \(String(describing: new), privacy: .public)") }
    }

    /// Only a READY helper going away is news; a helper that is already unreachable keeps failing quietly.
    private func connectionDropped(invalidated: Bool) {
        lastHelperState = nil
        guard case .ready = state, refreshTask == nil else { return }
        log.notice("helper connection \(invalidated ? "invalidated" : "interrupted", privacy: .public); re-checking")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(invalidated ? 200 : 1000))   // let launchd relaunch it
            await self.refresh()
        }
    }

    // MARK: Install / approve / upgrade / uninstall

    func install() async throws {
        guard !isDemo else { return }
        try await perform("install") { try await self.installHelper() }
        connection?.reset()
        await refreshUntilSettled { $0.isSettledAfterInstall }
    }

    private func installHelper() async throws {
        switch mode {
        case .appService:
            try await registerWithRetry()
            if await Self.daemonStatus() == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        case .legacy:
            try runLegacyInstaller(prompt: String(localized: "Thermik needs administrator permission to install its fan-control helper."))
        }
    }

    /// Call while System Settings › Login Items is open: polls every 2 s until the user approves (or `timeout`).
    func awaitApproval(timeout: Duration = .seconds(120)) async -> Bool {
        guard !isDemo else { return true }
        isBusy = true
        defer { isBusy = false }
        if let approved = await waitForApproval(until: ContinuousClock.now + timeout) {
            return approved
        }
        await refresh()
        return isReady
    }

    private func waitForApproval(until deadline: ContinuousClock.Instant) async -> Bool? {
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let status = mode == .appService ? await Self.daemonStatus() : await Self.legacyStatus()
            if status == .enabled {
                return await finishApproval()
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    private func finishApproval() async -> Bool {
        connection?.reset()
        await refreshUntilSettled { $0.isSettledAfterInstall }
        return isReady
    }

    func upgrade() async throws {
        guard !isDemo else { return }
        try await perform("upgrade") { try await self.upgradeHelper() }
        connection?.reset()
        await refreshUntilSettled { $0.isSettledAfterInstall }
    }

    private func upgradeHelper() async throws {
        try? await connection?.resetAllFans()
        switch mode {
        case .appService:
            try await upgradeDaemon()
        case .legacy:
            // Idempotent: bootout (the old helper restores the fans on SIGTERM) → verified copy → bootstrap.
            try runLegacyInstaller(prompt: String(localized: "Thermik needs administrator permission to update its fan-control helper."))
        }
    }

    /// SMAppService.h: after the executable changed, unregister before re-registering.
    private func upgradeDaemon() async throws {
        try? await Self.unregisterDaemon()
        try await registerWithRetry()
        if await Self.daemonStatus() == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() async throws {
        guard !isDemo else { return }
        try await perform("uninstall") { try await self.uninstallHelper() }
        connection?.reset()
        await refreshUntilSettled { $0 == .notInstalled }
    }

    private func uninstallHelper() async throws {
        try? await connection?.resetAllFans()
        switch mode {
        case .appService:
            try await Self.unregisterDaemon()              // launchd SIGTERMs the helper → it restores the fans
        case .legacy:
            try await uninstallLegacy()
        }
    }

    private func uninstallLegacy() async throws {
        do {
            guard let connection else { throw NSError.thermikHelper(.notPermitted, "no connection") }
            try await connection.uninstallLegacyHelper()   // the trusted helper removes itself: no password
        } catch {
            log.notice("XPC uninstall unavailable (\(error.localizedDescription, privacy: .public)); using the administrator script")
            NSApp.activate()
            try LegacyHelperInstaller.uninstall(prompt: String(localized: "Thermik needs administrator permission to remove its fan-control helper."))
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// getState() → lastHelperState (Diagnostics, Fans page helper card). nil when not ready or on failure.
    func fetchState() async {
        guard isReady else { lastHelperState = nil; return }
        do {
            lastHelperState = try await client.state()
        } catch {
            lastHelperState = nil
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain || ns.thermikHelperCode == .notPermitted { await refresh() }
        }
    }

    // MARK: Internals

    /// Runs one lifecycle operation: busy flag, logging, localized `lastError`.
    private func perform(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
        isBusy = true
        defer { isBusy = false }
        do {
            try await body()
            operationSucceeded(name)
        } catch {
            lastError = Self.message(for: error)
            log.error("helper \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func operationSucceeded(_ name: String) {
        lastError = nil
        log.notice("helper \(name, privacy: .public) done")
    }

    private func runLegacyInstaller(prompt: String) throws {
        NSApp.activate()                    // LSUIElement app: bring the administrator dialog to the front
        try LegacyHelperInstaller.install(prompt: prompt)
    }

    /// The daemon needs a moment after bootstrap / approval: re-check up to ~5 s until `settled`.
    private func refreshUntilSettled(_ settled: (State) -> Bool) async {
        for attempt in 0..<10 {
            await refresh()
            if settled(state) { return }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(500)) }
        }
    }

    /// register() right after unregister() fails transiently with EPERM ("Operation not permitted"): retry with
    /// back-off, 6 attempts, 500 ms × n (pattern from Battery Toolkit (BSD-3-Clause) and Apple forums 768592).
    private func registerWithRetry() async throws {
        var lastError: (any Error)?
        for attempt in 1...6 {
            guard let error = await attemptRegistration(attempt) else { return }
            lastError = error
            if attempt < 6 { try await Task.sleep(for: .milliseconds(500 * attempt)) }
        }
        throw lastError ?? NSError.thermikHelper(.internalError, "SMAppService.register failed")
    }

    private func attemptRegistration(_ attempt: Int) async -> (any Error)? {
        do {
            try await Self.registerDaemon()
            log.notice("SMAppService.register ok (attempt \(attempt, privacy: .public))")
            return nil
        } catch {
            return await registrationFailure(error, attempt: attempt)
        }
    }

    private func registrationFailure(_ error: Error, attempt: Int) async -> (any Error)? {
        let ns = error as NSError
        log.error("SMAppService.register attempt \(attempt, privacy: .public) failed: \(ns, privacy: .public)")
        if ns.code == kSMErrorAlreadyRegistered { return nil }
        if await Self.daemonStatus() == .requiresApproval { return nil }   // registered, waiting for the user
        return error
    }

    // SMAppService does XPC to smd/BTM: keep it off the main actor.
    nonisolated private static func daemonStatus() async -> SMAppService.Status {
        await Task.detached { SMAppService.daemon(plistName: ThermikHelper.plistName).status }.value
    }

    nonisolated private static func legacyStatus() async -> SMAppService.Status {
        await Task.detached { SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: ThermikHelper.Legacy.plistPath)) }.value
    }

    nonisolated private static func registerDaemon() async throws {
        try await Task.detached { try SMAppService.daemon(plistName: ThermikHelper.plistName).register() }.value
    }

    nonisolated private static func unregisterDaemon() async throws {
        try await Task.detached { try await SMAppService.daemon(plistName: ThermikHelper.plistName).unregister() }.value
    }

    /// User-facing text for a failed operation.
    private static func message(for error: any Error) -> String {
        if let error = error as? LegacyHelperInstaller.InstallError {
            return legacyMessage(for: error)
        }
        let ns = error as NSError
        if ns.domain == ThermikHelper.errorDomain || ns.domain == NSCocoaErrorDomain {
            return String(localized: "The helper did not respond: \(ns.localizedDescription)")
        }
        return String(localized: "macOS refused to register the helper: \(ns.localizedDescription)")
    }

    private static func legacyMessage(for error: LegacyHelperInstaller.InstallError) -> String {
        switch error {
        case .cancelled: return String(localized: "The administrator prompt was cancelled.")
        case .missingHelper: return String(localized: "The helper is missing from the Thermik app bundle. Reinstall Thermik.")
        case .unsignedApp: return String(localized: "Thermik's code signature cannot be read.")
        case .failed(_, let message): return String(localized: "The helper could not be installed: \(message)")
        }
    }
}

private extension HelperManager.State {
    /// After install / upgrade / approval: anything but "not there yet" ends the wait.
    var isSettledAfterInstall: Bool {
        switch self {
        case .ready, .requiresApproval, .needsUpgrade: true
        case .unknown, .notInstalled, .unreachable: false
        }
    }
}
