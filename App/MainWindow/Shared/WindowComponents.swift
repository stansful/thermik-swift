// WindowComponents.swift — Thermik (MIT). Unit 8. Small building blocks shared by the main-window pages, Settings
// and onboarding: locale-safe number formatting with localized units, page scaffolding, metric tiles, banners,
// placeholders. Built on the DesignSystem kit (cards, fonts, palette) without changing it.
import AppKit
import SwiftUI
import ThermikCore
import ThermikSMC

// MARK: - Formatting (numbers are always pre-formatted strings, never interpolated into LocalizedStringKey: §4.2.4)

enum WindowFormat {
    static func number(_ v: Double, decimals: Int = 0) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }
    /// "38.2 W" / «38,2 Вт».
    static func watts(_ w: Double, decimals: Int = 1) -> String {
        let n = number(w, decimals: decimals)
        return String(localized: "\(n) W", comment: "Power in watts; %@ is a formatted number")
    }
    /// "2310 rpm" / «2310 об/мин» (never grouped: "2 310" would wrap in Russian).
    static func rpm(_ r: Double) -> String {
        let n = ThermikFormat.rpm(r)
        return String(localized: "\(n) rpm", comment: "Fan speed; %@ is a formatted number")
    }
    /// 0…100 → "45%" / «45 %» (locale-aware).
    static func percent(_ p: Double, decimals: Int = 0) -> String {
        (p / 100).formatted(.percent.precision(.fractionLength(decimals)))
    }
    static func megahertz(_ mhz: Double) -> String {
        let n = number(mhz)
        return String(localized: "≈ \(n) MHz", comment: "Requested CPU/GPU frequency; %@ is a formatted number")
    }
    static func volts(millivolts mV: Int, decimals: Int = 2) -> String {
        let n = number(Double(mV) / 1000, decimals: decimals)
        return String(localized: "\(n) V", comment: "Voltage; %@ is a formatted number")
    }
    static func amps(milliamps mA: Int) -> String {
        let n = number(Double(mA) / 1000, decimals: 2)
        return String(localized: "\(n) A", comment: "Current; %@ is a formatted number")
    }
    static func milliampHours(_ mAh: Int) -> String {
        let n = number(Double(mAh))
        return String(localized: "\(n) mAh", comment: "Battery capacity; %@ is a formatted number")
    }
    static func bytes(_ b: UInt64) -> String { Int64(clamping: b).formatted(.byteCount(style: .memory)) }
    /// "3 d 4 h" / «3 дн. 4 ч» (Foundation-localized units).
    static func duration(_ seconds: TimeInterval, maxUnits: Int = 2) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return Duration.seconds(seconds.rounded()).formatted(
            .units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: maxUnits))
    }
    /// "28:41" countdown.
    static func countdown(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: .minuteSecond))
    }
    static func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .standard) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }

    /// Temperature in the user's unit, "—" for nil.
    static func temp(_ c: Double?, _ unit: UnitTemperature, decimals: Int = 0) -> String {
        c.map { ThermikFormat.temp($0, unit: unit, decimals: decimals) } ?? "—"
    }
    /// A temperature DIFFERENCE (hysteresis) in the user's unit: 3 °C → "3°" or "5°".
    static func tempDelta(_ dc: Double, _ unit: UnitTemperature, decimals: Int = 0) -> String {
        number(unit == .fahrenheit ? dc * 9 / 5 : dc, decimals: decimals) + "°"
    }
    /// Kit charts print plain numbers with "°": convert values before plotting so °F users read °F.
    static func chartValue(_ celsius: Double, _ unit: UnitTemperature) -> Double {
        unit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }
}

/// Short statistic labels with their own keys: "Max" alone is the fan mode «Максимум» (unit0), a column needs «Макс.».
enum StatLabel {
    static var min: String { String(localized: "stat.min", defaultValue: "Min", comment: "Short label: minimum value") }
    static var avg: String { String(localized: "stat.avg", defaultValue: "Avg", comment: "Short label: average value") }
    static var max: String { String(localized: "stat.max", defaultValue: "Max", comment: "Short label: maximum value") }
}

// MARK: - Display helpers

extension LiveSensor {
    /// Per-class colour scale (§4.2.2).
    var colorScale: ThermalScale { ThermalScale(sensor.thermalClass) }
}

extension Sensor {
    var colorScale: ThermalScale { ThermalScale(thermalClass) }
}

extension FanDescriptor {
    /// "Left fan" / «Левый вентилятор» from the DB / SMC names; "Fan 3" otherwise.
    var localizedName: String {
        let n = name.lowercased()
        if n.hasPrefix("left") { return String(localized: "Left fan") }
        if n.hasPrefix("right") { return String(localized: "Right fan") }
        if n.hasPrefix("center") || n.hasPrefix("centre") { return String(localized: "Center fan") }
        return String(localized: "Fan \(index + 1)")
    }
}

extension LiveFan {
    /// Localized name: DB names are English ("Left"); a user-visible custom name is kept as is.
    var localizedName: String {
        let n = displayName.lowercased()
        if n == "left" || n == "left fan" { return String(localized: "Left fan") }
        if n == "right" || n == "right fan" { return String(localized: "Right fan") }
        if n == "center" || n == "center fan" { return String(localized: "Center fan") }
        if n.isEmpty || n.hasPrefix("fan") { return descriptor.localizedName }
        return displayName
    }
}

extension FanMode {
    var explanation: String {
        switch self {
        case .system: String(localized: "macOS controls the fans. They may stop completely when the Mac is cool.")
        case .curve: String(localized: "Fan speed follows the curve below, based on the driving sensor.")
        case .fixed: String(localized: "Fans run at a constant speed you choose.")
        case .max: String(localized: "Fans run at full speed.")
        }
    }
}

// MARK: - Page scaffolding

/// Scrollable page body with the standard gutter. Content is laid out top-down.
struct PageScroll<Content: View>: View {
    var spacing: CGFloat = ThermikMetrics.gutter
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// Card with a small-caps title row and an optional trailing accessory.
struct PageCard<Accessory: View, Content: View>: View {
    var title: String
    var symbol: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(verbatim: title).font(ThermikFont.sectionTitle).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .thermikCard()
    }
}

extension PageCard where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// KPI tile (Overview): title, big value, a footer line.
struct MetricTile<Value: View, Footer: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var value: Value
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(ThermikFont.sectionTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            value
            footer
                .font(ThermikFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .thermikCard()
        .accessibilityElement(children: .combine)
    }
}

/// Key/value row for detail grids (inspector, System, Battery).
struct DetailRow: View {
    var label: String
    var value: String
    var monospaced = false
    var body: some View {
        LabeledContent {
            Text(verbatim: value)
                .font(monospaced ? ThermikFont.mono : .system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Banners & states

enum BannerKind { case info, warning, critical
    /// `ramp`: the active thermal ramp (`\.thermikRamp`), so "critical" follows the colour-blind setting.
    func tint(_ ramp: ThermikRamp) -> Color {
        switch self {
        case .info: .secondary
        case .warning: Color(nsColor: .systemOrange)
        case .critical: ramp.ink(1.0)
        }
    }
}

/// One-line state banner (helper missing, foreign controller, safety override, approximate names, stale data).
struct StatusBanner<Actions: View>: View {
    var kind: BannerKind
    var symbol: String
    var text: String
    @ViewBuilder var actions: Actions
    @Environment(\.thermikRamp) private var ramp

    var body: some View {
        let tint = kind.tint(ramp)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(verbatim: text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tint.opacity(kind == .info ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: ThermikMetrics.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension StatusBanner where Actions == EmptyView {
    init(kind: BannerKind, symbol: String, text: String) {
        self.init(kind: kind, symbol: symbol, text: text, actions: { EmptyView() })
    }
}

/// Chart skeleton while history fills (§4.14 "No history yet").
struct CollectingDataPlaceholder: View {
    var height: CGFloat = 180
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { _ in
                    Divider().opacity(0.5)
                    Spacer(minLength: 0)
                }
            }
            Label { Text("Collecting data…") } icon: { ProgressView().controlSize(.small) }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }
}

/// Placeholder for data that comes from sensor discovery (sensor lists, sensor / fan history): "Collecting data…"
/// while it is pending, "Sensors unavailable" with a link to Diagnostics once it failed (SPEC §4.14). Without the
/// second state the skeleton would wait forever on a Mac where neither the SMC nor HID sensors can be opened.
struct SensorDataPlaceholder: View {
    var height: CGFloat = 180
    @Environment(SensorStore.self) private var sensors
    @Environment(AppRouter.self) private var router

    var body: some View {
        if sensors.isUnavailable {
            VStack(spacing: 6) {
                Label { Text("Sensors unavailable") } icon: { Image(systemName: "exclamationmark.octagon") }
                    .font(.system(size: 12, weight: .medium))
                Button { router.showMain(.diagnostics) } label: { Text("Diagnostics") }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        } else {
            CollectingDataPlaceholder(height: height)
        }
    }
}

extension SensorStore {
    /// No sensor can be read: discovery failed (no SMC and no HID temperature services; SamplingCoordinator retries
    /// after wake) or it found nothing. `loadError` stays set until a later discovery succeeds.
    var isUnavailable: Bool { isLoaded ? sensors.isEmpty : loadError != nil }
}

/// Small coloured status dot (helper footer, rule rows).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// Opens System Settings at a pane (URLs verified on macOS 26/27; plain System Settings as the fallback).
enum SystemSettingsLink {
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    @MainActor static func open(_ string: String) {
        if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
