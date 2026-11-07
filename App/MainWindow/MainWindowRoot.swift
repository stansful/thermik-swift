// MainWindowRoot.swift — Thermik (MIT). NavigationSplitView main window:
// source-list sidebar (Overview, Sensors, Fans, Battery, System, Diagnostics, Logs, Alerts, then Settings in
// its own section) with badges and a footer (model, chip, helper status dot); toolbar with the history range
// (5 m…24 h), export and the stale chip. Settings are a page of this window, not a window of their own.
// Pages live in App/MainWindow/<Page>/; navigation state in MainWindowModel (owned by WindowManager).
import AppKit
import SwiftUI
import ThermikCore
import UniformTypeIdentifiers

struct MainWindowRoot: View {
    @Bindable var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        NavigationSplitView {
            MainSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            PageContainer(model: model)
        }
        .navigationTitle(Text(verbatim: system.machine?.marketingName ?? "Thermik"))
        .navigationSubtitle(Text(verbatim: model.page == .settings ? model.page.title + " · " + model.settingsTab.title : model.page.title))
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: availablePages) { _, pages in
            if !pages.contains(model.page) { model.page = .overview }
        }
    }

    /// Fans only with fans; Battery only on laptops (both become known after discovery / the first system tick).
    private var availablePages: [Route.Page] {
        Route.Page.allCases.filter { p in
            switch p {
            case .fans: return fans.hasFans || !sensors.isLoaded
            case .battery: return system.hasBattery
            default: return true
            }
        }
    }
}

// MARK: - Sidebar

private struct MainSidebar: View {
    @Bindable var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors
    @Environment(DiagnosticsStore.self) private var diagnostics
    @Environment(AlertStore.self) private var alerts
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        List(selection: Binding<Route.Page?>(get: { model.page }, set: { if let p = $0 { model.page = p } })) {
            Section {
                ForEach(pages, id: \.self) { page in
                    Label(page.title, systemImage: page.symbol)
                        .badge(badge(page))
                        .tag(page)
                        .help(Text(verbatim: "⌘\(page.shortcutDigit)"))
                }
            }
            Section {
                Label(Route.Page.settings.title, systemImage: Route.Page.settings.symbol)
                    .tag(Route.Page.settings)
                    .help(Text(verbatim: "⌘,"))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }

    private var pages: [Route.Page] {
        Route.Page.contentPages.filter { p in
            switch p {
            case .fans: fans.hasFans
            case .battery: system.hasBattery
            default: true
            }
        }
    }

    /// Sensors: hottest value; Fans: ◆ while Thermik holds them; Diagnostics: warnings; Alerts: alerts today.
    private func badge(_ page: Route.Page) -> Text? {
        switch page {
        case .sensors: return sensorBadge()
        case .fans: return fans.isOverriding ? Text(verbatim: "◆") : nil
        case .diagnostics: return countBadge(diagnostics.items.filter { $0.status >= .warning }.count)
        case .alerts: return countBadge(alerts.alertsToday)
        default: return nil
        }
    }

    private func sensorBadge() -> Text? {
        guard let v = sensors.hottest?.value else { return nil }
        return Text(verbatim: ThermikFormat.temp(v, unit: settings.effectiveUnit))
    }

    private func countBadge(_ count: Int) -> Text? {
        guard count > 0 else { return nil }
        return Text(verbatim: "\(count)")
    }
}

/// Model id, chip and the helper status dot (green ready / orange needs action / grey not installed).
private struct SidebarFooter: View {
    @Environment(SystemStore.self) private var system
    @Environment(SensorStore.self) private var sensors
    @Environment(HelperManager.self) private var helper
    @Environment(FanStore.self) private var fans
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: system.machine?.modelIdentifier ?? sensors.inventory?.identity.modelIdentifier ?? "—")
                        .font(.system(size: 11, weight: .semibold))
                    Text(verbatim: system.machine?.chip ?? sensors.inventory?.identity.chipName ?? "")
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                    if fans.hasFans {
                        HStack(spacing: 5) {
                            StatusDot(color: helperColor)
                            Text(verbatim: helperText).font(ThermikFont.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Button { router.showSettings(nil) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help(Text("Settings…"))
                    .accessibilityLabel(Text("Settings…"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    private var helperColor: Color { HelperStatusColor.color(helper.state) }

    private var helperText: String {
        switch helper.state {
        case .ready: String(localized: "Fan control ready")
        case .requiresApproval: String(localized: "Helper needs approval")
        case .needsUpgrade: String(localized: "Helper needs an update")
        case .unreachable: String(localized: "Helper not responding")
        case .notInstalled: String(localized: "Monitoring only")
        case .unknown: String(localized: "Checking the helper…")
        }
    }
}

// MARK: - Detail + toolbar

private struct PageContainer: View {
    @Bindable var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        Group {
            switch model.page {
            case .overview: OverviewPage(model: model)
            case .sensors: SensorsPage(model: model)
            case .fans: FansPage()
            case .battery: BatteryPage(model: model)
            case .system: SystemPage(model: model)
            case .diagnostics: DiagnosticsPage()
            case .logs: LogsPage(model: model)
            case .alerts: AlertsPage(model: model)
            case .settings: SettingsPage(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            if sensors.isLoaded && sensors.isStale {
                ToolbarItem(placement: .navigation) {
                    Label { Text("Paused") } icon: { Image(systemName: "pause.circle") }
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help(Text("Readings are not updating right now."))
                }
            }
            if model.page.showsHistoryRange {
                ToolbarItem(placement: .primaryAction) {
                    Picker(selection: $model.historyWindow) {
                        ForEach(HistoryWindow.allCases) { Text($0.title).tag($0) }
                    } label: { Text("History range") }
                    .pickerStyle(.segmented)
                    .help(Text("History range"))
                }
            }
            if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            if model.page == .overview || model.page == .sensors {
                ToolbarItem(placement: .primaryAction) { HistoryExportMenu(model: model) }
            }
        }
    }
}

/// Export the visible range of history (P1) as CSV or JSON.
private struct HistoryExportMenu: View {
    var model: MainWindowModel
    @Environment(HistoryStore.self) private var history
    @Environment(SensorStore.self) private var sensors
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Menu {
            Button { exportCSV() } label: { Text("Export as CSV…") }
            Button { exportJSON() } label: { Text("Export as JSON…") }
        } label: {
            Label { Text("Export") } icon: { Image(systemName: "square.and.arrow.up") }
        }
        .help(Text("Export the history shown in the window"))
    }

    private var seriesIDs: [SeriesID] {
        var ids: [SeriesID] = [.aggregate(.cpuAverage), .aggregate(.cpuHottest), .aggregate(.gpuAverage),
                               .aggregate(.socHottest), .aggregate(.highestAll), .power(.systemTotal), .pressure]
        ids += fans.fans.flatMap { [SeriesID.fanRPM($0.id), .fanTarget($0.id)] }
        if model.page == .sensors {
            ids += sensors.sensors.filter { settings.showHiddenSensors || !$0.isHidden }.map { .sensor($0.id) }
        }
        return ids
    }

    private func exportCSV() {
        save(history.exportCSV(seriesIDs, window: model.historyWindow), fileExtension: "csv", contentType: .commaSeparatedText)
    }

    private func exportJSON() {
        save(history.exportJSON(seriesIDs, window: model.historyWindow), fileExtension: "json", contentType: .json)
    }

    private func save(_ data: Data, fileExtension: String, contentType: UTType) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "Thermik-history-\(stamp).\(fileExtension)"
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }
}
