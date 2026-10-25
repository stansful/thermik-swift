// EnvironmentInjection.swift — Thermik (MIT). FROZEN CONTRACT (Unit 0). Every hosted SwiftUI root calls
// `.thermikEnvironment(env)`; views read stores with `@Environment(SensorStore.self) private var sensors`.
import SwiftUI

extension View {
    @MainActor func thermikEnvironment(_ env: AppEnvironment) -> some View {
        self.environment(env.settings)
            .environment(env.events)
            .environment(env.visibility)
            .environment(env.helper)
            .environment(env.sensors)
            .environment(env.system)
            .environment(env.history)
            .environment(env.fans)
            .environment(env.alerts)
            .environment(env.diagnostics)
            .environment(env.router)
    }
}
