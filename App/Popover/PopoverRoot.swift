// PopoverRoot.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 7 (DES §7.7 wireframe).
import SwiftUI
import ThermikCore

struct PopoverRoot: View {
    @Environment(SensorStore.self) private var sensors
    @Environment(FanStore.self) private var fans
    @Environment(AppRouter.self) private var router
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermik").font(.headline)
            if let h = sensors.hottest, let v = h.value {
                Text("\(h.displayName): \(ThermikFormat.temp(v))").font(ThermikFont.value)
            } else {
                Text("Collecting data…").foregroundStyle(.secondary)
            }
            ForEach(fans.fans) { f in Text("\(f.displayName) \(ThermikFormat.rpm(f.actualRPM)) rpm").font(ThermikFont.valueSmall) }
            Button("Open Thermik") { router.showMain(nil) }
        }
        .padding(ThermikMetrics.gutter)
        .frame(width: ThermikMetrics.popoverWidth, alignment: .leading)
    }
}
