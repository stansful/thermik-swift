// AppUpdater.swift — Thermik (MIT). Optional GitHub release checks; downloading opens the release in a browser.
import AppKit
import Observation
import ThermikUpdates
import os

@MainActor @Observable final class AppUpdater: NSObject, NSMenuItemValidation {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(AvailableUpdate)
        case failed(String)
    }

    nonisolated static let releasesURL = URL(string: "https://github.com/stansful/thermik-swift/releases")!
    private(set) var state: State = .idle
    let unavailableMessage: String?
    var isAvailable: Bool { checker != nil }
    var canCheckForUpdates: Bool { isAvailable && started && state != .checking }
    var automaticallyChecksForUpdates: Bool { settings.automaticallyCheckForUpdates }
    var lastChecked: Date? { settings.lastUpdateCheck }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let checker: (any ReleaseChecking)?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.thermik.Thermik", category: "updates")

    init(settings: SettingsStore, checker: any ReleaseChecking) {
        self.settings = settings
        self.checker = checker
        unavailableMessage = nil
        super.init()
    }

    private init(settings: SettingsStore, unavailableMessage: String) {
        self.settings = settings
        self.checker = nil
        self.unavailableMessage = unavailableMessage
        super.init()
    }

    static func forCurrentLaunch(settings: SettingsStore) -> AppUpdater {
        #if DEBUG
        if let fixture = debugFixture(settings: settings) { return fixture }
        #endif
        let identity = releaseIdentity()
        do {
            let configuration = try ReleaseConfiguration(repository: identity.repository, currentVersion: identity.version)
            return AppUpdater(settings: settings, checker: GitHubReleaseChecker(configuration: configuration))
        } catch {
            return AppUpdater(settings: settings, unavailableMessage: String(localized: "Update checks are unavailable for this build."))
        }
    }

    private static func releaseIdentity() -> (repository: String, version: String) {
        #if DEBUG
        let repository = UserDefaults.standard.string(forKey: "ThermikUpdateRepository") ?? "stansful/thermik-swift"
        let version = UserDefaults.standard.string(forKey: "ThermikUpdateVersion")
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #else
        let repository = "stansful/thermik-swift"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #endif
        return (repository, version)
    }

    static func forDemo(settings: SettingsStore) -> AppUpdater {
        #if DEBUG
        if let fixture = debugFixture(settings: settings) { return fixture }
        #endif
        return AppUpdater(settings: settings, unavailableMessage: String(localized: "Update checks are disabled in demo mode."))
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleAutomaticCheck(after: .seconds(60))
    }

    func stop() {
        started = false
        scheduledTask?.cancel()
        scheduledTask = nil
        checkTask?.cancel()
        checkTask = nil
        if state == .checking { state = .idle }
    }

    func setAutomaticChecking(_ value: Bool) {
        guard isAvailable else { return }
        settings.automaticallyCheckForUpdates = value
        scheduleAutomaticCheck(after: .seconds(60))
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await check()
            guard started else { return }
            presentResult()
        }
    }

    /// Shared by manual and scheduled checks. Concurrent callers wait for the same request.
    func check() async {
        if let checkTask { await checkTask.value; return }
        guard started, let checker else { return }
        state = .checking
        let task = Task { @MainActor [weak self] in
            let result = await Self.requestResult(using: checker)
            guard !Task.isCancelled, let self else { return }
            self.applyCheckResult(result)
        }
        checkTask = task
        await task.value
    }

    private static func requestResult(using checker: any ReleaseChecking) async -> Result<UpdateCheckResult, any Error> {
        do { return .success(try await checker.check()) }
        catch { return .failure(error) }
    }

    private func applyCheckResult(_ result: Result<UpdateCheckResult, any Error>) {
        switch result {
        case .success(let update): completeCheck(with: update)
        case .failure(let error): failCheck(with: error)
        }
        checkTask = nil
    }

    private func completeCheck(with result: UpdateCheckResult) {
        switch result {
        case .upToDate: state = .upToDate
        case .available(let release): state = .available(release)
        }
        settings.lastUpdateCheck = Date()
    }

    private func failCheck(with error: any Error) {
        state = .failed(Self.message(for: error))
        log.notice("release check failed: \(String(describing: error), privacy: .public)")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }

    func openRelease(_ release: AvailableUpdate) { NSWorkspace.shared.open(release.url) }

    private func scheduleAutomaticCheck(after delay: Duration) {
        scheduledTask?.cancel()
        scheduledTask = nil
        guard started, isAvailable, automaticallyChecksForUpdates else { return }
        scheduledTask = Task { @MainActor [weak self] in
            guard await Self.wait(for: delay) else { return }
            guard let self, self.started, self.automaticallyChecksForUpdates, !Task.isCancelled else { return }
            await self.runScheduledCheck()
        }
    }

    private static func wait(for delay: Duration) async -> Bool {
        do { try await Task.sleep(for: delay) }
        catch { return false }
        return true
    }

    private var checkIsDue: Bool {
        lastChecked.map { checked in
            let elapsed = Date().timeIntervalSince(checked)
            return elapsed >= 86_400 || elapsed < 0
        } ?? true
    }

    private func runScheduledCheck() async {
        if checkIsDue { await check() }
        guard !Task.isCancelled else { return }
        // Retry failed checks hourly, and check successful ones at most once a day.
        scheduleAutomaticCheck(after: .seconds(3_600))
    }

    private func presentResult() {
        switch state {
        case .available(let release): presentAvailable(release)
        case .upToDate: presentUpToDate()
        case .failed(let message): presentFailure(message)
        case .idle, .checking: break
        }
    }

    private func presentAvailable(_ release: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Thermik \(release.version) is available")
        alert.informativeText = String(localized: "Download the new version from GitHub Releases and replace Thermik in Applications.")
        alert.addButton(withTitle: String(localized: "Download…"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openRelease(release) }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Thermik is up to date")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not check for updates")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    private static func message(for error: any Error) -> String {
        switch error as? UpdateCheckError {
        case .offline: String(localized: "Could not connect to GitHub. Check your connection and try again.")
        case .rateLimited: String(localized: "GitHub's request limit was reached. Try again later.")
        case .repositoryNotFound: String(localized: "No published release was found on GitHub.")
        default: String(localized: "GitHub returned an unexpected response. Try again later.")
        }
    }

    #if DEBUG
    private static func debugFixture(settings: SettingsStore) -> AppUpdater? {
        guard let value = UserDefaults.standard.string(forKey: "ThermikUpdateFixture") else { return nil }
        guard let fixture = UpdateFixture(rawValue: value) else {
            return AppUpdater(settings: settings, unavailableMessage: String(localized: "Unknown local update test scenario."))
        }
        return AppUpdater(settings: settings, checker: FixtureReleaseChecker(fixture: fixture))
    }
    #endif
}

#if DEBUG
private enum UpdateFixture: String { case available, upToDate, offline }

private struct FixtureReleaseChecker: ReleaseChecking {
    let fixture: UpdateFixture
    func check() async throws -> UpdateCheckResult {
        switch fixture {
        case .available: .available(AvailableUpdate(version: "99.0.0", url: AppUpdater.releasesURL))
        case .upToDate: .upToDate
        case .offline: throw UpdateCheckError.offline
        }
    }
}
#endif
