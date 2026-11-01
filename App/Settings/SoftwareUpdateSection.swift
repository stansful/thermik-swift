// SoftwareUpdateSection.swift — Thermik (MIT). GitHub release checks, separate from sensor sampling.
import SwiftUI

struct SoftwareUpdateSection: View {
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecking)) {
                Text("Automatically check for updates")
            }
            .disabled(!updater.isAvailable)
            HStack {
                Button { updater.checkForUpdates() } label: { Text("Check for Updates…") }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                Link(destination: AppUpdater.releasesURL) { Text("GitHub Releases") }
            }
            status
            if let checked = updater.lastChecked {
                LabeledContent { Text(checked, style: .relative).foregroundStyle(.secondary) } label: { Text("Last checked") }
            }
            if let message = updater.unavailableMessage {
                Text(verbatim: message).font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Software Updates")
        } footer: {
            Text("When enabled, Thermik checks GitHub Releases once a day. Download opens the release in your browser; install the new version manually. Sensor data and logs stay on your Mac.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle: EmptyView()
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case .upToDate:
            Label { Text("Thermik is up to date") } icon: { Image(systemName: "checkmark.circle") }
        case .available(let release):
            HStack {
                Text("Thermik \(release.version) is available")
                Spacer()
                Button { updater.openRelease(release) } label: { Text("Download…") }
            }
        case .failed(let message):
            Text(verbatim: message).font(ThermikFont.caption).foregroundStyle(.secondary)
        }
    }
}
