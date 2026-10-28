// DiagnosticsPage.swift — Thermik (MIT). Unit 8. Diagnostics page (SPEC §4.6 W7, §2.13): one card per DiagnosticItem
// (status glyph, localized finding, expandable raw details in SF Mono), "Run fan test" (P1, helper required),
// "Load sleep/wake history" (pmset log on demand, last 200 events in a table), Copy report / Save report….
// Core returns structured findings; every sentence shown here is localized in this file.
import AppKit
import SwiftUI
import ThermikCore
import UniformTypeIdentifiers

struct DiagnosticsPage: View {
    @Environment(DiagnosticsStore.self) private var diagnostics
    @State private var copied = false

    var body: some View {
        PageScroll {
            header
            if diagnostics.items.isEmpty {
                PageCard(title: String(localized: "Diagnostics")) {
                    Text("Checks run in the background and appear here shortly after launch.")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: ThermikMetrics.gutter, alignment: .top)],
                          alignment: .leading, spacing: ThermikMetrics.gutter) {
                    ForEach(diagnostics.items) { DiagnosticCard(item: $0) }
                }
            }
            FanTestCard()
            PowerLogCard()
        }
        .onAppear { diagnostics.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let overall = diagnostics.overall
            Image(systemName: overall.symbol).font(.system(size: 22)).foregroundStyle(DiagnosticColors.color(overall))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: overallTitle(overall)).font(.system(size: 15, weight: .semibold))
                Text("Hardware checks are free and run locally. Nothing leaves this Mac.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { diagnostics.refresh() } label: { Label { Text("Refresh") } icon: { Image(systemName: "arrow.clockwise") } }
            Button { copyReport() } label: {
                Label { copied ? Text("Copied") : Text("Copy report") } icon: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            }
            Button { saveReport() } label: { Text("Save report…") }
        }
        .accessibilityElement(children: .contain)
    }

    private func overallTitle(_ s: DiagnosticStatus) -> String {
        switch s {
        case .ok: String(localized: "Everything looks fine")
        case .info: String(localized: "Everything looks fine, with notes")
        case .unknown: String(localized: "Some checks have not run yet")
        case .warning: String(localized: "Some checks need attention")
        case .error: String(localized: "A problem was found")
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.makeReport(), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func saveReport() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "Thermik-diagnostics-\(stamp).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(diagnostics.makeReport().utf8).write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }
}

// MARK: - One item

private struct DiagnosticCard: View {
    var item: DiagnosticItem
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(HelperManager.self) private var helper
    @Environment(DiagnosticsStore.self) private var diagnostics
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.status.symbol).foregroundStyle(DiagnosticColors.color(item.status))
                    .font(.system(size: 15))
                Text(verbatim: item.id.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: item.status.title)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(DiagnosticColors.color(item.status).opacity(0.15), in: Capsule())
            }
            Text(verbatim: DiagnosticFindingText.finding(item.finding, fanName: fanName, sensorName: sensorName, unit: settings.effectiveUnit))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            // The helper card fixes what it reports: Install / Update / Open Login Items / Retry, as in the popover.
            if item.id == .helper, let availability = helper.availability {
                HelperQuickAction(availability: availability)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            if !item.details.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.details, id: \.self) { d in
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: d.label).font(ThermikFont.mono).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(verbatim: d.value).font(ThermikFont.mono).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Details").font(ThermikFont.caption)
                }
            }
            Text(verbatim: String(localized: "Checked \(item.updated.formatted(date: .omitted, time: .shortened))"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .thermikCard()
        .accessibilityElement(children: .contain)
        .onChange(of: helper.availability) { _, _ in
            if item.id == .helper { diagnostics.refresh() }               // the card shows the new state at once
        }
    }

    private func fanName(_ i: Int) -> String {
        fans.fans.first { $0.id == i }?.localizedName ?? String(localized: "Fan \(i + 1)")
    }
    private func sensorName(_ id: SensorID) -> String { sensors.sensor(id)?.displayName ?? id.description }
}

/// Localized finding sentences (Core findings are structured, never text).
enum DiagnosticFindingText {
    @MainActor static func finding(_ f: DiagnosticFinding, fanName: (Int) -> String, sensorName: (SensorID) -> String,
                                   unit: UnitTemperature) -> String {
        switch f {
        case .shutdown(let verdict, let panicLog):
            let base = String(localized: "Last shutdown: \(verdict.title).")
            return panicLog ? base + " " + String(localized: "A panic report was saved by macOS.") : base
        case .fansOK(let count):
            return String(localized: "\(count) fans respond normally.")
        case .fanless:
            return String(localized: "Passively cooled — no fans")
        case .fansStalled(let ids):
            let names = ids.map(fanName).joined(separator: ", ")
            return String(localized: "Not spinning although asked to: \(names).")
        case .fansNotReachingTarget(let ids):
            let names = ids.map(fanName).joined(separator: ", ")
            return String(localized: "Not reaching the requested speed: \(names).")
        case .sensorsOK(let count):
            return String(localized: "\(count) sensors report plausible values.")
        case .sensorsSuspect(let ids):
            let names = ids.prefix(5).map(sensorName).joined(separator: ", ")
            let more = ids.count > 5 ? " " + String(localized: "and \(ids.count - 5) more") : ""
            return String(localized: "Suspicious readings (stuck, out of range or missing): \(names)\(more).")
        case .battery(let condition, let health, let cycles, let rated):
            var parts = [condition.title]
            if let health { parts.append(String(localized: "health \(WindowFormat.percent(health))")) }
            if let cycles { parts.append(String(localized: "\(cycles) of \(rated ?? 1000) cycles")) }
            return parts.joined(separator: " · ")
        case .noBattery:
            return String(localized: "This Mac has no battery.")
        case .thermal(let p, let events):
            return String(localized: "Thermal pressure now: \(p.title). Pressure events today: \(events).")
        case .storage(let used, let temp, let critical):
            if critical { return String(localized: "The drive reports a critical warning. Back up your data.") }
            var parts: [String] = []
            if let used { parts.append(String(localized: "wear \(WindowFormat.percent(Double(used)))")) }
            if let temp { parts.append(String(localized: "temperature \(ThermikFormat.temp(Double(temp), unit: unit))")) }
            return parts.isEmpty ? String(localized: "Drive health is not available.") : parts.joined(separator: " · ")
        case .helper(let h):
            return helperText(h)
        case .smc(let available, let keyCount, let catalog):
            return available ? String(localized: "SMC readable: \(keyCount) keys. \(catalog.title).")
                             : String(localized: "The SMC could not be opened, so temperatures are unavailable.")
        case .unknown:
            return String(localized: "Not checked yet.")
        }
    }

    static func helperText(_ h: HelperHealth) -> String {
        switch h {
        case .ready(let v): String(localized: "Helper \(v) is running.")
        case .notInstalled: String(localized: "Helper not installed: monitoring only.")
        case .requiresApproval: String(localized: "Approve Thermik in System Settings › Login Items")
        case .needsUpgrade: String(localized: "The helper needs an update")
        case .unreachable(let why): String(localized: "The helper is not responding (\(why)).")
        case .foreignController(let name):
            foreignControllerText(name ?? String(localized: "another app"))
        case .notApplicable: String(localized: "Not needed: this Mac has no fans.")
        }
    }

    static func foreignControllerText(_ who: String) -> String {
        String(localized: "Fan control is in use by \(who). Quit it to let Thermik control the fans.")
    }
}

// MARK: - Fan test (P1)

private struct FanTestCard: View {
    @Environment(FanStore.self) private var fans
    @State private var confirm = false
    @State private var running = false

    var body: some View {
        if fans.hasFans {
            PageCard(title: String(localized: "Fan test"), symbol: "fan") {
                HStack(spacing: 12) {
                    Text("Spins each fan to its maximum for 10 seconds, then returns to the current mode.")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    if running { ProgressView().controlSize(.small) }
                    Button { confirm = true } label: { Text("Run fan test…") }
                        .disabled(!fans.canControl || running)
                        .help(fans.canControl ? Text("Run the fan test") : Text("Fan control needs the Thermik helper"))
                }
            }
            .confirmationDialog(Text("Run the fan test?"), isPresented: $confirm) {
                Button { run() } label: { Text("Run Test") }
                Button(role: .cancel) {} label: { Text("Cancel") }
            } message: {
                Text("The fans will be loud for about 10 seconds per fan.")
            }
        }
    }

    private func run() {
        running = true
        Task { @MainActor in
            await fans.runFanTest()
            running = false
        }
    }
}

// MARK: - Sleep / wake history

private struct PowerLogCard: View {
    @Environment(DiagnosticsStore.self) private var diagnostics

    var body: some View {
        PageCard(title: String(localized: "Sleep and wake history"), symbol: "moon.zzz") {
            if diagnostics.isLoadingPowerLog { ProgressView().controlSize(.small) }
            Button { Task { await diagnostics.loadPowerLog() } } label: { Text("Load sleep/wake history") }
                .disabled(diagnostics.isLoadingPowerLog)
        } content: {
            let events = Array(diagnostics.powerLog.suffix(200).reversed())
            if events.isEmpty {
                Text("Reads the macOS power log on demand (a few seconds). Shows the last 200 sleep, wake and thermal events.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            } else {
                Table(events.enumerated().map { PowerLogRow(id: $0.offset, event: $0.element) }) {
                    TableColumn("Time") { r in Text(verbatim: WindowFormat.dateTime(r.event.date)).font(ThermikFont.mono) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Event") { r in Text(verbatim: r.event.kind) }
                        .width(min: 70, ideal: 100)
                    TableColumn("Details") { r in Text(verbatim: r.event.message).font(ThermikFont.mono).lineLimit(1).help(Text(verbatim: r.event.message)) }
                }
                .thermikPlainRows()
                .frame(height: 280)
            }
        }
    }
}

private struct PowerLogRow: Identifiable {
    let id: Int
    let event: PowerLogEvent
}
