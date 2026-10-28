// SensorsPage.swift — Thermik (MIT). Unit 8. Sensors page (SPEC §4.6 W3): group filter chips, a sortable / searchable
// SwiftUI Table (☆ pin, name, group, value, session min / avg / max, 5-minute sparkline, raw key hidden unless
// "Show raw SMC keys"), a context menu (pin, hide, exclude from Hottest, rename, set alert, copy) and the inspector
// (SensorInspector.swift). Rows observe their own LiveSensor, so a value change re-renders only that row's cells (§2.14).
// Pin / hide / exclude / rename go through SensorStore, which persists them in `sensors.overrides`.
import AppKit
import SwiftUI
import ThermikCore

struct SensorsPage: View {
    @Bindable var model: MainWindowModel
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @State private var sortOrder: [SensorSortComparator] = []
    @State private var columns = TableColumnCustomization<LiveSensor>()
    @State private var renaming: LiveSensor?
    @State private var renameText = ""

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if sensors.inventory?.catalogStatus.isHeuristic == true {
                    StatusBanner(kind: .info, symbol: "questionmark.circle",
                                 text: String(localized: "Approximate sensor names: this Mac's chip has no verified sensor list yet."))
                }
                GroupFilterChips(selection: $model.sensorGroupFilter)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if !sensors.isLoaded {
                SensorDataPlaceholder(height: 240).frame(maxHeight: .infinity)
            } else if rows.isEmpty && !model.sensorSearch.isEmpty {
                ContentUnavailableView.search(text: model.sensorSearch)
            } else {
                table(rows)
            }
        }
        .searchable(text: $model.sensorSearch, placement: .toolbar, prompt: Text("Search sensors"))
        .inspector(isPresented: $model.isInspectorShown) {
            SensorInspector(model: model, onRename: beginRename)
                .inspectorColumnWidth(min: 260, ideal: 310, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.isInspectorShown.toggle() } label: {
                    Label { Text("Inspector") } icon: { Image(systemName: "sidebar.trailing") }
                }
                .help(Text("Show or hide the inspector"))
            }
        }
        .alert(Text("Rename sensor"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { s in
            TextField(text: $renameText) { Text("Name") }
            Button { commitRename(s, renameText) } label: { Text("Rename") }
            Button { commitRename(s, nil) } label: { Text("Use the default name") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: { s in
            Text(verbatim: s.sensor.name(preferRussian: settings.preferRussian))
        }
        .onAppear { applyKeyColumnVisibility() }
        .onChange(of: settings.showRawKeys) { _, _ in applyKeyColumnVisibility() }
    }

    private var rows: [LiveSensor] {
        let query = model.sensorSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var r = sensors.sensors.filter { settings.showHiddenSensors || !$0.isHidden }
        if let g = model.sensorGroupFilter { r = r.filter { $0.sensor.displayGroup == g } }
        if !query.isEmpty {
            r = r.filter { s in
                s.displayName.lowercased().contains(query) || s.sensor.id.key.lowercased().contains(query)
                    || s.sensor.displayGroup.title.lowercased().contains(query)
            }
        }
        if !sortOrder.isEmpty { r.sort(using: sortOrder) }
        return r
    }

    private func table(_ rows: [LiveSensor]) -> some View {
        let unit = settings.effectiveUnit
        return Table(rows, selection: $model.selectedSensor, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn(Text(Image(systemName: "star")), sortUsing: SensorSortComparator(column: .pinned)) { s in
                PinCell(sensor: s)
            }
            .width(22)
            .customizationID("pin")
            TableColumn("Name", sortUsing: SensorSortComparator(column: .name)) { s in NameCell(sensor: s) }
                .width(min: 150, ideal: 240)
                .customizationID("name")
            TableColumn("Group", sortUsing: SensorSortComparator(column: .group)) { s in
                Text(verbatim: s.sensor.displayGroup.title).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 96)
            .customizationID("group")
            TableColumn("Value", sortUsing: SensorSortComparator(column: .value)) { s in ValueCell(sensor: s, unit: unit) }
                .width(min: 56, ideal: 70)
                .customizationID("value")
            TableColumn(Text(verbatim: StatLabel.min), sortUsing: SensorSortComparator(column: .min)) { s in StatCell(sensor: s, stat: .min, unit: unit) }
                .width(min: 44, ideal: 54)
                .customizationID("min")
            TableColumn(Text(verbatim: StatLabel.avg), sortUsing: SensorSortComparator(column: .avg)) { s in StatCell(sensor: s, stat: .avg, unit: unit) }
                .width(min: 44, ideal: 54)
                .customizationID("avg")
            TableColumn(Text(verbatim: StatLabel.max), sortUsing: SensorSortComparator(column: .max)) { s in StatCell(sensor: s, stat: .max, unit: unit) }
                .width(min: 44, ideal: 54)
                .customizationID("max")
            TableColumn("Last 5 min") { s in SparkCell(sensor: s) }
                .width(min: 60, ideal: 90)
                .customizationID("spark")
            TableColumn("Key", sortUsing: SensorSortComparator(column: .key)) { s in
                Text(verbatim: s.sensor.id.description).font(ThermikFont.mono).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .width(min: 60, ideal: 90)
            .customizationID("key")
            .defaultVisibility(.hidden)
        }
        .contextMenu(forSelectionType: SensorID.self) { ids in
            if let id = ids.first, let s = sensors.sensor(id) { contextMenu(s) }
        } primaryAction: { ids in
            guard let id = ids.first else { return }
            model.selectedSensor = id
            model.isInspectorShown = true
        }
        .thermikPlainRows()
    }

    @ViewBuilder private func contextMenu(_ s: LiveSensor) -> some View {
        Button { sensors.setPinned(s.id, !s.isPinned) } label: { s.isPinned ? Text("Unpin") : Text("Pin") }
        Button { sensors.setHidden(s.id, !s.isHidden) } label: { s.isHidden ? Text("Show") : Text("Hide") }
        if SensorStore.isHottestCandidate(s.sensor) {
            // A block excluded in Settings › Sensors wins over the sensor's own switch (SensorStore.isBlockExcluded:
            // its block, or any block for a die-wide maximum): say so instead of a toggle.
            if SensorStore.isBlockExcluded(s.sensor, settings.hottestExcludedGroups) {
                Button {} label: { Text("Hardware block excluded from Hottest") }.disabled(true)
            } else {
                Button { sensors.setExcludedFromHottest(s.id, !s.isExcludedFromHottest) } label: {
                    s.isExcludedFromHottest ? Text("Include in Hottest") : Text("Exclude from Hottest")
                }
            }
        }
        Button { beginRename(s) } label: { Text("Rename…") }
        Divider()
        Button { model.createAlert(for: .sensor(s.id)) } label: { Text("Set alert…") }
        Button { copyValue(s) } label: { Text("Copy value") }
            .disabled(s.value == nil)
        Divider()
        Button { model.selectedSensor = s.id; model.isInspectorShown = true } label: { Text("Show in inspector") }
    }

    private func beginRename(_ s: LiveSensor) {
        renameText = s.displayName
        renaming = s
    }

    private func commitRename(_ s: LiveSensor, _ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        sensors.rename(s.id, to: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        renaming = nil
    }

    private func copyValue(_ s: LiveSensor) {
        guard let v = s.value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(s.displayName): \(ThermikFormat.temp(v, unit: settings.effectiveUnit, decimals: 1))", forType: .string)
    }

    private func applyKeyColumnVisibility() {
        columns[visibility: "key"] = settings.showRawKeys ? .visible : .hidden
    }
}

// MARK: - Filter chips

private struct GroupFilterChips: View {
    @Binding var selection: DisplayGroup?
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        let groups = DisplayGroup.allCases.filter { g in sensors.sensors.contains { $0.sensor.displayGroup == g } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: String(localized: "All"), symbol: "square.grid.3x3", selected: selection == nil) { selection = nil }
                ForEach(groups, id: \.self) { g in
                    chip(title: g.title, symbol: g.symbol, selected: selection == g) { selection = selection == g ? nil : g }
                }
            }
        }
    }

    private func chip(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.fill.tertiary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Cells (each observes its own LiveSensor)

private struct PinCell: View {
    var sensor: LiveSensor
    @Environment(SensorStore.self) private var sensors
    var body: some View {
        Button { sensors.setPinned(sensor.id, !sensor.isPinned) } label: {
            Image(systemName: sensor.isPinned ? "star.fill" : "star")
                .foregroundStyle(sensor.isPinned ? AnyShapeStyle(Color(nsColor: .systemYellow)) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .help(sensor.isPinned ? Text("Unpin") : Text("Pin to the top of the popover"))
        .accessibilityLabel(sensor.isPinned ? Text("Unpin") : Text("Pin"))
    }
}

private struct NameCell: View {
    var sensor: LiveSensor
    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: sensor.displayName).lineLimit(1).truncationMode(.middle)
            if sensor.sensor.isHeuristic {
                Image(systemName: "questionmark.circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help(Text("Approximate sensor names"))
            }
            if sensor.isHidden {
                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
                    .help(Text("Hidden"))
            }
        }
        .foregroundStyle(sensor.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

private struct ValueCell: View {
    var sensor: LiveSensor
    var unit: UnitTemperature
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if let v = sensor.value {
                TemperatureText(celsius: v, scale: sensor.colorScale, font: ThermikFont.valueSmall, unit: unit)
                    .opacity(sensor.state == .stale ? 0.5 : 1)
            } else if sensor.state == .gated {
                Text("Sleeping").font(ThermikFont.caption).foregroundStyle(.secondary)
                    .help(Text("This CPU cluster is idle and powered down; it has no reading right now."))
            } else {
                Text(verbatim: "—").foregroundStyle(.tertiary)
            }
        }
    }
}

private struct StatCell: View {
    enum Stat { case min, avg, max }
    var sensor: LiveSensor
    var stat: Stat
    var unit: UnitTemperature
    var body: some View {
        let v: Double? = switch stat {
        case .min: sensor.minValue
        case .avg: sensor.averageValue
        case .max: sensor.maxValue
        }
        HStack {
            Spacer(minLength: 0)
            Text(verbatim: WindowFormat.temp(v, unit)).font(ThermikFont.valueSmall).foregroundStyle(.secondary)
        }
    }
}

private struct SparkCell: View {
    var sensor: LiveSensor
    @Environment(HistoryStore.self) private var history
    var body: some View {
        let _ = history.sparklineRevision
        Sparkline(values: history.sparkline(.sensor(sensor.id), points: 48), scale: sensor.colorScale, fill: false)
            .frame(height: 14)
    }
}

// MARK: - Sorting

/// Table sort descriptor. LiveSensor is main-actor isolated; Table and `sort(using:)` call `compare` on the main
/// thread only (rows are sorted inside the view body), hence `MainActor.assumeIsolated`.
struct SensorSortComparator: SortComparator {
    enum Column: Hashable, Sendable { case pinned, name, group, value, min, avg, max, key }
    var column: Column
    var order: SortOrder = .forward

    func compare(_ lhs: LiveSensor, _ rhs: LiveSensor) -> ComparisonResult {
        let column = self.column
        let r = MainActor.assumeIsolated { Self.forwardCompare(column, lhs, rhs) }
        guard order == .reverse else { return r }
        switch r {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    @MainActor private static func forwardCompare(_ c: Column, _ a: LiveSensor, _ b: LiveSensor) -> ComparisonResult {
        switch c {
        case .pinned: return compareBool(a.isPinned, b.isPinned, tie: a.displayName, b.displayName)
        case .name: return a.displayName.localizedStandardCompare(b.displayName)
        case .group:
            let ga = DisplayGroup.allCases.firstIndex(of: a.sensor.displayGroup) ?? 0
            let gb = DisplayGroup.allCases.firstIndex(of: b.sensor.displayGroup) ?? 0
            return ga == gb ? a.displayName.localizedStandardCompare(b.displayName) : (ga < gb ? .orderedAscending : .orderedDescending)
        case .value: return compareOptional(a.value, b.value)
        case .min: return compareOptional(a.minValue, b.minValue)
        case .avg: return compareOptional(a.averageValue, b.averageValue)
        case .max: return compareOptional(a.maxValue, b.maxValue)
        case .key: return a.sensor.id.description.localizedStandardCompare(b.sensor.id.description)
        }
    }

    /// Pinned first in forward order.
    private static func compareBool(_ a: Bool, _ b: Bool, tie ta: String, _ tb: String) -> ComparisonResult {
        if a == b { return ta.localizedStandardCompare(tb) }
        return a ? .orderedAscending : .orderedDescending
    }

    /// Missing values sort after present ones.
    private static func compareOptional(_ a: Double?, _ b: Double?) -> ComparisonResult {
        switch (a, b) {
        case let (x?, y?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }
}
