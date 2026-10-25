// MainWindowRoot.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 8 (NavigationSplitView, DES §7.8).
import SwiftUI
import ThermikCore

struct MainWindowRoot: View {
    var initialRoute: Route?
    @Environment(SensorStore.self) private var sensors
    var body: some View {
        NavigationSplitView {
            List { Text("Overview"); Text("Sensors"); Text("Fans") }
        } detail: {
            List(sensors.groups) { g in
                Section(g.group.title) {
                    ForEach(g.sensors) { s in
                        HStack { Text(s.displayName); Spacer(); Text(s.value.map { ThermikFormat.temp($0, decimals: 1) } ?? "—") }
                    }
                }
            }
        }
        .frame(minWidth: 880, minHeight: 560)
    }
}
