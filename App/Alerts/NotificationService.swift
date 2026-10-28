// NotificationService.swift — Thermik (MIT). OWNER: Unit 6 (new). Local notifications for alerts (SPEC §2.10).
//
// UNUserNotificationCenter with [.alert, .sound] (no badge: menu-bar app). Interruption level `.active`
// (`.timeSensitive` needs an entitlement, §6.2). Request id `alert.<ruleID>` replaces the previous notification of the
// same rule; the thread id groups by subject. Categories: `thermik.alert` ("Fans to Max", "Snooze 1 h") when Thermik
// can drive the fans, `thermik.alert.info` ("Snooze 1 h") otherwise. Clicking a notification opens the page in its
// userInfo route. The delegate answers on whatever queue UserNotifications uses and hops to the main actor.
import AppKit
import Foundation
import os
import ThermikCore
import UserNotifications

enum NotificationAction: Sendable, Equatable {
    case open(Route?)
    case setFansMax
    case snooze1h
}

/// What to show; built on the main actor by AlertStore.
struct AlertNotification: Sendable {
    var id: String                    // request identifier ("alert.<ruleID>")
    var title: String
    var body: String
    var threadID: String
    var route: Route?
    var offerFanActions: Bool
    var soundName: String?
}

@MainActor final class NotificationService {
    nonisolated static let fanCategory = "thermik.alert"
    nonisolated static let infoCategory = "thermik.alert.info"
    nonisolated static let setMaxAction = "thermik.setMax"
    nonisolated static let snoozeAction = "thermik.snooze1h"
    nonisolated static let routeKey = "route"

    /// nil when this process has no bundle identifier (UNUserNotificationCenter.current() would raise).
    private let center: UNUserNotificationCenter?
    private let delegate: Delegate
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "alerts")
    /// Set by AlertStore: notification clicks and actions.
    var onAction: (NotificationAction) -> Void = { _ in }

    init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        // Responses arrive on UserNotifications' queue; a stream carries them (as Sendable strings) to the main actor.
        let (responses, continuation) = AsyncStream.makeStream(of: Response.self)
        delegate = Delegate { continuation.yield($0) }
        Task { @MainActor [weak self] in
            for await r in responses { self?.handle(action: r.action, routeJSON: r.routeJSON) }
        }
        guard let center else { return }
        center.delegate = delegate
        let fansToMax = UNNotificationAction(identifier: Self.setMaxAction, title: String(localized: "Fans to Max"), options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: String(localized: "Snooze 1 h"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.fanCategory, actions: [fansToMax, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.infoCategory, actions: [snooze], intentIdentifiers: []),
        ])
    }

    // MARK: Authorization

    func authorizationStatus() async -> NotificationAuthorization {
        guard let center else { return .unknown }
        let status = await withCheckedContinuation { (c: CheckedContinuation<UNAuthorizationStatus, Never>) in
            center.getNotificationSettings { c.resume(returning: $0.authorizationStatus) }
        }
        return Self.map(status)
    }

    /// Asks once (the system shows its prompt only while the status is "not determined"); returns the new status.
    func requestAuthorization() async -> NotificationAuthorization {
        guard let center else { return .unknown }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            log.info("notification authorization granted: \(granted, privacy: .public)")
        } catch {
            log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await authorizationStatus()
    }

    private static func map(_ s: UNAuthorizationStatus) -> NotificationAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .authorized
        @unknown default: return .unknown
        }
    }

    /// System Settings › Notifications › Thermik.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.thermik.Thermik"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Delivery

    func post(_ n: AlertNotification) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.threadIdentifier = n.threadID
        content.categoryIdentifier = n.offerFanActions ? Self.fanCategory : Self.infoCategory
        content.interruptionLevel = .active
        content.sound = n.soundName.map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        if let route = n.route, let data = try? JSONEncoder().encode(route), let json = String(data: data, encoding: .utf8) {
            content.userInfo = [Self.routeKey: json]
        }
        let request = UNNotificationRequest(identifier: n.id, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("notification not delivered: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Responses

    private func handle(action: String, routeJSON: String?) {
        switch action {
        case Self.setMaxAction: onAction(.setFansMax)
        case Self.snoozeAction: onAction(.snooze1h)
        case UNNotificationDefaultActionIdentifier:
            let route = routeJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Route.self, from: $0) }
            onAction(.open(route))
        default: break                                         // dismissed
        }
    }

    private struct Response: Sendable {
        var action: String
        var routeJSON: String?
    }

    /// Immutable, so it is Sendable; UserNotifications may call it on any queue.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
        private let onResponse: @Sendable (Response) -> Void
        init(onResponse: @escaping @Sendable (Response) -> Void) { self.onResponse = onResponse }

        /// Show alerts even while a Thermik window is frontmost.
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            [.banner, .list, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let route = response.notification.request.content.userInfo[NotificationService.routeKey] as? String
            onResponse(Response(action: response.actionIdentifier, routeJSON: route))
        }
    }
}
