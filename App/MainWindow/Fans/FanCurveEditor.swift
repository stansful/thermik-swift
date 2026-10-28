// FanCurveEditor.swift — Thermik (MIT). Unit 8. Percent-based fan-curve editor (SPEC §4.9, DES §4.4 / §7.9), adapted
// from the design kit's rpm editor (research/design/kit/ThermikCharts.swift, Thermik's own MIT code).
//
// Model: Core `CurvePoint` (celsius, percent 0…100 of each fan's own [Mn, Mx]). The editor keeps `points` sorted by °C.
// Rendering is split in two layers, as in the kit's history chart (DES §4.2: hover in the chart content 60 % CPU →
// sibling overlay 6 %):
//   1. the chart (the kit's ChartFrame) — reads only the points, the release band, the minimum rule and the "now" rule;
//   2. a sibling `.overlay` (CurveHandlesLayer) — handles, the selection tooltip and the live operating point. It reads
//      the selection / drag state from `CurveEditorState`, which the chart body never reads.
// Input is captured by a transparent layer over the chart (drag, double-click); positions are mapped with the explicit
// linear domains (x = tempDomain, y = 0…100), so drawing and hit testing agree exactly.
//
// Interaction: drag the nearest point within 14 pt by the pointer's travel (grab offset kept; a click without a > 2 pt
// move only selects it; x stays between its neighbours ±1 °C, snaps 1 °C / 1 %);
// double-click empty space adds a point (≤ 12, not within 2 °C of another); Delete removes the selected point (never
// fewer than 2); arrows nudge 1 °C / 5 % (⌥ 5 °C / 20 %); Tab / ⇧Tab cycle points; Esc deselects; ⌘Z / ⇧⌘Z undo / redo
// through the window's UndoManager (Edit menu). VoiceOver: the value lists every point; increment / decrement adjust
// the selected point; named actions select the next / previous point, add or delete one.
import AppKit
import SwiftUI
import ThermikCore
import ThermikSMC

struct FanCurveEditor: View {
    @Binding var points: [CurvePoint]          // Core model: celsius, percent 0…100
    var fans: [FanDescriptor]                  // for the "≈ rpm" secondary labels (fan 0's range when fans differ)
    var tempDomain: ClosedRange<Double> = 30...105
    var liveCelsius: Double?                   // FanStore.curveInputC
    var livePercent: Double?                   // current fan 0 percent (actual rpm → percent(forRPM:))
    var below: BelowFirstPoint                 // left of the first point: the first speed, an "Auto (macOS)" or a "Stopped" zone
    var unit: UnitTemperature = .celsius       // display only; points stay in °C

    static let maxPoints = 12
    static let minPoints = 2

    @State private var state = CurveEditorState()
    @State private var undoTarget = CurveUndoTarget()
    @FocusState private var focused: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.thermikRamp) private var ramp

    private var refFan: FanDescriptor? { fans.first }

    var body: some View {
        chart
            .overlay(alignment: .topLeading) {
                CurveHandlesLayer(points: points, state: state, fan: refFan, tempDomain: tempDomain,
                                  liveCelsius: liveCelsius, livePercent: livePercent, unit: unit)
            }
            .padding(.top, 14)
            .overlay {
                RoundedRectangle(cornerRadius: ThermikMetrics.innerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(focused ? 0.5 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in deleteSelected() ? .handled : .ignored }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                nudge(press.key, big: press.modifiers.contains(.option)) ? .handled : .ignored
            }
            .onKeyPress(.tab, phases: .down) { press in cycle(backwards: press.modifiers.contains(.shift)) ? .handled : .ignored }
            .onKeyPress(.escape) {
                guard state.selected != nil else { return .ignored }
                state.selected = nil
                return .handled
            }
            .onKeyPress(KeyEquivalent("z"), phases: .down) { press in
                // Fallback when no Edit menu is installed (the menu's ⌘Z normally wins before the view sees the key).
                guard press.modifiers.contains(.command), let um = undoManager else { return .ignored }
                if press.modifiers.contains(.shift) { if um.canRedo { um.redo() } } else if um.canUndo { um.undo() }
                return .handled
            }
            .onChange(of: points.count) { _, n in
                if let s = state.selected, s >= n { state.selected = n > 0 ? n - 1 : nil }
            }
            .onDisappear { undoManager?.removeAllActions(withTarget: undoTarget) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Fan curve"))
            .accessibilityValue(Text(verbatim: accessibilityDescription))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: _ = nudge(.upArrow, big: false)
                case .decrement: _ = nudge(.downArrow, big: false)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Next point")) { _ = cycle(backwards: false, wrap: true) }
            .accessibilityAction(named: Text("Previous point")) { _ = cycle(backwards: true, wrap: true) }
            .accessibilityAction(named: Text("Delete point")) { _ = deleteSelected() }
            .accessibilityAction(named: Text("Add point")) { addPointBetweenSelectedAndNext() }
    }

    // MARK: Chart (reads only the data)

    private var chart: some View {
        let sorted = points
        let lo = tempDomain.lowerBound, hi = tempDomain.upperBound
        // Below the first point: the first percent, macOS (released) or stopped; above the last point: the last percent.
        var line: [CurvePoint] = sorted
        if let first = sorted.first, below == .minimum, first.celsius > lo { line.insert(CurvePoint(lo, first.percent), at: 0) }
        if let last = sorted.last, last.celsius < hi { line.append(CurvePoint(hi, last.percent)) }
        let zone = below != .minimum ? sorted.first.flatMap { $0.celsius > lo ? $0.celsius : nil } : nil
        let y = 0.0...100.0
        let percents: [Double] = [0, 25, 50, 75, 100]
        return ChartFrame(x: tempDomain, y: y,
                          xTicks: ChartTick.stride(tempDomain, by: 10) { ThermikFormat.temp($0, unit: unit) },
                          yTicks: percents.map { ChartTick(value: $0, label: WindowFormat.percent($0)) },
                          leadingYLabels: true,
                          trailingYLabels: refFan.map { f in
                              percents.map { ChartTick(value: $0, label: "≈ " + ThermikFormat.rpm(f.rpm(forPercent: $0))) }
                          } ?? []) { s in
            ZStack {
                if let zone {
                    ChartPath(x: [lo, zone], y: [100, 100], xDomain: tempDomain, yDomain: y, baseline: 0)
                        .fill(Color.secondary.opacity(0.09))
                }
                ChartPath(x: line.map(\.celsius), y: line.map(\.percent), xDomain: tempDomain, yDomain: y, baseline: 0)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom)
                        .in(s.areaRect(peak: line.map(\.percent).max() ?? 100, baseline: 0)))
                ChartPath(x: line.map(\.celsius), y: line.map(\.percent), xDomain: tempDomain, yDomain: y)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ChartPath.rule(y: 0, xDomain: tempDomain, yDomain: y)
                    .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                if let live = liveCelsius {
                    let x = min(max(live, lo), hi)
                    ChartPath(x: [x, x], y: [0, 100], xDomain: tempDomain, yDomain: y)
                        .stroke(ramp.ink(ThermalScale.soc.normalized(live)), lineWidth: 1)
                }
            }
            .chartPlot(s)
            if let zone {
                Group {
                    if below == .stop { Text("Fans stopped") } else { Text("Auto (macOS)") }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .position(x: (s.px(lo) + s.px(zone)) / 2, y: s.plot.midY)
            }
            if let f = refFan {
                ChartLabel(String(localized: "minimum ≈ \(WindowFormat.rpm(f.minRPM))"), size: 9, weight: .medium)
                    .placed(at: CGPoint(x: s.plot.maxX, y: s.py(0) - 2), anchor: .bottomTrailing)
                    .foregroundStyle(.secondary)
            }
            if let live = liveCelsius {
                ChartLabel(String(localized: "now \(ThermikFormat.temp(live, unit: unit))"), size: 9, weight: .semibold)
                    .placed(at: CGPoint(x: s.px(min(max(live, lo), hi)), y: s.plot.minY - 2), anchor: .bottom)
                    .foregroundStyle(.secondary)
            }
            // Input over the whole chart, in the chart's coordinates (the same as `state.plot`).
            Rectangle().fill(.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag($0) }
                    .onEnded { _ in endDrag() })
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .local)
                    .onEnded { addPoint(at: $0.location) })
                .onAppear { state.plot = s.plot }
                .onChange(of: s.plot) { _, n in state.plot = n }
        }
        .transaction { $0.animation = nil }
    }

    // MARK: Geometry (explicit linear domains)

    private func position(_ p: CurvePoint) -> CGPoint {
        CurveGeometry.position(p, plot: state.plot, domain: tempDomain)
    }

    private func value(at loc: CGPoint) -> (celsius: Double, percent: Double)? {
        let plot = state.plot
        guard plot.width > 1, plot.height > 1 else { return nil }
        let span = tempDomain.upperBound - tempDomain.lowerBound
        let c = tempDomain.lowerBound + Double((loc.x - plot.minX) / plot.width) * span
        let p = 100 * (1 - Double((loc.y - plot.minY) / plot.height))
        return (c, p)
    }

    private func nearest(to loc: CGPoint, within radius: CGFloat = 14) -> Int? {
        let hits = points.indices.map { ($0, hypot(position(points[$0]).x - loc.x, position(points[$0]).y - loc.y)) }
        guard let best = hits.min(by: { $0.1 < $1.1 }), best.1 <= radius else { return nil }
        return best.0
    }

    /// x bounds for point i: its neighbours ±1 °C, else the domain.
    private func xBounds(_ i: Int) -> ClosedRange<Double> {
        let lo = i > 0 ? points[i - 1].celsius + 1 : tempDomain.lowerBound
        let hi = i < points.count - 1 ? points[i + 1].celsius - 1 : tempDomain.upperBound
        return lo...max(lo, hi)
    }

    // MARK: Mouse

    private func drag(_ g: DragGesture.Value) {
        if state.dragging == nil {
            guard !state.dragMissed else { return }
            guard let i = nearest(to: g.startLocation) else {
                state.dragMissed = true
                state.selected = nil
                return
            }
            state.dragging = i
            state.selected = i
            state.dragOrigin = points
            // Grab offset: the point moves by the pointer's travel, not to the cursor (a handle is 11–14 pt wide,
            // ≈ 5 % / 1.5 °C), so a click off-centre does not move it.
            let pos = position(points[i])
            state.grabOffset = CGSize(width: pos.x - g.startLocation.x, height: pos.y - g.startLocation.y)
            state.dragMoved = false
            focused = true
        }
        // A plain click only selects (for arrow-key nudging): the curve changes once the pointer travelled > 2 pt.
        if !state.dragMoved {
            guard hypot(g.translation.width, g.translation.height) > 2 else { return }
            state.dragMoved = true
        }
        let target = CGPoint(x: g.location.x + state.grabOffset.width, y: g.location.y + state.grabOffset.height)
        guard let i = state.dragging, points.indices.contains(i), let v = value(at: target) else { return }
        let b = xBounds(i)
        var p = points
        p[i].celsius = min(max(v.celsius.rounded(), b.lowerBound), b.upperBound)
        p[i].percent = min(max(v.percent.rounded(), 0), 100)
        if p != points { points = p }
    }

    private func endDrag() {
        if let origin = state.dragOrigin, origin != points {
            undoTarget.registerRestore(origin, binding: $points, undoManager: undoManager,
                                       name: String(localized: "Move Curve Point"))
        }
        state.dragging = nil
        state.dragOrigin = nil
        state.dragMissed = false
        state.dragMoved = false
    }

    private func addPoint(at loc: CGPoint) {
        guard nearest(to: loc) == nil, let v = value(at: loc) else { return }
        let c = v.celsius.rounded()
        guard points.count < Self.maxPoints, tempDomain.contains(c), !points.contains(where: { abs($0.celsius - c) < 2 }) else {
            NSSound.beep()
            return
        }
        var p = points
        let i = p.firstIndex { $0.celsius > c } ?? p.count
        p.insert(CurvePoint(c, min(max(v.percent.rounded(), 0), 100)), at: i)
        undoTarget.set(p, binding: $points, undoManager: undoManager, name: String(localized: "Add Curve Point"))
        state.selected = i
        focused = true
    }

    private func addPointBetweenSelectedAndNext() {
        guard points.count < Self.maxPoints, points.count >= 2 else { return }
        let i = min(state.selected ?? 0, points.count - 2)
        let a = points[i], b = points[i + 1]
        guard b.celsius - a.celsius >= 4 else { return }
        var p = points
        p.insert(CurvePoint(((a.celsius + b.celsius) / 2).rounded(), ((a.percent + b.percent) / 2).rounded()), at: i + 1)
        undoTarget.set(p, binding: $points, undoManager: undoManager, name: String(localized: "Add Curve Point"))
        state.selected = i + 1
    }

    // MARK: Keyboard

    @discardableResult
    private func deleteSelected() -> Bool {
        guard let i = state.selected, points.indices.contains(i), points.count > Self.minPoints else { return false }
        var p = points
        p.remove(at: i)
        undoTarget.set(p, binding: $points, undoManager: undoManager, name: String(localized: "Delete Curve Point"))
        state.selected = p.isEmpty ? nil : min(i, p.count - 1)
        return true
    }

    private func nudge(_ key: KeyEquivalent, big: Bool) -> Bool {
        guard let i = state.selected, points.indices.contains(i) else { return false }
        let dc = big ? 5.0 : 1.0, dp = big ? 20.0 : 5.0
        var p = points
        let b = xBounds(i)
        switch key {
        case .leftArrow: p[i].celsius = max(p[i].celsius - dc, b.lowerBound)
        case .rightArrow: p[i].celsius = min(p[i].celsius + dc, b.upperBound)
        case .upArrow: p[i].percent = min(p[i].percent + dp, 100)
        case .downArrow: p[i].percent = max(p[i].percent - dp, 0)
        default: return false
        }
        if p != points {
            undoTarget.set(p, binding: $points, undoManager: undoManager, name: String(localized: "Move Curve Point"))
        }
        return true
    }

    /// Tab / ⇧Tab: next / previous point; at the ends the key is passed on so focus can leave the editor.
    private func cycle(backwards: Bool, wrap: Bool = false) -> Bool {
        guard !points.isEmpty else { return false }
        guard let s = state.selected else {
            state.selected = backwards ? points.count - 1 : 0
            return true
        }
        let next = backwards ? s - 1 : s + 1
        if points.indices.contains(next) { state.selected = next; return true }
        guard wrap else { state.selected = nil; return false }
        state.selected = backwards ? points.count - 1 : 0
        return true
    }

    private var accessibilityDescription: String {
        points.map { p in
            String(localized: "\(WindowFormat.number(p.celsius)) degrees \(WindowFormat.number(p.percent)) percent")
        }.joined(separator: ", ")
    }
}

// MARK: - Interaction state (outside the chart's inputs)

@MainActor @Observable final class CurveEditorState {
    var selected: Int?
    var dragging: Int?
    var plot: CGRect = .zero
    @ObservationIgnored var dragOrigin: [CurvePoint]?
    @ObservationIgnored var dragMissed = false
    /// Point position minus the mouse-down location (the drag keeps the handle where it was grabbed).
    @ObservationIgnored var grabOffset: CGSize = .zero
    /// The pointer left the 2 pt click slop: from now on the drag edits the point.
    @ObservationIgnored var dragMoved = false
}

enum CurveGeometry {
    static func position(_ p: CurvePoint, plot: CGRect, domain: ClosedRange<Double>) -> CGPoint {
        let span = max(domain.upperBound - domain.lowerBound, 1)
        let x = plot.minX + CGFloat((min(max(p.celsius, domain.lowerBound), domain.upperBound) - domain.lowerBound) / span) * plot.width
        let y = plot.minY + CGFloat(1 - min(max(p.percent, 0), 100) / 100) * plot.height
        return CGPoint(x: x, y: y)
    }
}

/// Undo / redo for discrete edits. `set` applies a value and registers its inverse (which itself registers the redo).
@MainActor final class CurveUndoTarget {
    func set(_ newValue: [CurvePoint], binding: Binding<[CurvePoint]>, undoManager: UndoManager?, name: String) {
        let old = binding.wrappedValue
        guard old != newValue else { return }
        binding.wrappedValue = newValue
        registerRestore(old, binding: binding, undoManager: undoManager, name: name)
    }

    /// The value already changed (a finished drag): register the way back to `old`.
    func registerRestore(_ old: [CurvePoint], binding: Binding<[CurvePoint]>, undoManager: UndoManager?, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.set(old, binding: binding, undoManager: undoManager, name: name)
        }
        undoManager.setActionName(name)
    }
}

// MARK: - Handles, tooltip and live point (sibling overlay layer)

private struct CurveHandlesLayer: View {
    var points: [CurvePoint]
    var state: CurveEditorState
    var fan: FanDescriptor?
    var tempDomain: ClosedRange<Double>
    var liveCelsius: Double?
    var livePercent: Double?
    var unit: UnitTemperature

    var body: some View {
        let plot = state.plot
        if plot.width > 1 {
            ZStack(alignment: .topLeading) {
                ForEach(points.indices, id: \.self) { i in
                    let big = i == state.selected || i == state.dragging
                    let pos = CurveGeometry.position(points[i], plot: plot, domain: tempDomain)
                    Circle()
                        .fill(big ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: big ? 14 : 11, height: big ? 14 : 11)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .position(pos)
                }
                if let c = liveCelsius, let p = livePercent {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .shadow(color: .black.opacity(0.25), radius: 1)
                        .position(CurveGeometry.position(CurvePoint(c, p), plot: plot, domain: tempDomain))
                        .accessibilityHidden(true)
                }
                if let i = state.dragging ?? state.selected, points.indices.contains(i) {
                    let pos = CurveGeometry.position(points[i], plot: plot, domain: tempDomain)
                    tooltip(points[i])
                        .fixedSize()
                        .position(x: min(max(pos.x, plot.minX + 70), plot.maxX - 70), y: max(pos.y - 22, plot.minY - 6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private func tooltip(_ p: CurvePoint) -> some View {
        var parts = [ThermikFormat.temp(p.celsius, unit: unit), WindowFormat.percent(p.percent)]
        if let fan { parts.append("≈ " + WindowFormat.rpm(fan.rpm(forPercent: p.percent))) }
        return Text(verbatim: parts.joined(separator: " · "))
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .thermikGlass(Capsule())
    }
}
