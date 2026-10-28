// FanCurveSection.swift — Thermik (MIT). Unit 8. The curve card of the Fans page (SPEC §4.6 W4, §4.9): power-source
// tabs (adapter / battery, P1), preset menu, driving-sensor picker ("Specific sensor…"), hysteresis, ramp-up / ramp-down
// times, "Release to macOS below the first point", the FanCurveEditor with the live operating point, and the floating
// glass [Revert] [Apply] bar that appears only with unsaved changes.
//
// Editing works on a draft per power source; the stored curve (SettingsStore.fans via FanStore.config) is changed only
// by Apply (`fans.applyCurve`, after `FanControlEngine.normalized` + the local sanitizer) or by picking a preset
// (`fans.applyPreset`). Any edit clears `presetID` (the curve becomes "Custom").
import AppKit
import SwiftUI
import ThermikCore
import ThermikSMC

@MainActor @Observable final class CurveDraftModel {
    var power: PowerSourceKind = .ac
    /// Unsaved edits per power source (nil = showing the stored curve).
    var drafts: [PowerSourceKind: FanCurve] = [:]
    var pendingPreset: FanPresetID?
    var choosingSensor = false
}

enum FanCurveSection {
    /// Page body for the Fans page: `top` content, the curve card and the helper card in a scroll view, plus the
    /// floating Apply / Revert bar.
    struct Container<Top: View>: View {
        @ViewBuilder var top: Top
        @State private var model = CurveDraftModel()
        @Environment(FanStore.self) private var fans

        var body: some View {
            let stored = CurveCard.stored(fans.config, model.power)
            let dirty = model.drafts[model.power].map { $0 != stored } ?? false
            ZStack(alignment: .bottom) {
                PageScroll {
                    top
                    CurveCard(model: model)
                    HelperControlCard()
                    Color.clear.frame(height: dirty ? 56 : 0)
                }
                if dirty {
                    CurveApplyBar(onRevert: { model.drafts[model.power] = nil },
                                  onApply: { CurveCard.apply(model: model, fans: fans) })
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.28), value: dirty)
        }
    }
}

// MARK: - Curve card

private struct CurveCard: View {
    @Bindable var model: CurveDraftModel
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors
    @Environment(SettingsStore.self) private var settings

    static let drivingAggregates: [AggregateKind] = [.cpuAverage, .cpuHottest, .gpuAverage, .gpuHottest, .socHottest,
                                                     .socDie, .highestAll, .safetyTop4, .memory, .ssd, .battery]

    static func stored(_ config: FanUserConfig, _ power: PowerSourceKind) -> FanCurve {
        power == .battery ? (config.curveBattery ?? config.curveAC) : config.curveAC
    }

    static func apply(model: CurveDraftModel, fans: FanStore) {
        guard var curve = model.drafts[model.power] else { return }
        curve.points = CurveSanitizer.clean(FanControlEngine.normalized(curve.points))
        fans.applyCurve(curve, for: model.power == .battery ? .battery : .ac)
        model.drafts[model.power] = nil
    }

    var body: some View {
        let stored = Self.stored(fans.config, model.power)
        let curve = model.drafts[model.power] ?? stored
        let separateBattery = fans.config.curveBattery != nil
        let editingDisabled = model.power == .battery && !separateBattery
        PageCard(title: String(localized: "Fan curve"), symbol: "chart.xyaxis.line") {
            if fans.mode != .curve {
                Text("Used in Curve mode").font(ThermikFont.caption).foregroundStyle(.tertiary)
            }
        } content: {
            HStack(spacing: 12) {
                Picker(selection: $model.power) {
                    Text("Power adapter").tag(PowerSourceKind.ac)
                    Text("Battery").tag(PowerSourceKind.battery)
                } label: { Text("Curve for") }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer(minLength: 8)
                presetMenu(curve)
            }
            if model.power == .battery {
                Toggle(isOn: Binding(get: { separateBattery }, set: { setSeparateBattery($0) })) {
                    Text("Use a separate curve on battery")
                }
            }
            controls(curve)
                .disabled(editingDisabled)
            FanCurveEditor(points: pointsBinding,
                           fans: fans.fans.map(\.descriptor),
                           liveCelsius: fans.curveInputC ?? sensors.value(curve.input),
                           livePercent: livePercent,
                           below: effectiveBelow(curve),
                           unit: settings.effectiveUnit)
                .id(model.power)                 // a new editor (and a fresh undo stack) per power source
                .frame(height: 300)
                .disabled(editingDisabled)
                .opacity(editingDisabled ? 0.5 : 1)
            Text("Drag a point to change it, double-click to add one, press Delete to remove the selected point. Arrow keys nudge it (⌥ for bigger steps).")
                .font(ThermikFont.caption).foregroundStyle(.tertiary)
        }
        .confirmationDialog(Text("Replace your unsaved changes?"),
                            isPresented: Binding(get: { model.pendingPreset != nil }, set: { if !$0 { model.pendingPreset = nil } }),
                            presenting: model.pendingPreset) { id in
            Button(role: .destructive) { loadPreset(id) } label: { Text("Load Preset") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: { id in
            let name = id.title
            Text(verbatim: String(localized: "The \(name) preset replaces the curve you are editing."))
        }
        .sheet(isPresented: $model.choosingSensor) {
            SensorChooserSheet(title: String(localized: "Driving sensor"), current: { if case .sensor(let id) = curve.input { return id }; return nil }()) { id in
                edit { $0.input = .sensor(id) }
            }
        }
    }

    /// Reads the CURRENT draft (not a snapshot of this body pass): the editor's undo / redo closures keep this binding
    /// and must see the value at the time they run.
    private var pointsBinding: Binding<[CurvePoint]> {
        let model = self.model, fans = self.fans
        // The editor works on points sorted by °C (stored curves are normalized on Apply, but stay defensive).
        return Binding(get: { (model.drafts[model.power] ?? Self.stored(fans.config, model.power)).points.sorted { $0.celsius < $1.celsius } },
                       set: { p in Self.edit(model, fans) { $0.points = p } })
    }

    /// Live operating point of fan 0 (nil while it is stopped by macOS).
    private var livePercent: Double? {
        guard let f = fans.fans.first, !f.isOff else { return nil }
        return f.descriptor.percent(forRPM: f.actualRPM)
    }

    private func presetMenu(_ curve: FanCurve) -> some View {
        Menu {
            ForEach(FanPresetID.allCases) { id in
                Button { choosePreset(id) } label: { Text(verbatim: id.title) }
            }
        } label: {
            Text(verbatim: String(localized: "Preset: \(curve.presetID?.title ?? String(localized: "Custom"))"))
        }
        .fixedSize()
    }

    @ViewBuilder private func controls(_ curve: FanCurve) -> some View {
        let unit = settings.effectiveUnit
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Driving sensor").foregroundStyle(.secondary)
                drivingPicker(curve).frame(maxWidth: 320)
            }
            GridRow {
                Text("Hysteresis").foregroundStyle(.secondary)
                Stepper(value: Binding(get: { curve.hysteresisC }, set: { v in edit { $0.hysteresisC = v } }), in: 1...10, step: 1) {
                    Text(verbatim: WindowFormat.tempDelta(curve.hysteresisC, unit))
                        .font(ThermikFont.valueSmall)
                }
                .help(Text("How far the temperature must fall before the fans slow down again."))
            }
            GridRow {
                Text("Ramp-up time").foregroundStyle(.secondary)
                Stepper(value: Binding(get: { Self.rampSeconds(curve.slew.upPercentPerSecond) },
                                       set: { s in edit { $0.slew.upPercentPerSecond = 100 / s } }), in: 1...120, step: 1) {
                    Text("\(Int(Self.rampSeconds(curve.slew.upPercentPerSecond))) s").font(ThermikFont.valueSmall)
                }
                .help(Text("Time to go from minimum to maximum speed."))
            }
            GridRow {
                Text("Ramp-down time").foregroundStyle(.secondary)
                Stepper(value: Binding(get: { Self.rampSeconds(curve.slew.downPercentPerSecond) },
                                       set: { s in edit { $0.slew.downPercentPerSecond = 100 / s } }), in: 1...120, step: 1) {
                    Text("\(Int(Self.rampSeconds(curve.slew.downPercentPerSecond))) s").font(ThermikFont.valueSmall)
                }
                .help(Text("Time to go from maximum to minimum speed."))
            }
            GridRow {
                Text("Below the first point").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: Binding(get: { curve.below }, set: { v in edit { $0.below = v } })) {
                        Text("Minimum").tag(BelowFirstPoint.minimum)
                        Text(verbatim: "macOS").tag(BelowFirstPoint.system)
                        if fans.profile.scheme.allowsFanStop || curve.below == .stop {
                            Text("Stop").tag(BelowFirstPoint.stop)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text(stopUnsupported(curve) ? "This Mac cannot stop its fans: below the first point they run at the minimum."
                                                : Self.belowExplanation(curve.below))
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if stopHeld(curve) {
                        Label { Text("The chip is hot, so the fans keep their minimum; they stop once it cools below 85 °C.") }
                            icon: { Image(systemName: "thermometer.high") }
                            .font(ThermikFont.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.system(size: 12))
    }

    private func stopUnsupported(_ c: FanCurve) -> Bool { c.below == .stop && !fans.profile.scheme.allowsFanStop }
    /// What the chart draws: a stop this Mac cannot do behaves as the minimum.
    private func effectiveBelow(_ c: FanCurve) -> BelowFirstPoint { stopUnsupported(c) ? .minimum : c.below }
    /// Thermik asks for a stop but the helper holds the fans at their minimum (hot die).
    private func stopHeld(_ c: FanCurve) -> Bool {
        guard c.below == .stop, !stopUnsupported(c), fans.isOverriding, !fans.lastCommands.isEmpty,
              fans.lastCommands.values.allSatisfy({ $0 == .rpm(0) }) else { return false }
        return fans.fans.contains { !$0.isOff }
    }

    private static func belowExplanation(_ b: BelowFirstPoint) -> LocalizedStringKey {
        switch b {
        case .minimum: "The fans keep their slowest speed (0 % on the chart) below the first point."
        case .system: "Below the first point macOS controls the fans again; on many Macs it keeps them at the minimum."
        case .stop: "The fans stop once the temperature is the hysteresis below the first point, and start again at the first point. Thermik's safety and the helper restart them if the chip gets hot."
        }
    }

    private func drivingPicker(_ curve: FanCurve) -> some View {
        Picker(selection: Binding<DrivingChoice>(
            get: { .source(curve.input) },
            set: { choice in
                switch choice {
                case .source(let s): edit { $0.input = s }
                case .chooseSensor: model.choosingSensor = true
                }
            })) {
            ForEach(Self.drivingAggregates, id: \.self) { k in
                Text(verbatim: k.title).tag(DrivingChoice.source(.aggregate(k)))
            }
            if case .sensor(let id) = curve.input {
                Divider()
                Text(verbatim: sensors.sensor(id)?.displayName ?? id.description).tag(DrivingChoice.source(curve.input))
            }
            Divider()
            Text("Specific sensor…").tag(DrivingChoice.chooseSensor)
        } label: { Text("Driving sensor") }
        .labelsHidden()
    }

    private enum DrivingChoice: Hashable { case source(TemperatureSource), chooseSensor }

    static func rampSeconds(_ percentPerSecond: Double) -> Double {
        guard percentPerSecond > 0 else { return 120 }
        return min(max((100 / percentPerSecond).rounded(), 1), 120)
    }

    /// Mutates the draft for the current power source; any edit makes the curve "Custom".
    private func edit(_ change: (inout FanCurve) -> Void) { Self.edit(model, fans, change) }

    static func edit(_ model: CurveDraftModel, _ fans: FanStore, _ change: (inout FanCurve) -> Void) {
        var c = model.drafts[model.power] ?? stored(fans.config, model.power)
        change(&c)
        c.presetID = nil
        model.drafts[model.power] = c
    }

    private func choosePreset(_ id: FanPresetID) {
        let stored = Self.stored(fans.config, model.power)
        if let d = model.drafts[model.power], d != stored { model.pendingPreset = id } else { loadPreset(id) }
    }

    private func loadPreset(_ id: FanPresetID) {
        if model.power == .ac {
            fans.applyPreset(id)                      // persists the preset as the adapter curve
            model.drafts[.ac] = nil
        } else {
            if fans.config.curveBattery == nil { fans.applyCurve(fans.config.curveAC, for: .battery) }
            model.drafts[.battery] = FanPresets.curve(id)   // battery: load into the draft; Apply saves it
        }
    }

    private func setSeparateBattery(_ on: Bool) {
        if on {
            fans.applyCurve(fans.config.curveAC, for: .battery)
        } else {
            settings.fans.curveBattery = nil
            model.drafts[.battery] = nil
        }
    }
}

// MARK: - Floating Apply / Revert bar (glass, only when dirty)

private struct CurveApplyBar: View {
    var onRevert: () -> Void
    var onApply: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.circle").foregroundStyle(.secondary)
                Text("Unsaved curve changes").font(.system(size: 12, weight: .medium))
                Button(action: onRevert) { Text("Revert").frame(minWidth: 70) }
                Button(action: onApply) { Text("Apply").frame(minWidth: 70) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .thermikGlass(Capsule())
        }
    }
}

// MARK: - Sanitizer (idempotent; runs after FanControlEngine.normalized on Apply)

enum CurveSanitizer {
    /// Sorted by °C, ≥ 1 °C apart, °C within 0…130, percent clamped 0…100 and non-decreasing, at least 2 points.
    static func clean(_ points: [CurvePoint]) -> [CurvePoint] {
        var out: [CurvePoint] = []
        var floor = 0.0
        for p in points.sorted(by: { $0.celsius < $1.celsius }) {
            let c = min(max(p.celsius.rounded(), 0), 130)
            if let last = out.last, c - last.celsius < 1 { continue }
            floor = max(floor, min(max(p.percent.rounded(), 0), 100))
            out.append(CurvePoint(c, floor))
        }
        if out.count < 2, let only = out.first {
            out.append(CurvePoint(min(only.celsius + 10, 130), 100))
        }
        return out
    }
}
