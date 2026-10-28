// SystemPage.swift — Thermik (MIT). Unit 8. System page (SPEC §4.6 W6): machine identity, cores, memory, macOS build,
// uptime; per-core CPU usage bars (efficiency then performance clusters), GPU usage, memory used / pressure / swap,
// requested cluster frequencies ("≈ MHz", IOReport), power, and the thermal-pressure history as a step chart.
// While this page (or Overview) is visible VisibilityTracker.needsSoCMetrics turns IOReport sampling on.
import SwiftUI
import ThermikCore

struct SystemPage: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system

    var body: some View {
        PageScroll {
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                MachineCard()
                MemoryCard()
            }
            CPUCard(model: model)
            HStack(alignment: .top, spacing: ThermikMetrics.gutter) {
                FrequencyCard()
                PowerCard()
            }
            PressureCard(model: model)
        }
    }
}

// MARK: - Machine

private struct MachineCard: View {
    @Environment(SystemStore.self) private var system
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        PageCard(title: String(localized: "This Mac"), symbol: "macbook") {
            if let m = system.machine {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: m.marketingName ?? m.modelIdentifier).font(.system(size: 14, weight: .semibold))
                    DetailRow(label: String(localized: "Model identifier"), value: m.modelIdentifier, monospaced: true)
                    DetailRow(label: String(localized: "Chip"), value: m.chip)
                    DetailRow(label: String(localized: "CPU cores"), value: coreSummary(m))
                    if let g = m.gpuCores { DetailRow(label: String(localized: "GPU cores"), value: "\(g)") }
                    DetailRow(label: String(localized: "Memory"), value: WindowFormat.bytes(m.memoryBytes))
                    DetailRow(label: String(localized: "macOS"), value: m.osVersion)
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        DetailRow(label: String(localized: "Uptime"), value: WindowFormat.duration(uptime(at: ctx.date)))
                    }
                    if m.isTranslated {
                        Label { Text("Running under Rosetta: some sensors may be missing.") } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(ThermikFont.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                CollectingDataPlaceholder(height: 140)
            }
        }
    }

    private func coreSummary(_ m: MachineInfo) -> String {
        guard m.perfLevels.count >= 2 else { return "\(m.logicalCPUs)" }
        let p = m.perfLevels[0].physicalCPUs, e = m.perfLevels[1].physicalCPUs
        return String(localized: "\(p) performance + \(e) efficiency")
    }

    private func uptime(at date: Date) -> TimeInterval {
        if let boot = system.boot?.bootTime { return date.timeIntervalSince(boot) }
        return ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Memory + GPU

private struct MemoryCard: View {
    @Environment(SystemStore.self) private var system

    var body: some View {
        PageCard(title: String(localized: "Memory and GPU"), symbol: "memorychip") {
            VStack(alignment: .leading, spacing: 6) {
                if let mem = system.memory {
                    let used = Double(mem.used) / Double(max(mem.total, 1))
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: WindowFormat.bytes(mem.used)).font(ThermikFont.value)
                        Text(verbatim: String(localized: "of \(WindowFormat.bytes(mem.total))")).font(ThermikFont.caption).foregroundStyle(.secondary)
                    }
                    ProgressView(value: used).tint(pressureColor(mem.pressure))
                    DetailRow(label: String(localized: "Memory pressure"), value: mem.pressure.title)
                    DetailRow(label: String(localized: "Swap used"), value: WindowFormat.bytes(mem.swapUsed))
                    DetailRow(label: String(localized: "Compressed"), value: WindowFormat.bytes(mem.compressed))
                } else {
                    Text("Memory figures appear after the first update.").font(ThermikFont.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
                if let g = system.gpu, let p = g.devicePercent {
                    DetailRow(label: String(localized: "GPU usage"), value: WindowFormat.percent(Double(p)))
                    ProgressView(value: Double(p), total: 100)
                } else {
                    DetailRow(label: String(localized: "GPU usage"), value: "—")
                }
            }
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal, .unknown: .accentColor
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }
}

// MARK: - CPU

private struct CPUCard: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system

    var body: some View {
        PageCard(title: String(localized: "CPU usage"), symbol: "cpu") {
            if let total = system.cpuTotalPercent {
                Text(verbatim: WindowFormat.percent(total)).font(ThermikFont.valueSmall)
            }
        } content: {
            if system.cpuLoad.isEmpty {
                CollectingDataPlaceholder(height: 80)
            } else {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(clusters, id: \.title) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .bottom, spacing: 3) {
                                ForEach(c.cores, id: \.self) { i in
                                    CoreBar(load: system.cpuLoad.indices.contains(i) ? system.cpuLoad[i].total : 0, isEfficiency: c.efficiency)
                                }
                            }
                            .frame(height: 56)
                            Text(verbatim: c.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("CPU usage per core"))
                .accessibilityValue(Text(verbatim: system.cpuTotalPercent.map { WindowFormat.percent($0) } ?? ""))
                MetricHistoryChart(id: .cpuUsage, window: model.historyWindow, domain: 0...100, height: 90,
                                   label: { WindowFormat.percent($0) }, accessibilityTitle: String(localized: "CPU usage history"))
            }
        }
    }

    private struct Cluster { var title: String; var efficiency: Bool; var cores: [Int] }

    /// Efficiency clusters first, then performance clusters (logical ids from the topology; plain order otherwise).
    private var clusters: [Cluster] {
        let n = system.cpuLoad.count
        guard let topo = system.machine?.cpuTopology, !topo.isEmpty else {
            return [Cluster(title: String(localized: "All cores"), efficiency: false, cores: Array(0..<n))]
        }
        let groups = Dictionary(grouping: topo.filter { $0.id < n }) { "\($0.type)|\($0.cluster)" }
        let sorted = groups.values
            .map { cores in (efficiency: cores[0].type.uppercased().hasPrefix("E"), cores: cores.map(\.id).sorted()) }
            .sorted { a, b in a.efficiency != b.efficiency ? a.efficiency : (a.cores.first ?? 0) < (b.cores.first ?? 0) }
        var eNumber = 0, pNumber = 0
        return sorted.map { c in
            if c.efficiency { eNumber += 1 } else { pNumber += 1 }
            let title = c.efficiency ? String(localized: "Efficiency cluster \(eNumber)") : String(localized: "Performance cluster \(pNumber)")
            return Cluster(title: title, efficiency: c.efficiency, cores: c.cores)
        }
    }
}

/// Moves once per reading, without animation (like RPMBar): the load changes on every tick.
private struct CoreBar: View {
    var load: Double            // 0…1
    var isEfficiency: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isEfficiency ? Color(nsColor: .systemTeal) : Color.accentColor)
                    .frame(height: max(1, g.size.height * min(max(load, 0), 1)))
            }
        }
        .frame(width: 9)
    }
}

// MARK: - Frequencies + power

private struct FrequencyCard: View {
    @Environment(SystemStore.self) private var system

    var body: some View {
        PageCard(title: String(localized: "Frequencies"), symbol: "waveform") {
            if let soc = system.soc, !soc.clusters.isEmpty || soc.gpu != nil {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(soc.clusters, id: \.name) { d in
                        DetailRow(label: d.name, value: "\(WindowFormat.megahertz(d.mhz)) · \(WindowFormat.percent(d.activePercent))")
                    }
                    if let g = soc.gpu {
                        DetailRow(label: String(localized: "GPU"), value: "\(WindowFormat.megahertz(g.mhz)) · \(WindowFormat.percent(g.activePercent))")
                    }
                    Text("Requested frequency and active residency (IOReport), not a measured clock.")
                        .font(ThermikFont.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text("Frequencies appear while this page is open.").font(ThermikFont.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PowerCard: View {
    @Environment(SystemStore.self) private var system
    @Environment(SensorStore.self) private var sensors

    var body: some View {
        let p = sensors.power
        PageCard(title: String(localized: "Power"), symbol: "bolt") {
            VStack(alignment: .leading, spacing: 5) {
                DetailRow(label: String(localized: "Whole Mac"), value: p.systemTotalW.map { WindowFormat.watts($0) } ?? "—")
                if let w = p.socW { DetailRow(label: String(localized: "SoC (estimate)"), value: WindowFormat.watts(w)) }
                if let w = p.dcInW { DetailRow(label: String(localized: "Power input"), value: WindowFormat.watts(w)) }
                if let s = system.soc?.power, s.source != .unavailable {
                    if let w = s.cpuW { DetailRow(label: String(localized: "CPU"), value: WindowFormat.watts(w)) }
                    if let w = s.gpuW { DetailRow(label: String(localized: "GPU"), value: WindowFormat.watts(w)) }
                    if let w = s.aneW { DetailRow(label: String(localized: "Neural Engine"), value: WindowFormat.watts(w)) }
                    if let w = s.dramW { DetailRow(label: String(localized: "Memory"), value: WindowFormat.watts(w)) }
                }
                if let kind = system.powerSource?.kind {
                    DetailRow(label: String(localized: "Power source"), value: kind.title)
                }
            }
        }
    }
}

// MARK: - Thermal pressure

private struct PressureCard: View {
    var model: MainWindowModel
    @Environment(SystemStore.self) private var system
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        PageCard(title: String(localized: "Thermal pressure"), symbol: "gauge.with.dots.needle.50percent") {
            PressureChip(level: PressureLevel(system.pressure))
        } content: {
            MetricHistoryChart(id: .pressure, window: model.historyWindow, color: ramp.ink(0.75), domain: 0...4,
                               stepped: true, height: 110,
                               label: { v in ThermalPressure(rawValue: UInt64(max(0, v.rounded()))).map(\.title) ?? "" },
                               accessibilityTitle: String(localized: "Thermal pressure history"))
            HStack(spacing: 16) {
                DetailRow(label: String(localized: "Now"), value: system.pressure.title)
                DetailRow(label: String(localized: "Events today"), value: "\(system.pressureEventsToday)")
                DetailRow(label: String(localized: "Process thermal state"), value: processStateTitle)
            }
        }
    }

    private var processStateTitle: String {
        switch system.processThermalState {
        case .nominal: String(localized: "Nominal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "thermalPressure.critical", defaultValue: "Critical", comment: "Thermal pressure level")
        }
    }
}
