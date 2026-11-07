// EnvironmentInjection.swift — Thermik (MIT). Every hosted SwiftUI root calls
// `.thermikEnvironment(env)`; views read stores with `@Environment(SensorStore.self) private var sensors`.
import SwiftUI

extension View {
    @MainActor func thermikEnvironment(_ env: AppEnvironment) -> some View {
        withBaseEnvironment(env).withFeatureEnvironment(env)
    }

    @MainActor private func withBaseEnvironment(_ env: AppEnvironment) -> some View {
        self.environment(env.settings)
            .environment(env.events)
            .environment(env.visibility)
            .environment(env.helper)
            .environment(env.sensors)
            .environment(env.system)
    }

    @MainActor private func withFeatureEnvironment(_ env: AppEnvironment) -> some View {
        self.environment(env.history)
            .environment(env.fans)
            .environment(env.alerts)
            .environment(env.diagnostics)
            .environment(env.router)
            .environment(env.updater)
    }
}
