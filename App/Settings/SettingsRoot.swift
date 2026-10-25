// SettingsRoot.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 8 (tabs: §4.6).
import SwiftUI

struct SettingsRoot: View {
    var initialTab: SettingsTab
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        @Bindable var s = settings
        Form {
            Picker("Update interval", selection: $s.updateInterval) {
                ForEach(SettingsStore.updateIntervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
        }
        .padding()
        .frame(width: 640, height: 480)
    }
}
