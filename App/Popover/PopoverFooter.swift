// PopoverFooter.swift — Thermik (MIT). OWNER: Unit 7. Popover footer (SPEC §4.5): alerts-today / diagnostics status
// links (→ Alerts / Diagnostics pages), the gear (⌘, → Settings › General in the main window) and Quit (⌘Q). The main
// window opens from a sensor row, the status links, the right-click menu or the gear.
import SwiftUI
import AppKit
import ThermikCore

struct PopoverFooter: View {
    @Environment(AlertStore.self) private var alerts
    @Environment(DiagnosticsStore.self) private var diagnostics
    @Environment(AppRouter.self) private var router
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?

    var body: some View {
        HStack(spacing: 6) {
            statusLinks.layoutPriority(1)                // all the width the buttons leave (ViewThatFits decides)
            Spacer(minLength: 8)
            Button { panel.closeThen { router.showSettings(.general) } } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help(Text("Settings…"))
            .accessibilityLabel(Text("Settings…"))
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: .command)
            .help(Text("Quit Thermik"))
            .accessibilityLabel(Text("Quit Thermik"))
        }
        .padding(.horizontal, ThermikMetrics.gutter)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// One row ("2 alerts today · Diagnostics OK") when it fits next to the buttons (≈ 270 pt), otherwise the two links
    /// stacked: in Russian "12 оповещений сегодня · Диагностика: найдена проблема" needs ≈ 350 pt, and truncating it
    /// would cut off what is wrong.
    private var statusLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                if showsAlertLink {
                    alertLink
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                diagnosticsLink
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsAlertLink { alertLink }
                diagnosticsLink
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var showsAlertLink: Bool { alerts.alertsToday > 0 || alerts.hasActiveAlert }

    private var alertLink: some View {
        let today = alerts.alertsToday
        return Button { panel.closeThen { router.showMain(.alerts) } } label: {
            Label {
                Text(today > 0 ? String(localized: "\(today) alerts today") : String(localized: "Alert active"))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain)
    }

    private var diagnosticsLink: some View {
        let overall = diagnostics.overall
        return Button { panel.closeThen { router.showMain(.diagnostics) } } label: {
            Label { Text(diagnosticsTitle(overall)) } icon: {
                Image(systemName: diagnosticsSymbol(overall)).foregroundStyle(diagnosticsTint(overall))
            }
        }
        .buttonStyle(.plain)
    }

    private func diagnosticsTitle(_ s: DiagnosticStatus) -> String {
        switch s {
        case .ok, .info: String(localized: "Diagnostics OK")
        case .warning: String(localized: "Diagnostics: needs attention")
        case .error: String(localized: "Diagnostics: problem found")
        case .unknown: String(localized: "Diagnostics")
        }
    }
    private func diagnosticsSymbol(_ s: DiagnosticStatus) -> String {
        switch s {
        case .ok, .info: "checkmark.seal"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .unknown: "stethoscope"
        }
    }
    private func diagnosticsTint(_ s: DiagnosticStatus) -> Color {
        switch s {
        case .ok, .info: .green
        case .warning: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }
}
