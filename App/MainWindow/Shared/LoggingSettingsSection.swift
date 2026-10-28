// LoggingSettingsSection.swift — Thermik (MIT). Unit 8. CSV logging options (SPEC §2.12, §4.6 Logs, §4.7 Logging),
// shared by the Logs page and Settings › Logging. Writes `settings.log` (LogConfig); CSVLoggingService (Unit 6) picks
// the change up. Retention is off by default and only ever touches Thermik-*.csv files in the chosen folder.
import AppKit
import SwiftUI
import ThermikCore

/// Form rows (place inside a `Form`).
struct LoggingSettingsSection: View {
    @Environment(SettingsStore.self) private var settings

    static let intervals: [Double] = [0, 1, 2, 5, 10, 30, 60, 300]
    static let rotations: [LogRotation] = [.daily, .weekly, .sizeMB(10), .sizeMB(50), .sizeMB(100), .never]
    static let retentions: [Int] = [0, 7, 30, 90, 365]

    var body: some View {
        @Bindable var s = settings
        Section {
            Toggle(isOn: $s.log.enabled) { Text("Write a CSV log") }
            LabeledContent {
                HStack(spacing: 6) {
                    Text(verbatim: (settings.log.folderPath as NSString).abbreviatingWithTildeInPath)
                        .font(ThermikFont.mono).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button { chooseFolder() } label: { Text("Choose…") }
                    Button { reveal() } label: { Text("Reveal in Finder") }
                }
            } label: { Text("Folder") }
            // Each list also offers the stored value when it is not a preset (e.g. edited by `defaults write`).
            Picker(selection: $s.log.intervalSeconds) {
                ForEach(Self.withCurrent(Self.intervals, settings.log.intervalSeconds).sorted(), id: \.self) { v in
                    if v == 0 { Text("Every update").tag(v) } else { Text(verbatim: WindowFormat.duration(v)).tag(v) }
                }
            } label: { Text("Write a row every") }
            Picker(selection: $s.log.rotation) {
                ForEach(Self.withCurrent(Self.rotations, settings.log.rotation), id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: { Text("Start a new file") }
            Picker(selection: Binding(get: { settings.log.retentionDays ?? 0 },
                                      set: { settings.log.retentionDays = $0 == 0 ? nil : $0 })) {
                ForEach(Self.withCurrent(Self.retentions, settings.log.retentionDays ?? 0).sorted(), id: \.self) { d in
                    if d == 0 { Text("Keep all files").tag(d) } else { Text("Delete after \(d) days").tag(d) }
                }
            } label: { Text("Old files") }
        } header: {
            Text("CSV log")
        } footer: {
            Text("Temperatures are always written in °C with a “.” decimal separator. Thermik never deletes log files unless you choose a limit above, and then only its own Thermik-*.csv files in this folder.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(LogColumnGroup.allCases, id: \.self) { g in
                Toggle(isOn: Binding(get: { settings.log.include.contains(g) },
                                     set: { on in if on { settings.log.include.insert(g) } else { settings.log.include.remove(g) } })) {
                    Text(verbatim: g.title)
                }
            }
        } header: {
            Text("Columns")
        } footer: {
            if settings.log.include.contains(.sensors) {
                Text("Individual sensors: every visible sensor gets its own column.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func withCurrent<T: Equatable>(_ options: [T], _ current: T) -> [T] {
        options.contains(current) ? options : options + [current]
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.log.folderPath)
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.log.folderPath = url.path
    }

    /// Opens the folder in Finder; if it does not exist yet (created when logging starts), shows its parent.
    private func reveal() {
        var url = URL(fileURLWithPath: settings.log.folderPath)
        var isDir: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }
}
