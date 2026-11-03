// main.swift — Thermik (MIT). AppKit lifecycle: agent app (LSUIElement), SwiftUI hosted in
// AppKit windows/panels. No SwiftUI `App`/`Scene` (status item + custom panel + programmatic windows).
import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
