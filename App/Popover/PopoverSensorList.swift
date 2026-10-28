// PopoverSensorList.swift — Thermik (MIT). OWNER: Unit 7. Scrolling sensor list of the popover (SPEC §4.5):
// "Pinned" first, then collapsible display groups (count, hottest 5-min sparkline, hottest value) that remember their
// expanded state. Rows observe their own LiveSensor (only that row re-renders on a new value). Click → main window on
// that sensor; right-click → Pin / Unpin, Hide, Rename…, Show in Menu Bar, Set Alert…, Copy Value. Keyboard: Tab
// reaches the list, ↑/↓ move between rows and headers, Return/Space activates, Esc closes (or cancels a rename).
import SwiftUI
import AppKit
import ThermikCore

/// Keyboard focus target inside the list.
enum PopoverFocus: Hashable {
    case group(DisplayGroup)
    case sensor(SensorID, pinned: Bool)
}

struct PopoverSensorList: View {
    var maxHeight: CGFloat
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @AppStorage("popover.expandedGroups") private var expandedRaw = ""
    @State private var contentHeight: CGFloat = 0
    @State private var renaming: SensorID?
    @FocusState private var focus: PopoverFocus?

    var body: some View {
        let compact = settings.popoverDensity == .compact
        let pinned = sensors.pinned.filter { settings.showHiddenSensors || !$0.isHidden }
        let groups = sensors.groups
        // Measured height of the content; before the first measurement an estimate from the row metrics keeps the first
        // layout close to final (the panel is revealed once its size settles).
        let measured = contentHeight > 0 ? contentHeight : estimatedHeight(pinned: pinned, groups: groups, compact: compact)
        let overflow = measured > maxHeight + 0.5
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if !pinned.isEmpty {
                        Label("Pinned", systemImage: "star.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .frame(height: 24)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(pinned) { s in
                            PopoverSensorRow(sensor: s, compact: compact, focusID: .sensor(s.id, pinned: true),
                                             focus: $focus, renaming: $renaming)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(groups) { g in
                        PopoverGroupSection(group: g, expanded: expandedBinding(g.group), compact: compact,
                                            focus: $focus, renaming: $renaming)
                    }
                    if sensors.isLoaded && groups.isEmpty && pinned.isEmpty {
                        Text("No sensors to show")
                            .font(ThermikFont.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
                .padding(.horizontal, ThermikMetrics.gutter)
                .padding(.vertical, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: max(min(measured, maxHeight), 1))
            .scrollIndicators(overflow ? .automatic : .never)
            .scrollDisabled(!overflow)
            .modifier(ScrollEdgeFade(active: overflow))
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .upArrow ? -1 : 1, pinned: pinned, groups: groups) ? .handled : .ignored
            }
            .onChange(of: focus) { _, target in
                // Keep the keyboard-focused row visible while arrowing through a scrolling list.
                if let target, overflow { proxy.scrollTo(target) }
            }
        }
    }

    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }

    private func estimatedHeight(pinned: [LiveSensor], groups: [LiveSensorGroup], compact: Bool) -> CGFloat {
        let row = compact ? ThermikMetrics.compactRowHeight : ThermikMetrics.rowHeight
        let header = compact ? 26 : ThermikMetrics.groupHeaderHeight
        let open = expanded
        var h: CGFloat = 12
        if !pinned.isEmpty { h += 24 + CGFloat(pinned.count) * row + 9 }
        for g in groups {
            h += header
            if open.contains(g.group.rawValue) { h += CGFloat(g.sensors.count) * row }
        }
        return h
    }

    private func expandedBinding(_ g: DisplayGroup) -> Binding<Bool> {
        Binding(get: { expanded.contains(g.rawValue) }, set: { on in
            var set = expanded
            if on { set.insert(g.rawValue) } else { set.remove(g.rawValue) }
            expandedRaw = set.sorted().joined(separator: ",")
        })
    }

    /// Visible focus order: pinned rows, then each group header followed by its rows when expanded.
    private func order(pinned: [LiveSensor], groups: [LiveSensorGroup]) -> [PopoverFocus] {
        var out = pinned.map { PopoverFocus.sensor($0.id, pinned: true) }
        let open = expanded
        for g in groups {
            out.append(.group(g.group))
            if open.contains(g.group.rawValue) { out += g.sensors.map { .sensor($0.id, pinned: false) } }
        }
        return out
    }

    private func move(_ step: Int, pinned: [LiveSensor], groups: [LiveSensorGroup]) -> Bool {
        guard renaming == nil else { return false }
        let ids = order(pinned: pinned, groups: groups)
        guard !ids.isEmpty else { return false }
        guard let current = focus, let i = ids.firstIndex(of: current) else {
            focus = step > 0 ? ids.first : ids.last
            return true
        }
        let j = min(max(i + step, 0), ids.count - 1)
        focus = ids[j]
        return true
    }
}

/// Soft edges while the list scrolls: system scroll-edge effect on macOS 26+, a 12-pt gradient mask before.
private struct ScrollEdgeFade: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else if active {
            content.mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
        } else {
            content
        }
    }
}

/// A display group: live header + expanded rows.
struct PopoverGroupSection: View {
    let group: LiveSensorGroup
    @Binding var expanded: Bool
    var compact: Bool
    var focus: FocusState<PopoverFocus?>.Binding
    @Binding var renaming: SensorID?
    @Environment(HistoryStore.self) private var history
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let hottest = group.hottest
        let scale = hottest.map { ThermalScale($0.sensor.thermalClass) } ?? .soc
        let id = PopoverFocus.group(group.group)
        let isFocused = focus.wrappedValue == id
        VStack(spacing: 0) {
            SensorGroupHeaderLabel(symbol: group.group.symbol, title: group.group.title, count: group.sensors.count,
                                   history: compact ? nil : hottest.map { sparkline($0.id) },
                                   celsius: hottest?.value, scale: scale, unit: settings.effectiveUnit,
                                   expanded: expanded, showsSparkline: !compact,
                                   dimmed: sensors.showsStaleReadings,
                                   height: compact ? 26 : ThermikMetrics.groupHeaderHeight)
                .padding(.horizontal, 4)
                .background(isFocused ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { toggle() }
                .focusable(true, interactions: .activate)
                .focusEffectDisabled()
                .focused(focus, equals: id)
                .id(id)
                .onKeyPress(keys: [.return, .space]) { _ in toggle(); return .handled }
                .onKeyPress(keys: [.rightArrow]) { _ in if !expanded { toggle() }; return .handled }
                .onKeyPress(keys: [.leftArrow]) { _ in if expanded { toggle() }; return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(group.group.title))
                .accessibilityValue(Text(groupSpoken(hottest: hottest, scale: scale)))
                .accessibilityAddTraits([.isHeader, .isButton])
                .accessibilityAction { toggle() }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.sensors) { s in
                        PopoverSensorRow(sensor: s, compact: compact, focusID: .sensor(s.id, pinned: false),
                                         focus: focus, renaming: $renaming)
                            .padding(.leading, 26)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toggle() {
        withAnimation(ThermikMotion.unlessReduced(ThermikMotion.disclosure, reduceMotion)) { expanded.toggle() }
    }

    private func sparkline(_ id: SensorID) -> [Float] {
        _ = history.sparklineRevision                          // refresh with the cached sparkline (≈ 5 s)
        return history.sparkline(.sensor(id), points: Int(ThermikMetrics.sparklineWidth))
    }

    private func groupSpoken(hottest: LiveSensor?, scale: ThermalScale) -> String {
        let state = expanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        let count = String(localized: "\(group.sensors.count) sensors")
        guard let h = hottest, let v = h.value else { return count + ", " + state }
        return count + ", " + String(localized: "hottest \(h.displayName)") + " "
            + TemperatureText.spoken(v, scale: scale, unit: settings.effectiveUnit) + ", " + state
    }
}

/// One sensor row (observes its LiveSensor).
struct PopoverSensorRow: View {
    let sensor: LiveSensor
    var compact: Bool
    var focusID: PopoverFocus
    var focus: FocusState<PopoverFocus?>.Binding
    @Binding var renaming: SensorID?
    @Environment(HistoryStore.self) private var history
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AlertStore.self) private var alerts
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let unit = settings.effectiveUnit
        let scale = ThermalScale(sensor.sensor.thermalClass)
        let gated = sensor.state == .gated
        let dim = gated || sensor.state == .stale || sensors.showsStaleReadings
        let isFocused = focus.wrappedValue == focusID
        HStack(spacing: 8) {
            if renaming == sensor.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($fieldFocused)
                    .onSubmit { finishRename() }
                    .onExitCommand { renaming = nil }
                    .onAppear { draft = sensor.displayName; fieldFocused = true }
            } else {
                Text(sensor.displayName)
                    .font(ThermikFont.body)
                    .foregroundStyle(dim ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !compact {
                Sparkline(values: sparkline, scale: scale, fill: false)
                    .frame(width: ThermikMetrics.sparklineWidth, height: 14)
            }
            Group {
                if let v = sensor.value {
                    TemperatureText(celsius: v, scale: scale, font: ThermikFont.valueSmall, unit: unit, dimmed: dim)
                } else {
                    Text(verbatim: "—").font(ThermikFont.valueSmall).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: compact ? ThermikMetrics.compactRowHeight : ThermikMetrics.rowHeight)
        .background(isFocused ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .focusable(renaming != sensor.id, interactions: .activate)
        .focusEffectDisabled()
        .focused(focus, equals: focusID)
        .id(focusID)
        .onKeyPress(keys: [.return, .space]) { _ in
            guard renaming != sensor.id else { return .ignored }
            open(); return .handled
        }
        .help(gated ? Text("Sleeping") : Text(verbatim: ""))
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(sensor.displayName))
        .accessibilityValue(Text(spoken(scale: scale, unit: unit, gated: gated)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: sensor.isPinned ? Text("Unpin") : Text("Pin")) { sensors.setPinned(sensor.id, !sensor.isPinned) }
    }

    @ViewBuilder private var menu: some View {
        if sensor.isPinned {
            Button("Unpin") { sensors.setPinned(sensor.id, false) }
        } else {
            Button("Pin") { sensors.setPinned(sensor.id, true) }
        }
        Button("Hide") { sensors.setHidden(sensor.id, true) }
        Button("Rename…") { renaming = sensor.id }
        Button("Show in Menu Bar") { settings.menuBar.primary = .temperature(.sensor(sensor.id)) }
        Divider()
        Button("Set Alert…") {
            let id = sensor.id
            // The Alerts page opens its editor with a new rule for this sensor (like "Set alert…" on the Sensors page).
            panel.closeThen { alerts.requestNewRule(for: .sensor(id)); router.showMain(.alerts) }
        }
        Button("Copy Value") { copyValue() }
            .disabled(sensor.value == nil)
    }

    private var sparkline: [Float] {
        _ = history.sparklineRevision                          // refresh with the cached sparkline (≈ 5 s)
        return history.sparkline(.sensor(sensor.id), points: Int(ThermikMetrics.sparklineWidth))
    }

    private func open() {
        guard renaming != sensor.id else { return }
        let id = sensor.id
        panel.closeThen { router.showMain(.sensors(id)) }
    }

    private func finishRename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = sensor.sensor.name(preferRussian: settings.preferRussian)
        sensors.rename(sensor.id, to: name.isEmpty || name == original ? nil : name)
        renaming = nil
    }

    private func copyValue() {
        guard let v = sensor.value else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(ThermikFormat.tempWithUnit(v, unit: settings.effectiveUnit), forType: .string)
    }

    private func spoken(scale: ThermalScale, unit: UnitTemperature, gated: Bool) -> String {
        if gated { return String(localized: "Sleeping") }
        guard let v = sensor.value else { return String(localized: "No data") }
        return TemperatureText.spoken(v, scale: scale, unit: unit)
    }
}
