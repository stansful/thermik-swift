// SensorInspector.swift — Thermik (MIT). Unit 8. Sensors inspector (SPEC §4.6 W3, P1): big value + level, history chart
// for the toolbar range, session and range statistics, and the technical identity of the reading (raw key, source,
// SMC type, role, hardware block, raw decoded value, "approximate name" badge for heuristic sensors), and the actions
// (pin, hide, rename, alert, statistics; die sensors: exclude from / include in "Hottest", or switch its excluded
// hardware block back on).
// While it is open, WindowManager reports the sensor as `visibility.inspectedSensor` so it is sampled every tick.
import AppKit
import SwiftUI
import ThermikCore

struct SensorInspector: View {
    var model: MainWindowModel
    var onRename: (LiveSensor) -> Void
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        if let id = model.selectedSensor, let s = sensors.sensor(id) {
            SensorInspectorContent(sensor: s, model: model, onRename: onRename)
        } else {
            ContentUnavailableView {
                Label { Text("No sensor selected") } icon: { Image(systemName: "thermometer.medium") }
            } description: {
                Text("Select a sensor in the table to see its history and details.")
            }
        }
    }
}

private struct SensorInspectorContent: View {
    var sensor: LiveSensor
    var model: MainWindowModel
    var onRename: (LiveSensor) -> Void
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(HistoryStore.self) private var history

    var body: some View {
        let unit = settings.effectiveUnit
        let scale = sensor.colorScale
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: sensor.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(verbatim: sensor.sensor.displayGroup.title).font(ThermikFont.caption).foregroundStyle(.secondary)
                    if sensor.sensor.isHeuristic {
                        Label { Text("Approximate sensor names") } icon: { Image(systemName: "questionmark.circle") }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.fill.tertiary, in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let v = sensor.value {
                        TemperatureText(celsius: v, scale: scale, font: ThermikFont.hero, unit: unit)
                        LevelBadge(level: scale.level(v, unit: unit))
                    } else if sensor.state == .gated {
                        Text("Sleeping").font(ThermikFont.display).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "—").font(ThermikFont.hero).foregroundStyle(.tertiary)
                    }
                }
                HistoryChartPanel(series: [HistorySeriesSpec(id: .sensor(sensor.id), name: sensor.displayName,
                                                              color: ThermikPalette.vivid(0.75))],
                                  window: model.historyWindow, yDomain: nil, showsThresholds: scale == .soc, height: 150,
                                  accessibilityTitle: sensor.displayName)
                statistics(unit: unit)
                details
                actions
            }
            .padding(14)
        }
    }

    private func statistics(unit: UnitTemperature) -> some View {
        let range = history.stats(.sensor(sensor.id), window: model.historyWindow)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Statistics").font(ThermikFont.sectionTitle).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(verbatim: "")
                    Text(verbatim: StatLabel.min).gridColumnAlignment(.trailing)
                    Text(verbatim: StatLabel.avg).gridColumnAlignment(.trailing)
                    Text(verbatim: StatLabel.max).gridColumnAlignment(.trailing)
                }
                .font(ThermikFont.caption).foregroundStyle(.secondary)
                GridRow {
                    Text("Since launch").font(ThermikFont.caption).foregroundStyle(.secondary)
                    statText(sensor.minValue, unit); statText(sensor.averageValue, unit); statText(sensor.maxValue, unit)
                }
                GridRow {
                    Text(model.historyWindow.title).font(ThermikFont.caption).foregroundStyle(.secondary)
                    statText(range.map { Double($0.min) }, unit); statText(range.map { Double($0.avg) }, unit)
                    statText(range.map { Double($0.max) }, unit)
                }
            }
        }
    }

    private func statText(_ v: Double?, _ unit: UnitTemperature) -> some View {
        Text(verbatim: WindowFormat.temp(v, unit, decimals: 1)).font(ThermikFont.valueSmall)
    }

    private var details: some View {
        let s = sensor.sensor
        return VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(ThermikFont.sectionTitle).foregroundStyle(.secondary)
            DetailRow(label: String(localized: "Key"), value: s.id.key, monospaced: true)
            DetailRow(label: String(localized: "Source"), value: s.id.source.title)
            if let type = s.smcType { DetailRow(label: String(localized: "SMC type"), value: type, monospaced: true) }
            DetailRow(label: String(localized: "Role"), value: s.role.title)
            DetailRow(label: String(localized: "Hardware block"), value: s.group.title)
            if let c = s.descriptor.cluster { DetailRow(label: String(localized: "Cluster"), value: "\(c + 1)") }
            DetailRow(label: String(localized: "Raw value"),
                      value: sensor.rawValue.map { WindowFormat.number($0, decimals: 2) } ?? "—", monospaced: true)
            DetailRow(label: String(localized: "Default name"), value: s.name(preferRussian: settings.preferRussian))
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { sensors.setPinned(sensor.id, !sensor.isPinned) } label: { sensor.isPinned ? Text("Unpin") : Text("Pin") }
                Button { sensors.setHidden(sensor.id, !sensor.isHidden) } label: { sensor.isHidden ? Text("Show") : Text("Hide") }
                Button { onRename(sensor) } label: { Text("Rename…") }
            }
            HStack {
                Button { model.createAlert(for: .sensor(sensor.id)) } label: { Text("Set alert…") }
                Button { sensor.resetStatistics() } label: { Text("Reset statistics") }
            }
            hottestAction
        }
        .controlSize(.small)
    }

    /// Die sensors only (the ones "Hottest" is chosen from). When Settings › Sensors' blocks already exclude it (its
    /// block, or any block for a die-wide maximum: SensorStore.excludingBlocks), the sensor's own switch would change
    /// nothing visible, so the inspector says which block and offers to switch it (all of them for a die-wide
    /// maximum) back on. The caption names the block when there is one, as the Sensors context menu does: it can
    /// differ from "Hardware block" above (cluster summaries). The button leaves the sensor's own flag alone, so the
    /// caption also says when that flag keeps it out.
    @ViewBuilder private var hottestAction: some View {
        let blocks = SensorStore.excludingBlocks(sensor.sensor, settings.hottestExcludedGroups)
        if SensorStore.isHottestCandidate(sensor.sensor) {
            if !blocks.isEmpty {
                let single = blocks.count == 1 ? blocks.first : nil
                VStack(alignment: .leading, spacing: 2) {
                    if !SensorStore.isDieWideMaximum(sensor.sensor) {
                        Text("It goes with the “\(SensorStore.hottestBlock(sensor.sensor).title)” block, which is excluded from Hottest in Settings › Sensors.")
                    } else if let single {
                        Text("It spans every hardware block, so it is left out of Hottest while the “\(single.title)” block is off in Settings › Sensors.")
                    } else {
                        Text("It spans every hardware block, so it is left out of Hottest while any block is off in Settings › Sensors.")
                    }
                    if sensor.isExcludedFromHottest { Text("It is also excluded on its own.") }
                }
                .font(ThermikFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button { settings.hottestExcludedGroups.subtract(blocks) } label: {
                    single != nil ? Text("Include this block") : Text("Include every block")
                }
                .help(single != nil ? Text("Switches the block back on in Settings › Sensors. Sensors excluded on their own stay out of Hottest.")
                                    : Text("Switches every block back on in Settings › Sensors."))
            } else {
                Button { sensors.setExcludedFromHottest(sensor.id, !sensor.isExcludedFromHottest) } label: {
                    sensor.isExcludedFromHottest ? Text("Include in Hottest") : Text("Exclude from Hottest")
                }
                .help(Text("Only the Hottest value ignores an excluded sensor; alerts, fan curves and the safety override still use it."))
            }
        }
    }
}
