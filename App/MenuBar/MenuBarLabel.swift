//  MenuBarLabel.swift — status-item label rendering (MIT).
//  MenuBarExtra's label only honours ONE Text and/or ONE Image (verified on macOS 27: a VStack collapses
//  to its first Text). Multi-line / multi-metric labels are therefore rendered to a template NSImage.
import SwiftUI
import AppKit

// MenuBarStyle lives in App/Shared/SettingsModels.swift (persisted).

struct MenuBarSnapshot: Equatable, Sendable {
    var celsius: Double
    var rpm: Double?
    var normalized: Double          // for colour / gauge fill
    var alert: Bool                 // ≥ critical or user alert fired
}

@MainActor
final class MenuBarLabelRenderer {
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    /// Returns a template image (monochrome, adapts to menu bar appearance) unless `colored`.
    func image(for s: MenuBarSnapshot, style: MenuBarStyle, colored: Bool, scale: CGFloat) -> NSImage {
        let key = "\(style.rawValue)|\(Int(s.celsius.rounded()))|\(Int((s.rpm ?? 0) / 10))|\(colored)|\(s.alert)|\(scale)"
        if let hit = cache[key] { return hit }
        let view = CompactLabel(snapshot: s, style: style, colored: colored)
        let r = ImageRenderer(content: view)
        r.scale = scale
        let img = r.nsImage ?? NSImage()
        img.isTemplate = !colored && !s.alert
        // VoiceOver: "Thermik, 76 degrees" / «Thermik, 76 градусов» (plural key "%lld degrees", unit0.json).
        img.accessibilityDescription = "Thermik, " + String(localized: "\(Int(s.celsius.rounded())) degrees")
        cache[key] = img; order.append(key)
        if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }   // tiny LRU
        return img
    }
}

struct CompactLabel: View {
    var snapshot: MenuBarSnapshot
    var style: MenuBarStyle
    var colored: Bool
    var body: some View {
        let ink: Color = colored || snapshot.alert ? ThermikPalette.vivid(snapshot.normalized) : .black
        Group {
            switch style {
            case .stacked:
                VStack(alignment: .trailing, spacing: -1.5) {
                    Text(ThermikFormat.temp(snapshot.celsius)).font(.system(size: 10, weight: .semibold, design: .rounded))
                    Text(snapshot.rpm.map { ThermikFormat.rpm($0) + "rpm" } ?? "—").font(.system(size: 8.5, weight: .medium, design: .rounded))
                }
                .monospacedDigit()
            case .gauge:
                ZStack {
                    Circle().stroke(ink.opacity(0.3), lineWidth: 2)
                    Circle().trim(from: 0, to: snapshot.normalized).stroke(ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(snapshot.celsius.rounded()))").font(.system(size: 8, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 17, height: 17)
            case .tempFan:
                HStack(spacing: 4) {
                    Text(ThermikFormat.temp(snapshot.celsius))
                    if let rpm = snapshot.rpm { Image(systemName: "fan.fill").font(.system(size: 10)); Text(ThermikFormat.rpm(rpm)) }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
            case .iconTemp:
                HStack(spacing: 3) {
                    Image(systemName: "thermometer.medium").font(.system(size: 12, weight: .medium))
                    Text(ThermikFormat.temp(snapshot.celsius)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                }
            case .temp:
                Text(ThermikFormat.temp(snapshot.celsius)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
            case .iconOnly:
                Image(systemName: snapshot.alert ? "thermometer.high" : "thermometer.medium").font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(ink)
        .frame(height: 22)
        .fixedSize()
        .padding(.horizontal, 1)
    }
}
