// PopoverFansSection.swift — Thermik (MIT). OWNER: Unit 7. Fans card of the popover (SPEC §4.5 / §4.14): one live row
// per fan (Core Animation spin, rpm bar with min tick and target dot), ONE mode switcher for all fans, preset menu
// (Curve), inline slider (Fixed), auto-revert countdown (Max), and the state lines: fans stopped by macOS, foreign
// controller, helper missing / approval / upgrade / unreachable, engaging, error. Fanless Macs get one line instead.
import SwiftUI
import ThermikCore
import os

private let log = Logger(subsystem: "app.thermik.Thermik", category: "popover")

struct PopoverFansSection: View {
    @Environment(FanStore.self) private var fans
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?
    @Environment(PopoverDebugOverrides.self) private var debug: PopoverDebugOverrides?

    var body: some View {
        let state = FanPanelState(fans: fans, debug: debug)
        if !state.hasFans {
            if fans.profile.fans.isEmpty && !(debug?.fanless ?? false) && fans.status != .fanless {
                // Fans not discovered yet (launch): nothing to show until FanStore.load.
                EmptyView()
            } else {
                StatusLine(symbol: "wind", text: String(localized: "Passively cooled — no fans"))
                    .padding(.vertical, 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Fans", systemImage: "fan").font(.system(size: 12, weight: .semibold)).labelStyle(.titleAndIcon)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if state.mode == .curve && state.canControl {
                        Button {
                            panel.closeThen { router.showMain(.fans) }
                        } label: {
                            HStack(spacing: 2) { Text("Edit curve…"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 11))
                    }
                }
                ForEach(fans.fans) { PopoverFanRow(fan: $0) }
                ModeSwitcher(mode: modeBinding(state), compact: true, busy: state.isEngaging ? fans.mode : nil)
                    .disabled(!state.canControl)
                    .padding(.top, 2)
                // Own row: beside a preset name («Сбалансированный» ≈ 117 pt) the switcher has room only for symbols.
                if state.mode == .curve && state.canControl { PresetMenu() }
                if state.canControl && state.mode == .fixed { FixedSpeedControl() }
                if state.canControl && state.mode == .max, let deadline = state.maxDeadline { MaxCountdownChip(deadline: deadline) }
                PopoverFanStateLines(state: state)
            }
            .thermikCard(padding: 10)
        }
    }

    private func modeBinding(_ state: FanPanelState) -> Binding<FanMode> {
        Binding(get: { state.mode }, set: { new in
            guard state.canControl, new != fans.mode else { return }
            fans.setMode(new, reason: .user)
            router.requestTick()                   // apply now instead of on the next 1–2 s tick
        })
    }
}

/// One fan row observing its LiveFan (only this row re-renders on rpm changes).
struct PopoverFanRow: View {
    let fan: LiveFan
    @Environment(FanStore.self) private var fans
    var body: some View {
        FanRow(fan: FanRowItem(id: fan.id, name: popoverFanShortName(fan), rpm: fan.isOff ? 0 : fan.actualRPM,
                               minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                               targetRPM: fans.isOverriding ? fan.targetRPM : nil, mode: fans.mode))
    }
}

/// Curve preset menu ("Balanced ▾").
struct PresetMenu: View {
    @Environment(FanStore.self) private var fans
    @Environment(SystemStore.self) private var system
    @Environment(AppRouter.self) private var router

    var body: some View {
        let onBattery = system.powerSourceKind == .battery
        let usesBatteryCurve = onBattery && fans.config.curveBattery != nil
        let curve = (usesBatteryCurve ? fans.config.curveBattery : nil) ?? fans.config.curveAC
        Menu {
            ForEach(FanPresetID.allCases) { id in
                Button {
                    // The preset replaces the curve in use: the battery curve when one is set and the Mac is on battery
                    // (applyPreset only ever writes the adapter curve).
                    if usesBatteryCurve { fans.applyCurve(FanPresets.curve(id), for: .battery) } else { fans.applyPreset(id) }
                    router.requestTick()
                } label: {
                    if curve.presetID == id { Label(id.title, systemImage: "checkmark") } else { Text(id.title) }
                }
            }
        } label: {
            Text(curve.presetID?.title ?? String(localized: "Custom"))
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(Text("Curve preset"))
    }
}

/// Inline Fixed-speed slider (0 % = minimum spinning speed, 100 % = maximum, per fan's own range). A drag applies
/// once, on release (each apply writes settings, runs a tick and commands the fans); keyboard and VoiceOver steps,
/// which have no editing session, apply after a short pause. With "Same speed for all fans" off (Fans page)
/// one slider can neither show nor set the per-fan speeds: the card lists them and links to the Fans page.
struct FixedSpeedControl: View {
    @Environment(FanStore.self) private var fans
    @Environment(AppRouter.self) private var router
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?
    @State private var value: Double = -1
    @State private var dragging = false
    @State private var commit: Task<Void, Never>?

    var body: some View {
        if fans.config.linked { slider } else { perFan }
    }

    private var perFan: some View {
        let config = fans.config
        let speeds = fans.fans.map { f in
            popoverFanName(f) + "\u{00A0}" + ThermikFormat.percentValue(config.fixedPercentPerFan[f.id] ?? config.fixedPercent)
        }.joined(separator: " · ")
        return StatusLine(symbol: "dial.medium", text: String(localized: "Each fan has its own speed: \(speeds)")) {
            Button("Edit…") { panel.closeThen { router.showMain(.fans) } }.statusLineButton()
        }
    }

    @ViewBuilder private var slider: some View {
        let stored = fans.config.fixedPercent
        let shown = value < 0 ? stored : value
        HStack(spacing: 8) {
            ThermikSlider(value: Binding(get: { shown }, set: { v in
                value = v
                if !dragging { scheduleCommit(delay: .milliseconds(400)) }
            }), in: 0...100, step: 5) { editing in
                dragging = editing
                if editing { commit?.cancel(); commit = nil } else { scheduleCommit(delay: .zero) }
            }
            .controlSize(.small)
            .accessibilityLabel(Text("Fixed speed"))
            VStack(alignment: .trailing, spacing: 0) {
                Text(ThermikFormat.percentValue(shown)).font(ThermikFont.valueSmall)
                if let f = fans.fans.first {
                    Text(verbatim: "≈ " + ThermikFormat.rpmWithUnit(f.minRPM + (f.maxRPM - f.minRPM) * shown / 100))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Fixed speed"))
        .onChange(of: stored) { _, _ in if commit == nil && !dragging { value = -1 } }
    }

    /// Applies the slider's current value (read when the commit runs, not when it was scheduled).
    private func scheduleCommit(delay: Duration) {
        commit?.cancel()
        commit = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            if value >= 0, fans.config.linked { fans.setFixedPercent(value, fan: nil) }   // may run after the panel closed
            commit = nil
        }
    }
}

/// "Returns to Auto in 28:41" — `Text(timerInterval:)` is updated by SwiftUI itself (no timer of ours).
struct MaxCountdownChip: View {
    var deadline: Date
    @Environment(\.thermikRamp) private var ramp
    var body: some View {
        let now = Date()
        let timer = Text(timerInterval: now...max(deadline, now), countsDown: true)
        InfoChip(tint: ramp.ink(0.75)) {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text("Returns to Auto in \(timer)").monospacedDigit()
            }
        }
    }
}

/// State lines under the switcher.
struct PopoverFanStateLines: View {
    var state: FanPanelState
    @Environment(FanStore.self) private var fans
    @Environment(HelperManager.self) private var helper
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.isEngaging {
                StatusLine(symbol: "hourglass", text: String(localized: "Taking control…"))
            }
            if state.mode == .system && !fans.fans.isEmpty && fans.fans.allSatisfy(\.isOff) && !state.isForeign {
                StatusLine(symbol: "info.circle", text: String(localized: "Fans are off — macOS stopped them"))
            }
            if state.isForeign {
                StatusLine(symbol: "exclamationmark.triangle.fill", text: foreignText, tint: .orange)
            }
            if let availability = state.helperAvailability {
                StatusLine(symbol: availability == .connecting ? "arrow.triangle.2.circlepath" : "lock.fill",
                           text: availability.title, tint: availability == .connecting ? .secondary : .orange) {
                    helperAction(availability)
                }
            }
            if case .error(let message) = state.status {
                StatusLine(symbol: "exclamationmark.triangle", text: String(localized: "Fan control error: \(message)"), tint: .red)
            }
            // HelperManager keeps the last failure: the panel (and any @State here) is gone by the time an install
            // behind the administrator prompt fails, so the reason is still shown when the popover is reopened.
            if state.helperAvailability != nil, !helper.isBusy, let failure = helper.lastError {
                StatusLine(symbol: "xmark.octagon", text: failure, tint: .red)
            }
        }
    }

    private var foreignText: String {
        let lead = state.foreignName.map { String(localized: "Fan control is in use by \($0)") }
            ?? String(localized: "Another app is controlling the fans")
        return lead + ". " + String(localized: "Quit it to let Thermik control the fans.")
    }

    @ViewBuilder private func helperAction(_ a: HelperAvailability) -> some View {
        switch a {
        case .connecting:
            ProgressView().controlSize(.mini)
        case .notInstalled:
            Button("Install Helper…") { run { try await helper.install() } }.statusLineButton().disabled(busy || helper.isBusy)
        case .requiresApproval:
            Button("Open Login Items…") { helper.openLoginItems() }.statusLineButton()
        case .needsUpgrade:
            Button("Update Helper…") { run { try await helper.upgrade() } }.statusLineButton().disabled(busy || helper.isBusy)
        case .unreachable:
            Button("Retry") { run { await helper.refresh() } }.statusLineButton().disabled(busy || helper.isBusy)
        }
    }

    /// Helper operations may show the admin prompt; the popover closes when it loses key, the task keeps running.
    /// A failure lands in `helper.lastError` (shown above, also after the popover is reopened).
    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        busy = true
        let helper = self.helper
        Task { @MainActor in
            do {
                try await op()
                await helper.refresh()
            } catch {
                log.error("helper action failed: \(error.localizedDescription)")
            }
            busy = false
        }
    }
}

private extension View {
    /// Mini bordered buttons inside status lines.
    func statusLineButton() -> some View { buttonStyle(.bordered).controlSize(.mini) }
}
