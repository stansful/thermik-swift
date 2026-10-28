// BatteryPage.swift — Thermik (MIT). Unit 8. Battery page (SPEC §4.6 W5, M9; laptops only — the sidebar hides it on
// desktops): health (NominalChargeCapacity / DesignCapacity), macOS "Maximum capacity" + condition (system_profiler),
// cycles vs rated, temperature on the battery scale, charge and charging state, adapter, time to empty / full, live
// battery power chart, voltage / current, cell voltages and the raw figures in a details popover.
// While this page is visible VisibilityTracker.needsBatteryDetail asks the sampler for 1 s battery reads.
import SwiftUI
import ThermikCore

struct BatteryPage: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system

    var body: some View {
        if let b = system.battery {
            BatteryContent(battery: b, model: model)
        } else if system.hasBattery {
            CollectingDataPlaceholder(height: 240)
        } else {
            ContentUnavailableView {
                Label { Text("No battery") } icon: { Image(systemName: "powerplug") }
            } description: {
                Text("This Mac runs on mains power only.")
            }
        }
    }
}

private struct BatteryContent: View {
    var battery: BatterySnapshot
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(SettingsStore.self) private var settings
    @State private var showsRaw = false

    var body: some View {
        let b = battery
        let unit = settings.effectiveUnit
        PageScroll {
            if b.permanentFailureStatus.map({ $0 != 0 }) == true || system.appleBatteryHealth?.condition == .serviceRecommended {
                StatusBanner(kind: .warning, symbol: "exclamationmark.triangle.fill",
                             text: String(localized: "Service recommended: macOS reports that this battery needs service."))
            }
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                MetricTile(title: String(localized: "Battery health"), symbol: "heart") {
                    Text(verbatim: b.healthPercent.map { WindowFormat.percent($0, decimals: 1) } ?? "—").font(ThermikFont.display)
                } footer: {
                    Text("Full-charge capacity ÷ design capacity")
                }
                MetricTile(title: String(localized: "Maximum capacity"), symbol: "battery.100percent") {
                    Text(verbatim: system.appleBatteryHealth?.maximumCapacityPercent.map { WindowFormat.percent(Double($0)) } ?? "—")
                        .font(ThermikFont.display)
                } footer: {
                    Text(verbatim: system.appleBatteryHealth.map { String(localized: "macOS: \($0.condition.title)") } ?? String(localized: "As shown by macOS"))
                }
                MetricTile(title: String(localized: "Cycle count"), symbol: "arrow.triangle.2.circlepath") {
                    Text(verbatim: b.cycleCount.map { "\($0)" } ?? "—").font(ThermikFont.display)
                } footer: {
                    Text(verbatim: String(localized: "of \(b.designCycleCount ?? 1000) rated"))
                }
                MetricTile(title: String(localized: "Temperature"), symbol: "thermometer.medium") {
                    if let t = b.temperatureC {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TemperatureText(celsius: t, scale: .battery, font: ThermikFont.display, unit: unit)
                            LevelBadge(level: ThermalScale.battery.level(t), compact: true)
                        }
                    } else {
                        Text(verbatim: "—").font(ThermikFont.display).foregroundStyle(.tertiary)
                    }
                } footer: {
                    let warm = ThermikFormat.temp(ThermalScale.battery.temps[3], unit: unit)
                    Text(verbatim: String(localized: "Batteries feel warm from \(warm)"))
                }
            }
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                chargeCard(b)
                powerCard(b)
            }
            PageCard(title: String(localized: "Battery power"), symbol: "bolt") {
                Text(verbatim: BatteryText.flow(b)).font(ThermikFont.caption).foregroundStyle(.secondary)
            } content: {
                MetricHistoryChart(id: .power(.battery), window: model.historyWindow, color: Color(nsColor: .systemGreen),
                                   domain: nil, height: 140, label: { WindowFormat.watts($0, decimals: 0) },
                                   accessibilityTitle: String(localized: "Battery power"))
            }
            cellsCard(b)
        }
    }

    private func chargeCard(_ b: BatterySnapshot) -> some View {
        PageCard(title: String(localized: "Charge"), symbol: "battery.75percent") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: b.chargePercent.map { WindowFormat.percent(Double($0)) } ?? "—").font(ThermikFont.value)
                    Text(verbatim: BatteryText.state(b)).font(ThermikFont.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(b.chargePercent ?? 0), total: 100)
                    .tint(b.isCharging ? Color(nsColor: .systemGreen) : .accentColor)
                if let remaining = BatteryText.remaining(b, system.powerSource) {
                    DetailRow(label: remaining.label, value: remaining.value)
                }
                if let a = b.adapter {
                    DetailRow(label: String(localized: "Power adapter"),
                              value: [a.name, a.watts.map { WindowFormat.watts(Double($0), decimals: 0) }].compactMap { $0 }.joined(separator: " · "))
                    if let v = a.voltage_mV, let c = a.current_mA {
                        DetailRow(label: String(localized: "Adapter output"), value: "\(WindowFormat.volts(millivolts: v, decimals: 1)) · \(WindowFormat.amps(milliamps: c))")
                    }
                }
                if let low = system.powerSource?.lowPowerMode, low {
                    Label { Text("Low Power Mode is on") } icon: { Image(systemName: "leaf") }
                        .font(ThermikFont.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func powerCard(_ b: BatterySnapshot) -> some View {
        PageCard(title: String(localized: "Electrical"), symbol: "waveform.path.ecg") {
            Button { showsRaw.toggle() } label: { Text("Raw values") }
                .buttonStyle(.link).font(.system(size: 11))
                .popover(isPresented: $showsRaw, arrowEdge: .bottom) { rawDetails(b) }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                if let v = b.voltage_mV { DetailRow(label: String(localized: "Voltage"), value: WindowFormat.volts(millivolts: v)) }
                if let a = b.amperage_mA { DetailRow(label: String(localized: "Current"), value: WindowFormat.amps(milliamps: a)) }
                if let w = b.batteryPowerW { DetailRow(label: String(localized: "Battery power"), value: WindowFormat.watts(w)) }
                if let mW = b.systemLoad_mW { DetailRow(label: String(localized: "Whole Mac"), value: WindowFormat.watts(Double(mW) / 1000)) }
                if let mW = b.systemPowerIn_mW { DetailRow(label: String(localized: "Power input"), value: WindowFormat.watts(Double(mW) / 1000)) }
            }
        }
    }

    @ViewBuilder private func cellsCard(_ b: BatterySnapshot) -> some View {
        if !b.cellVoltages_mV.isEmpty {
            PageCard(title: String(localized: "Cells"), symbol: "minus.plus.batteryblock") {
                let lo = b.cellVoltages_mV.min() ?? 0, hi = b.cellVoltages_mV.max() ?? 0
                HStack(spacing: 16) {
                    ForEach(Array(b.cellVoltages_mV.enumerated()), id: \.offset) { i, mV in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: String(localized: "Cell \(i + 1)")).font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(verbatim: WindowFormat.volts(millivolts: mV, decimals: 3)).font(ThermikFont.valueSmall)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Imbalance").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(verbatim: String(localized: "\(hi - lo) mV")).font(ThermikFont.valueSmall)
                    }
                }
            }
        }
    }

    private func rawDetails(_ b: BatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Raw battery values").font(.headline)
            DetailRow(label: String(localized: "Raw health (AppleRawMaxCapacity)"), value: b.rawHealthPercent.map { WindowFormat.percent($0, decimals: 1) } ?? "—")
            DetailRow(label: String(localized: "Design capacity"), value: b.designCapacity_mAh.map(WindowFormat.milliampHours) ?? "—")
            DetailRow(label: String(localized: "Full-charge capacity"), value: b.nominalChargeCapacity_mAh.map(WindowFormat.milliampHours) ?? "—")
            DetailRow(label: String(localized: "Raw maximum capacity"), value: b.rawMaxCapacity_mAh.map(WindowFormat.milliampHours) ?? "—")
            DetailRow(label: String(localized: "Current capacity"), value: b.rawCurrentCapacity_mAh.map(WindowFormat.milliampHours) ?? "—")
            DetailRow(label: "PermanentFailureStatus", value: b.permanentFailureStatus.map { "\($0)" } ?? "—", monospaced: true)
            DetailRow(label: "NotChargingReason", value: b.notChargingReason.map { String(format: "0x%X", $0) } ?? "—", monospaced: true)
            if let raw = system.appleBatteryHealth?.conditionRaw {
                DetailRow(label: String(localized: "macOS condition"), value: raw, monospaced: true)
            }
            Text("The raw figure fluctuates by a few percent; Thermik's health value uses the full-charge capacity, which tracks macOS's Maximum capacity.")
                .font(ThermikFont.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// Localized battery phrases (shared with the Overview battery card).
enum BatteryText {
    static func state(_ b: BatterySnapshot) -> String {
        if b.fullyCharged { return String(localized: "Charged") }
        if b.isCharging { return String(localized: "Charging") }
        if b.externalConnected { return String(localized: "On power adapter, not charging") }
        return String(localized: "On battery")
    }

    static func flow(_ b: BatterySnapshot) -> String {
        guard let w = b.batteryPowerW, abs(w) >= 0.05 else { return String(localized: "No battery current") }
        return w > 0 ? String(localized: "Charging at \(WindowFormat.watts(w))") : String(localized: "Discharging at \(WindowFormat.watts(-w))")
    }

    static func remaining(_ b: BatterySnapshot, _ source: PowerSourceSummary?) -> (label: String, value: String)? {
        if b.isCharging, let m = b.minutesToFull, m > 0 {
            return (String(localized: "Time to full"), WindowFormat.duration(Double(m) * 60))
        }
        if !b.externalConnected {
            if let m = b.minutesToEmpty, m > 0 { return (String(localized: "Time remaining"), WindowFormat.duration(Double(m) * 60)) }
            if let t = source?.timeRemaining, t.isFinite, t > 0 { return (String(localized: "Time remaining"), WindowFormat.duration(t)) }
            return (String(localized: "Time remaining"), String(localized: "Calculating…"))
        }
        return nil
    }
}
