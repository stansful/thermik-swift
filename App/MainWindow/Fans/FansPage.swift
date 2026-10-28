// FansPage.swift — Thermik (MIT). Unit 8. Fans page (SPEC §4.6 W4, §2.9.4 UI contract): per-fan cards, the shared
// mode switcher (disabled with Auto shown as current while Thermik cannot control the fans, §4.14), Fixed and Max
// controls, the curve editor section (FanCurveSection.swift), the helper card and the safety copy.
// Commands go through FanStore only (setMode / setFixedPercent / setLinked / setMaxAutoRevert / applyCurve /
// applyPreset / resetToSystem).
import AppKit
import SwiftUI
import ThermikCore
import ThermikSMC

struct FansPage: View {
    @Environment(FanStore.self) private var fans

    var body: some View {
        if !fans.hasFans {
            ContentUnavailableView {
                Label { Text("Passively cooled — no fans") } icon: { Image(systemName: "wind") }
            } description: {
                Text("This Mac has no fans. Thermik keeps monitoring its temperatures.")
            }
        } else {
            FanCurveSection.Container {
                FanStatusBanners()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: ThermikMetrics.gutter)], spacing: ThermikMetrics.gutter) {
                    ForEach(fans.fans) { FanDetailCard(fan: $0) }
                }
                FanModeCard()
            }
        }
    }
}

// MARK: - Status banners

private struct FanStatusBanners: View {
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        switch fans.status {
        case .monitoringOnly(let availability):
            StatusBanner(kind: .warning, symbol: "lock.shield", text: availability.title) {
                HelperQuickAction(availability: availability)
            }
        case .foreignController(let name):
            let who = name ?? String(localized: "another app")
            StatusBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                         text: String(localized: "Fan control is in use by \(who). Quit it to let Thermik control the fans."))
        case .safetyOverride(let t):
            let temp = ThermikFormat.temp(t, unit: settings.effectiveUnit)
            StatusBanner(kind: .critical, symbol: "exclamationmark.octagon.fill",
                         text: String(localized: "Safety override: fans at maximum (\(temp))"))
        case .engaging:
            StatusBanner(kind: .info, symbol: "hourglass", text: String(localized: "Taking control…")) {
                ProgressView().controlSize(.small)
            }
        case .error(let message):
            StatusBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                         text: String(localized: "Fan control error: \(message)"))
        case .fanless, .system, .active:
            EmptyView()
        }
    }
}

// MARK: - Per-fan card

/// `fan.gauge.open` filled to `fraction` in 10 % steps, as a plain bitmap tinted with the accent colour. As a SwiftUI
/// variable-value symbol it went through RenderBox's symbol animator on every new reading (the rpm moves on every
/// tick): about 30 % CPU and 260 MB of GPU surfaces while the page was open.
private struct FanGauge: View {
    var fraction: Double
    @Environment(\.displayScale) private var displayScale

    private struct Key: Hashable { var step: Double; var scale: CGFloat }
    @MainActor private static var images: [Key: CGImage] = [:]

    var body: some View {
        let step = (min(max(fraction, 0), 1) * 10).rounded() / 10
        if let image = Self.image(step: step, scale: displayScale) {
            Image(decorative: image, scale: displayScale).renderingMode(.template).foregroundStyle(Color.accentColor)
        }
    }

    /// The symbol at 24 pt, drawn by AppKit (black, layer opacities in the alpha channel).
    private static func image(step: Double, scale: CGFloat) -> CGImage? {
        let key = Key(step: step, scale: scale)
        if let hit = images[key] { return hit }
        guard let symbol = NSImage(systemSymbolName: "fan.gauge.open", variableValue: step, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((symbol.size.width * scale).rounded(.up)),
                                         pixelsHigh: Int((symbol.size.height * scale).rounded(.up)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()
        let image = rep.cgImage
        images[key] = image
        return image
    }
}

private struct FanDetailCard: View {
    var fan: LiveFan
    @Environment(FanStore.self) private var fans

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                FanGlyph(rpm: fan.actualRPM, maxRPM: fan.maxRPM, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: fan.localizedName).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if fan.isOff {
                            Text("Off").font(ThermikFont.display)
                        } else {
                            Text(verbatim: ThermikFormat.rpm(fan.actualRPM)).font(ThermikFont.display)
                                .contentTransition(.numericText(value: fan.actualRPM))
                            Text("rpm").font(ThermikFont.unit).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                FanGauge(fraction: fan.percentOfMax / 100)
                    .help(Text(verbatim: String(localized: "\(WindowFormat.percent(fan.percentOfMax)) of maximum speed")))
                    .accessibilityHidden(true)
            }
            RPMBar(rpm: fan.actualRPM, minRPM: fan.minRPM, maxRPM: fan.maxRPM, target: fan.targetRPM)
                .frame(height: 6)
            HStack(spacing: 14) {
                stat(StatLabel.min, ThermikFormat.rpm(fan.minRPM))
                stat(StatLabel.max, ThermikFormat.rpm(fan.maxRPM))
                stat(String(localized: "Target"), fan.targetRPM.map(ThermikFormat.rpm) ?? "—")
                if let duty = fan.dutyCycle { stat(String(localized: "Duty"), WindowFormat.percent(duty * 100)) }
            }
            if fan.isOff && fans.mode == .system {
                Label { Text("Fans are off — macOS stopped them") } icon: { Image(systemName: "info.circle") }
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
        .thermikCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: fan.localizedName))
        .accessibilityValue(Text(verbatim: fan.isOff ? String(localized: "Off") : WindowFormat.rpm(fan.actualRPM)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(verbatim: value).font(ThermikFont.valueSmall)
        }
    }
}

// MARK: - Mode card (switcher + Fixed / Max options)

private struct FanModeCard: View {
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        PageCard(title: String(localized: "Fan mode"), symbol: "dial.medium") {
            Button { fans.resetToSystem() } label: { Text("Reset to Auto") }
                .controlSize(.small)
                .help(Text("Return every fan to macOS control now"))
        } content: {
            // Without control the switcher is disabled and shows Auto as current (§4.14).
            let shown = fans.canControl ? fans.mode : .system
            ModeSwitcher(mode: Binding(get: { shown }, set: { fans.setMode($0, reason: .user) }))
                .frame(maxWidth: 440)
                .disabled(!fans.canControl)
            Text(verbatim: shown.explanation).font(ThermikFont.caption).foregroundStyle(.secondary)
            if fans.canControl {
                switch fans.mode {
                case .fixed: FixedControls()
                case .max: MaxControls()
                case .system, .curve: EmptyView()
                }
            }
            Text("Thermik never sets fans below their hardware minimum. Quitting Thermik returns fans to Auto.")
                .font(ThermikFont.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct FixedControls: View {
    @Environment(FanStore.self) private var fans

    var body: some View {
        let config = fans.config
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { config.linked }, set: { fans.setLinked($0) })) { Text("Same speed for all fans") }
            if config.linked {
                FixedSpeedRow(title: String(localized: "All fans"), percent: config.fixedPercent,
                              rpmText: fans.fans.map { WindowFormat.rpm($0.descriptor.rpm(forPercent: config.fixedPercent)) }.joined(separator: " · ")) {
                    // A keyboard step applies 0.4 s later: by then "Same speed for all fans" may be off, and a speed
                    // for all fans would turn it back on.
                    if fans.config.linked { fans.setFixedPercent($0, fan: nil) }
                }
            } else {
                ForEach(fans.fans) { f in
                    let p = config.fixedPercentPerFan[f.id] ?? config.fixedPercent
                    FixedSpeedRow(title: f.localizedName, percent: p, rpmText: WindowFormat.rpm(f.descriptor.rpm(forPercent: p))) {
                        fans.setFixedPercent($0, fan: f.id)
                    }
                }
            }
        }
    }
}

/// Slider (snaps 1 %) + numeric field (% of the fan's own range) + the resulting ≈ rpm. A drag applies on release,
/// keyboard and VoiceOver steps after a short pause (they have no editing session).
private struct FixedSpeedRow: View {
    var title: String
    var percent: Double
    var rpmText: String
    var onChange: (Double) -> Void
    @State private var draft: Double?
    @State private var dragging = false
    @State private var commit: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: title).font(.system(size: 12)).frame(width: 120, alignment: .leading).lineLimit(1)
            ThermikSlider(value: Binding(get: { draft ?? percent }, set: { v in
                draft = v.rounded()
                if !dragging { scheduleCommit(delay: .milliseconds(400)) }
            }), in: 0...100) { editing in
                dragging = editing
                if editing { commit?.cancel(); commit = nil } else { scheduleCommit(delay: .zero) }
            }
            .frame(minWidth: 160)
            .accessibilityLabel(Text(verbatim: title))
            TextField(value: Binding(get: { percent.rounded() }, set: { onChange(min(max($0, 0), 100)) }),
                      format: .number.precision(.fractionLength(0))) { Text(verbatim: title) }
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
            Text(verbatim: "%").foregroundStyle(.secondary)
            Text(verbatim: "≈ " + rpmText).font(ThermikFont.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func scheduleCommit(delay: Duration) {
        commit?.cancel()
        commit = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            if let d = draft { onChange(d); draft = nil }
            commit = nil
        }
    }
}

/// Max auto-revert choices (Off is tag 0); a stored value outside the presets stays selectable.
enum FanSettingsOptions {
    static func revertMinutes(including current: Int?) -> [Int] {
        let presets = [15, 30, 60]
        guard let current, current > 0, !presets.contains(current) else { return presets }
        return (presets + [current]).sorted()
    }
}

private struct MaxControls: View {
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Through FanStore: a new value applies to the running Max session (the countdown restarts).
            Picker(selection: Binding(get: { settings.fans.maxAutoRevertMinutes ?? 0 },
                                      set: { fans.setMaxAutoRevert(minutes: $0 == 0 ? nil : $0) })) {
                Text("Never").tag(0)
                ForEach(FanSettingsOptions.revertMinutes(including: settings.fans.maxAutoRevertMinutes), id: \.self) { m in
                    Text("\(m) min").tag(m)
                }
            } label: { Text("Return to Auto after") }
            .frame(maxWidth: 320)
            if let deadline = fans.maxRevertDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = WindowFormat.countdown(deadline.timeIntervalSince(ctx.date))
                    Label { Text("Returns to Auto in \(left)") } icon: { Image(systemName: "timer") }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.fill.tertiary, in: Capsule())
                }
            }
        }
    }
}
