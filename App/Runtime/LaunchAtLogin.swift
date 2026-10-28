// LaunchAtLogin.swift — Thermik (MIT). OWNER: Unit 5. "Launch at login" through SMAppService.mainApp (macOS 13+,
// public ServiceManagement API; FEAT §9.1). `settings.launchAtLogin` is the user's intent, the system registration
// is the truth: Settings (Unit 8) binds the toggle to the setting and shows `LaunchAtLogin.shared.status`. The user can
// approve, switch off or remove Thermik in System Settings › Login Items while it runs, so the status is re-read
// whenever Thermik becomes active or one of its windows (Settings) becomes key — off the main actor, since
// SMAppService does XPC to BTM.
import AppKit
import Foundation
import Observation
import os
import ServiceManagement

@MainActor @Observable final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// Last known registration (`.enabled`, `.requiresApproval` — switched off in System Settings › Login Items —,
    /// `.notRegistered`, `.notFound`).
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// The last register/unregister failure (shown under the toggle), nil after a success.
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private let log = Logger(subsystem: "app.thermik.Thermik", category: "lifecycle")
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastBackgroundRefresh: ContinuousClock.Instant?
    /// Bumped by every synchronous status change: a background read that started earlier is then dropped.
    @ObservationIgnored private var statusGeneration = 0

    private init() {}

    /// AppDelegate, once at launch. Reconciles the setting with System Settings (the user may have removed or
    /// re-enabled Thermik there), then applies every later change of the setting. Nothing is registered before
    /// onboarding completes: the onboarding's last step sets the value (SPEC §2.11).
    func bind(to settings: SettingsStore) {
        guard self.settings == nil else { return }
        self.settings = settings
        refresh()
        reconcile()
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInBackground() }
            })
        }
        observeContinuously({ [weak settings] in
            _ = settings?.launchAtLogin; _ = settings?.onboardingCompleted
        }) { [weak self] in
            guard let self else { return false }
            self.apply()
            return true
        }
    }

    func refresh() {
        statusGeneration &+= 1
        let s = SMAppService.mainApp.status
        if s != status { status = s }
    }

    /// The setting follows System Settings (at launch, and when the user changed Login Items while Thermik ran).
    /// Not after a failed register/unregister: the toggle keeps the intent and the error stays visible.
    private func reconcile() {
        guard let settings, settings.onboardingCompleted, lastError == nil else { return }
        let registered = status == .enabled || status == .requiresApproval
        if settings.launchAtLogin != registered {
            log.info("launch at login: System Settings says \(registered, privacy: .public); following it")
            settings.launchAtLogin = registered
        }
    }

    /// Re-reads the registration off the main actor (at most once a second: activation and a window becoming key
    /// usually arrive together), then publishes it and reconciles the setting.
    private func refreshInBackground() {
        let now = ContinuousClock.now
        if let last = lastBackgroundRefresh, last.duration(to: now) < .seconds(1) { return }
        lastBackgroundRefresh = now
        let generation = statusGeneration, intent = settings?.launchAtLogin
        Task { @MainActor [weak self] in
            let s = await Task.detached { SMAppService.mainApp.status }.value
            // setEnabled ran, or the user flipped the toggle (apply() is about to register): this read is stale.
            guard let self, generation == self.statusGeneration, intent == self.settings?.launchAtLogin else { return }
            if s != self.status { self.status = s }
            self.reconcile()
        }
    }

    /// Registers or unregisters now. Returns false (and sets `lastError`) when ServiceManagement refuses.
    @discardableResult func setEnabled(_ on: Bool) -> Bool {
        refresh()
        let registered = status == .enabled || status == .requiresApproval
        guard on != registered else { return true }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
            log.info("launch at login \(on ? "registered" : "unregistered", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("launch at login \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        return lastError == nil
    }

    /// `.requiresApproval`: the user switched Thermik off in Login Items; only they can switch it back on.
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func apply() {
        guard let settings, settings.onboardingCompleted else { return }
        setEnabled(settings.launchAtLogin)
    }
}
