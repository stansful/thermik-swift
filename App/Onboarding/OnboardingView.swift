// OnboardingView.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 8 (3 steps, DES §7.10).
import SwiftUI

struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Thermik").font(.largeTitle)
            Button("Done") { settings.onboardingCompleted = true }
        }
        .padding(32)
        .frame(width: 560, height: 460)
    }
}
