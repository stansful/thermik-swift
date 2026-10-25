// MenuBarController.swift — Thermik (MIT). Basic version by Unit 0; OWNER: Unit 7 (metrics, colours, ◆ badge,
// hidden/notch detection, first-run hint, context menu with Mode ▸). Surface FROZEN.
import AppKit
import SwiftUI
import ThermikCore

@MainActor final class MenuBarController: TickConsumer {
    private let env: AppEnvironment
    private var status: StatusItemController?
    private var openMainObserver: (any NSObjectProtocol)?

    init(env: AppEnvironment) { self.env = env }

    func install() {
        let env = self.env
        status = StatusItemController(autosaveName: "ThermikStatusItem") {
            PopoverRoot().thermikEnvironment(env)
        }
        env.router.openPopover = { [weak self] in self?.status?.open() }
        env.router.closePopover = { [weak self] in self?.status?.close() }
        // The kit's right-click "Open Thermik" item only posts `.thermikOpenMainWindow`; route it to the main window.
        openMainObserver = NotificationCenter.default.addObserver(forName: .thermikOpenMainWindow, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated { env.router.showMain(nil) }
        }
    }

    var isItemOnScreen: Bool { status?.isOnScreen ?? false }

    func consume(_ tick: Tick) {
        let c = env.sensors.value(.aggregate(.cpuAverage)) ?? env.sensors.hottest?.value ?? 0
        let rpm = env.fans.fans.isEmpty ? nil : env.fans.fans.map(\.actualRPM).reduce(0, +) / Double(env.fans.fans.count)
        let snap = MenuBarSnapshot(celsius: c, rpm: rpm, normalized: ThermalScale.soc.normalized(c), alert: env.alerts.hasActiveAlert)
        status?.update(snap, style: env.fans.hasFans ? env.settings.menuBar.style : .temp, colored: env.settings.menuBar.colored)
    }
}
