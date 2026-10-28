// HelperControlCard.swift — Thermik (MIT). Unit 8. Helper status + actions, shared by the Fans page, Settings › Helper
// and onboarding (SPEC §4.6 W4, §4.7, F8). Reflects HelperManager.state; Install / Approve (Login Items) / Update /
// Reinstall / Uninstall call HelperManager (Unit 4), which owns both install modes (SMAppService with a Team ID, the
// legacy admin-prompt installer for ad-hoc builds). This view never talks to launchd or the SMC itself.
import AppKit
import SwiftUI
import ThermikCore
import ThermikHelperShared

struct HelperControlCard: View {
    var showsDetails = true
    @Environment(HelperManager.self) private var helper
    @Environment(SettingsStore.self) private var settings
    @State private var busy = false
    @State private var errorText: String?
    @State private var confirmUninstall = false

    var body: some View {
        PageCard(title: String(localized: "Fan helper"), symbol: "lock.shield") {
            if busy { ProgressView().controlSize(.small) }
        } content: {
            HStack(spacing: 8) {
                StatusDot(color: HelperStatusColor.color(helper.state), size: 9)
                Text(verbatim: helper.state.statusLine).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            Text(verbatim: explanation).font(ThermikFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !helper.conflictingHelpers.isEmpty {
                let names = helper.conflictingHelpers.joined(separator: ", ")
                StatusBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                             text: String(localized: "Other fan-control helpers are installed: \(names). Only one app should control the fans at a time — quit the others before switching Thermik to Curve, Fixed or Max."))
            }
            if showsDetails { details }
            if let errorText {
                Text(verbatim: errorText).font(ThermikFont.caption).foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .task { if helper.isReady { await helper.fetchState() } }
        .confirmationDialog(Text("Uninstall the fan helper?"), isPresented: $confirmUninstall) {
            Button(role: .destructive) { run { try await helper.uninstall(); settings.helperWanted = false } } label: { Text("Uninstall") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("The fans return to Auto. Monitoring keeps working; fan control needs the helper again.")
        }
    }

    private var explanation: String {
        switch helper.state {
        case .notInstalled, .unknown:
            String(localized: "Fan control needs a small privileged helper. It writes fan targets through the SMC as root, is open source, can be removed at any time, and quitting Thermik always returns the fans to Auto.")
        case .requiresApproval:
            String(localized: "Approve Thermik in System Settings › General › Login Items & Extensions, then come back here.")
        case .needsUpgrade:
            String(localized: "This version of Thermik bundles a newer helper. Update it to keep fan control working.")
        case .ready:
            String(localized: "The helper is running. Thermik never sets fans below their hardware minimum, and quitting Thermik returns them to Auto.")
        case .unreachable:
            String(localized: "The helper is installed but did not answer. Reinstalling usually fixes this.")
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: String(localized: "Install mode"), value: helper.mode.title)
            if case .ready(let info) = helper.state {
                DetailRow(label: String(localized: "Version"), value: "\(info.helperVersion) (\(info.helperBuild))")
                DetailRow(label: String(localized: "Installed as"), value: info.installKind.title)
                DetailRow(label: String(localized: "Fan scheme"), value: info.scheme, monospaced: true)
            }
            if let s = helper.lastHelperState {
                DetailRow(label: String(localized: "Controlling fans"), value: s.isControlling ? String(localized: "Yes") : String(localized: "No"))
                if let lease = s.leaseRemainingSeconds {
                    DetailRow(label: String(localized: "Lease"), value: WindowFormat.duration(lease))
                }
                if let token = s.lastRevertReason {
                    let reason = HelperRevertReason.title(token)
                    let when = s.lastRevertDate.map(WindowFormat.dateTime) ?? ""
                    DetailRow(label: String(localized: "Last return to Auto"), value: when.isEmpty ? reason : "\(reason) · \(when)")
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch helper.state {
            case .notInstalled:
                primary(String(localized: "Install Helper…")) { try await install() }
            case .requiresApproval:
                Button { helper.openLoginItems() } label: { Text("Open Login Items") }
                    .buttonStyle(.borderedProminent)
                secondary(String(localized: "Check Again")) { await helper.refresh() }
            case .needsUpgrade:
                primary(String(localized: "Update Helper…")) { try await helper.upgrade(); await helper.refresh() }
                uninstallButton
            case .ready:
                secondary(String(localized: "Reinstall…")) { try await install() }
                uninstallButton
            case .unreachable:
                primary(String(localized: "Reinstall…")) { try await install() }
                secondary(String(localized: "Retry")) { await helper.refresh() }
                uninstallButton
            case .unknown:
                secondary(String(localized: "Check Again")) { await helper.refresh() }
            }
        }
        .disabled(busy)
        .controlSize(.regular)
    }

    private var uninstallButton: some View {
        Button(role: .destructive) { confirmUninstall = true } label: { Text("Uninstall…") }
    }

    private func primary(_ title: String, _ action: @escaping @MainActor () async throws -> Void) -> some View {
        Button { run(action) } label: { Text(verbatim: title).frame(minWidth: 110) }
            .buttonStyle(.borderedProminent)
    }

    private func secondary(_ title: String, _ action: @escaping @MainActor () async throws -> Void) -> some View {
        Button { run(action) } label: { Text(verbatim: title) }
    }

    private func install() async throws {
        try await helper.install()
        settings.helperWanted = true
        if helper.mode == .appService, case .requiresApproval = helper.state { _ = await helper.awaitApproval() }
        await helper.refresh()
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task { @MainActor in
            do { try await action() } catch { errorText = (error as NSError).localizedDescription }
            if helper.isReady { await helper.fetchState() }
            busy = false
        }
    }
}

/// The one action button for a "fan control needs the helper" line (§4.14): Install / Open Login Items / Update / Retry.
struct HelperQuickAction: View {
    var availability: HelperAvailability
    @Environment(HelperManager.self) private var helper
    @Environment(SettingsStore.self) private var settings
    @State private var busy = false

    var body: some View {
        switch availability {
        case .notInstalled:
            button(String(localized: "Install Helper…")) {
                try await helper.install()
                settings.helperWanted = true
                if case .requiresApproval = helper.state { _ = await helper.awaitApproval() }
                await helper.refresh()
            }
        case .requiresApproval:
            Button { helper.openLoginItems() } label: { Text("Open Login Items") }
        case .needsUpgrade:
            button(String(localized: "Update Helper…")) { try await helper.upgrade(); await helper.refresh() }
        case .unreachable:
            button(String(localized: "Retry")) { await helper.refresh() }
        case .connecting:
            ProgressView().controlSize(.small)
        }
    }

    private func button(_ title: String, _ action: @escaping @MainActor () async throws -> Void) -> some View {
        Button {
            busy = true
            Task { @MainActor in
                do { try await action() } catch { NSAlert(error: error).runModal() }
                busy = false
            }
        } label: { Text(verbatim: title) }
        .disabled(busy)
    }
}

enum HelperStatusColor {
    static func color(_ s: HelperManager.State) -> Color {
        switch s {
        case .ready: Color(nsColor: .systemGreen)
        case .requiresApproval, .needsUpgrade, .unreachable: Color(nsColor: .systemOrange)
        case .notInstalled, .unknown: Color(nsColor: .tertiaryLabelColor)
        }
    }
}
