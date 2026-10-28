// OnboardingView.swift — Thermik (MIT). Unit 0 stub; OWNER: Unit 8. First-run guide (SPEC §4.8, DES §7.10):
// 560 × 460, three steps with Skip on every step, shown until `onboarding.completed`.
//   1. Welcome — icon, promise, three checklist rows (checkmarks draw on with `.drawOn` on macOS 26+).
//   2. Helper — why it exists, [Install Helper…] (HelperManager: admin prompt in legacy mode, Login Items approval with
//      live polling in SMAppService mode) or [Skip — monitor only]; status line; warning when another fan-control
//      helper is installed. Fanless Macs skip this step.
//   3. Menu bar & startup — live style gallery, Launch at login (on by default), "Allow alerts".
// [Done] and [Skip] set `onboarding.completed = true` and close the window (WindowManager passes `onFinish`).
import AppKit
import SwiftUI
import ThermikCore

struct OnboardingView: View {
    var onFinish: () -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(FanStore.self) private var fans
    @Environment(SensorStore.self) private var sensors
    @State private var step: Step = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable { case welcome, helper, menuBar }

    /// Fanless Macs (known once discovery ran) skip the helper step.
    private var steps: [Step] { sensors.isLoaded && !fans.hasFans ? [.welcome, .menuBar] : Step.allCases }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .helper: HelperStep(onSkip: { advance() })
                case .menuBar: MenuBarStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            footer
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { finish() } label: { Text("Skip") }
                .buttonStyle(.borderless)
                .help(Text("Close the guide; you can open it again from Settings › General."))
            Spacer()
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(localized: "Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")))
            Spacer()
            if step != steps.first {
                Button { back() } label: { Text("Back") }
            }
            if step == steps.last {
                PrimaryButton(title: String(localized: "Done")) { finish() }
            } else {
                PrimaryButton(title: String(localized: "Continue")) { advance() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.bar)
    }

    private func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { finish(); return }
        withAnimation(.snappy(duration: 0.3)) { step = steps[i + 1] }
    }

    private func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        withAnimation(.snappy(duration: 0.3)) { step = steps[i - 1] }
    }

    private func finish() {
        settings.onboardingCompleted = true
        onFinish()
    }
}

/// Liquid Glass prominent button on macOS 26+, bordered prominent before (§4.3).
private struct PrimaryButton: View {
    var title: String
    var action: () -> Void
    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) { Text(verbatim: title).frame(minWidth: 90) }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button(action: action) { Text(verbatim: title).frame(minWidth: 90) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    @State private var revealed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rows: [(symbol: String, text: String)] = [
        ("thermometer.medium", String(localized: "Monitoring works right away — no permissions needed.")),
        ("lock.shield", String(localized: "Fan control needs a small privileged helper.")),
        ("menubar.rectangle", String(localized: "Choose how Thermik appears in the menu bar.")),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: ThermikPalette.brandEmber.opacity(0.35), radius: 18, y: 6)
                .accessibilityHidden(true)
            Text("Welcome to Thermik").font(.system(size: 26, weight: .semibold, design: .rounded))
            Text("See your Mac's heat. Control its fans. Free and open source.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                        ChecklistMark(shown: i < revealed)
                        Image(systemName: row.symbol).foregroundStyle(.secondary).frame(width: 20)
                        Text(verbatim: row.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: 420, alignment: .leading)
        }
        .task {
            if reduceMotion { revealed = rows.count; return }
            for i in 1...rows.count {
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.snappy(duration: 0.35)) { revealed = i }
            }
        }
    }
}

/// Check mark that draws on (macOS 26+ `.drawOn` transition; a fade before).
private struct ChecklistMark: View {
    var shown: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1).frame(width: 20, height: 20)
            if shown {
                if #available(macOS 26.0, *) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .transition(.symbolEffect(.drawOn))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - 2. Helper

private struct HelperStep: View {
    var onSkip: () -> Void
    @Environment(HelperManager.self) private var helper
    @Environment(SettingsStore.self) private var settings
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [ThermikPalette.brandSky, ThermikPalette.brandEmber], startPoint: .top, endPoint: .bottom))
                .accessibilityHidden(true)
            Text("Why a helper?").font(.system(size: 22, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 8) {
                bullet("cpu", String(localized: "Changing fan speeds means writing to the SMC, which macOS allows only as root."))
                bullet("checkmark.seal", String(localized: "The helper is signed, open source and can be removed at any time."))
                bullet("arrow.uturn.backward", String(localized: "Quitting Thermik — or a crash — always returns the fans to Auto."))
            }
            .frame(maxWidth: 440, alignment: .leading)
            HStack(spacing: 8) {
                StatusDot(color: HelperStatusColor.color(helper.state), size: 9)
                Text(verbatim: helper.state.statusLine).font(.system(size: 12, weight: .medium))
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 4)
            if case .requiresApproval = helper.state {
                Text("Approve Thermik in System Settings › General › Login Items & Extensions. This page updates by itself.")
                    .font(ThermikFont.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if !helper.conflictingHelpers.isEmpty {
                let names = helper.conflictingHelpers.joined(separator: ", ")
                StatusBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                             text: String(localized: "Another fan-control helper is installed (\(names)). Quit that app before letting Thermik control the fans."))
                    .frame(maxWidth: 460)
            }
            if let errorText {
                Text(verbatim: errorText).font(ThermikFont.caption).foregroundStyle(Color(nsColor: .systemRed))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                switch helper.state {
                case .ready:
                    Label { Text("Fan control is ready") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen)) }
                case .requiresApproval:
                    Button { helper.openLoginItems() } label: { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                    Button { onSkip() } label: { Text("Skip — monitor only") }
                default:
                    installButton
                    Button { onSkip() } label: { Text("Skip — monitor only") }
                        .disabled(busy)
                }
            }
        }
    }

    @ViewBuilder private var installButton: some View {
        let title = String(localized: "Install Helper…")
        if #available(macOS 26.0, *) {
            Button { install() } label: { Text(verbatim: title).frame(minWidth: 130) }
                .buttonStyle(.glassProminent).disabled(busy)
        } else {
            Button { install() } label: { Text(verbatim: title).frame(minWidth: 130) }
                .buttonStyle(.borderedProminent).disabled(busy)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(verbatim: text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func install() {
        busy = true
        errorText = nil
        Task { @MainActor in
            do {
                try await helper.install()
                settings.helperWanted = true
                if case .requiresApproval = helper.state { _ = await helper.awaitApproval() }
                await helper.refresh()
            } catch {
                errorText = (error as NSError).localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - 3. Menu bar & startup

private struct MenuBarStep: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AlertStore.self) private var alerts

    var body: some View {
        @Bindable var s = settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Menu bar & startup").font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
            Text("Pick how Thermik looks in the menu bar. You can change it later in Settings.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            LabelStyleGallery()
            Toggle(isOn: $s.launchAtLogin) { Text("Launch at login") }
            HStack {
                Text("Get a notification when your Mac runs hot.").font(.system(size: 12))
                Spacer()
                switch alerts.authorization {
                case .authorized, .provisional:
                    Label { Text("Alerts allowed") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen)) }
                        .font(.system(size: 12))
                case .denied:
                    Button { SystemSettingsLink.open(SystemSettingsLink.notifications) } label: { Text("Open Notification Settings") }
                case .notDetermined, .unknown:
                    Button { Task { await alerts.requestAuthorization() } } label: { Text("Allow Alerts") }
                }
            }
        }
    }
}
