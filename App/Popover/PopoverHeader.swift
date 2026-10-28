// PopoverHeader.swift — Thermik (MIT). OWNER: Unit 7. Popover header (SPEC §4.5): aurora background, "Hottest · <sensor>"
// caption + pressure chip, hero temperature + level badge (heat glow behind it when ≥ hot), summary line
// (CPU average · GPU average · system power · battery). Decorative budget: the aurora animates (12 fps) only at
// pressure > nominal, the glow (15 fps) only for a hottest value ≥ hot, and never both at once.
import SwiftUI
import ThermikCore

struct PopoverHeader: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(SystemStore.self) private var system
    @Environment(SettingsStore.self) private var settings
    @Environment(PopoverDebugOverrides.self) private var debug: PopoverDebugOverrides?
    @Environment(AppRouter.self) private var router
    @Environment(StatusPanelState.self) private var panel: StatusPanelState?
    @Environment(\.thermikRamp) private var ramp

    // "Paused" needs no timer: SamplingCoordinator's watchdog marks the store stale when ticks stop arriving.
    private var isStale: Bool { sensors.showsStaleReadings || debug?.stale == true }

    @ViewBuilder var body: some View {
        let unit = settings.effectiveUnit
        let hottest = sensors.hottest
        let value = hottest?.value
        let scale = hottest.map { ThermalScale($0.sensor.thermalClass) } ?? .soc
        let t = value.map(scale.normalized) ?? 0
        let level = value.map(scale.level)
        let pressure = debug?.pressure ?? system.pressure
        let stale = isStale
        let auroraAnimates = pressure > .nominal && !stale
        let glowVisible = (level ?? .frost) >= .hot && !stale
        let unavailable = sensorsUnavailable

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    if let hottest {
                        Text("Hottest · \(hottest.displayName)")
                    } else {
                        Text(verbatim: "Thermik")
                    }
                }
                .font(ThermikFont.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if stale {
                    InfoChip { Label("Paused", systemImage: "pause.circle") }
                        .help(Text("No new readings for a while. The values shown are the last ones received."))
                }
                PressureChip(pressure: pressure)
            }

            HStack(alignment: .center, spacing: 10) {
                if let value {
                    TemperatureText(celsius: value, scale: scale, font: ThermikFont.hero, unit: unit, dimmed: stale)
                        .padding(.horizontal, 4)
                        .background {
                            if glowVisible {
                                HeatGlow(intensity: HeatGlow.intensity(forNormalized: t), tint: ramp.vivid(t),
                                         cornerRadius: ThermikMetrics.innerRadius, spread: 18, animated: !auroraAnimates)
                            }
                        }
                    if let level { LevelBadge(level: level) }
                } else {
                    Text(verbatim: "—").font(ThermikFont.hero).foregroundStyle(.tertiary)
                    Group {
                        if unavailable {
                            Button(action: openDiagnostics) {
                                HStack(spacing: 2) {
                                    Text("Sensors unavailable")
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .help(Text("Diagnostics"))
                        } else {
                            Text("Collecting data…")
                        }
                    }
                    .font(ThermikFont.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Hottest"))
            .accessibilityValue(Text(heroSpoken(hottest: hottest, value: value, scale: scale, unit: unit, unavailable: unavailable)))
            .accessibilityActions {
                if unavailable { Button(action: openDiagnostics) { Text("Diagnostics") } }
            }

            PopoverSummaryLine(unit: unit, dimmed: stale)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            AuroraBackground(normalized: t, energy: PressureLevel(pressure).energy, animated: auroraAnimates)
        }
    }

    /// SPEC §4.14 "Sensors unavailable": discovery failed or found nothing (`SensorStore.isUnavailable`; before this
    /// the popover waited on "Collecting data…" forever), or the SMC could not be opened and no die sensor has
    /// reported since the first tick.
    private var sensorsUnavailable: Bool {
        sensors.isUnavailable || (sensors.inventory?.smcAvailable == false && sensors.hottest == nil && sensors.hasReading)
    }

    private func openDiagnostics() { panel.closeThen { router.showMain(.diagnostics) } }

    private func heroSpoken(hottest: LiveSensor?, value: Double?, scale: ThermalScale, unit: UnitTemperature,
                            unavailable: Bool) -> String {
        guard let hottest, let value else {
            return unavailable ? String(localized: "Sensors unavailable") : String(localized: "Collecting data…")
        }
        return hottest.displayName + ", " + TemperatureText.spoken(value, scale: scale, unit: unit)
    }
}

/// "CPU 71° · GPU 66° · 38.2 W · ⚡ Charging" (caption, mono digits).
struct PopoverSummaryLine: View {
    var unit: UnitTemperature
    var dimmed = false
    @Environment(SensorStore.self) private var sensors
    @Environment(SystemStore.self) private var system

    var body: some View {
        let cpu = sensors.aggregates[.cpuAverage]
        let gpu = sensors.aggregates[.gpuAverage]
        let watts = sensors.power.systemTotalW
        let battery = batteryPart
        HStack(spacing: 4) {
            if let cpu { item(Text("CPU"), ThermikFormat.temp(cpu, unit: unit)) }
            if cpu != nil, gpu != nil { separator }
            if let gpu { item(Text("GPU"), ThermikFormat.temp(gpu, unit: unit)) }
            if let watts, watts > 0 {
                if cpu != nil || gpu != nil { separator }
                Text(ThermikFormat.watts(watts)).monospacedDigit()
            }
            if let battery {
                if cpu != nil || gpu != nil || (watts ?? 0) > 0 { separator }
                Label { Text(battery.text) } icon: { Image(systemName: battery.symbol) }
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel(Text(battery.spoken))
            }
        }
        .font(ThermikFont.caption)
        .foregroundStyle(dimmed ? .tertiary : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View { Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true) }

    private func item(_ label: Text, _ value: String) -> some View {
        HStack(spacing: 3) { label; Text(value).monospacedDigit() }
    }

    private var batteryPart: (symbol: String, text: String, spoken: String)? {
        guard let b = system.battery else { return nil }
        let pct = b.chargePercent.map { ThermikFormat.percentValue(Double($0)) }
        if b.isCharging {
            return ("bolt.fill", String(localized: "Charging"), String(localized: "Charging") + (pct.map { ", " + $0 } ?? ""))
        }
        if b.fullyCharged && b.externalConnected {
            return ("battery.100percent.bolt", String(localized: "Charged"), String(localized: "Charged"))
        }
        guard let pct else { return nil }
        if b.externalConnected {
            return ("powerplug.fill", pct, String(localized: "On power adapter, battery \(pct)"))
        }
        let level = b.chargePercent ?? 100
        let symbol = level > 87 ? "battery.100percent" : level > 62 ? "battery.75percent"
            : level > 37 ? "battery.50percent" : level > 12 ? "battery.25percent" : "battery.0percent"
        return (symbol, pct, String(localized: "On battery, \(pct)"))
    }
}

/// Critical banners under the header: safety override and macOS throttling (SPEC §4.14).
struct PopoverBanners: View {
    @Environment(FanStore.self) private var fans
    @Environment(SystemStore.self) private var system
    @Environment(SettingsStore.self) private var settings
    @Environment(PopoverDebugOverrides.self) private var debug: PopoverDebugOverrides?
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        let state = FanPanelState(fans: fans, debug: debug)
        let pressure = debug?.pressure ?? system.pressure
        let critical = ramp.ink(1)
        if state.safetyTemperature != nil || pressure >= .trapping {
            VStack(alignment: .leading, spacing: 4) {
                if let t = state.safetyTemperature {
                    banner(symbol: "exclamationmark.octagon.fill",
                           text: String(localized: "Safety override: fans at maximum (\(ThermikFormat.temp(t, unit: settings.effectiveUnit)))"),
                           tint: critical)
                }
                if pressure >= .trapping {
                    banner(symbol: "thermometer.sun.fill", text: String(localized: "macOS is throttling performance"), tint: critical)
                }
            }
            .padding(.horizontal, ThermikMetrics.gutter)
            .padding(.bottom, 2)
        }
    }

    private func banner(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(ramp.vivid(1).opacity(0.14), in: RoundedRectangle(cornerRadius: ThermikMetrics.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
