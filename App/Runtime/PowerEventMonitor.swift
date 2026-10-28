// PowerEventMonitor.swift — Thermik (MIT). OWNER: Unit 5 (port of research/system/prod/PowerEvents.swift:
// NSWorkspace sleep/wake/screens + IOPS change + Low Power Mode). Surface FROZEN.
// The app does not register with IORegisterForSystemPower: it never needs to delay sleep. The root helper restores
// the fans itself on kIOMessageSystemWillSleep before acknowledging (SPEC §2.3.5); `.willSleep` here is the app's
// belt-and-braces path.
import AppKit
import Foundation
import IOKit.ps
import os
import ThermikCore

enum PowerEvent: Sendable, Equatable {
    case willSleep, didWake, screensDidSleep, screensDidWake, willPowerOff
    case powerSourceChanged
    case lowPowerModeChanged(Bool)
}

@MainActor final class PowerEventMonitor {
    var onEvent: (PowerEvent) -> Void = { _ in }
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var defaultObservers: [any NSObjectProtocol] = []
    private var powerSourceLoop: CFRunLoopSource?
    private var context: Unmanaged<IOPSContext>?
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let log = Logger(subsystem: "app.thermik.Thermik", category: "power")

    init() {}

    func start() {
        guard workspaceObservers.isEmpty else { return }
        // Sleep/wake/power-off are posted on NSWorkspace's own center, NOT NotificationCenter.default.
        let ws = NSWorkspace.shared.notificationCenter
        let map: [(NSNotification.Name, PowerEvent)] = [(NSWorkspace.willSleepNotification, .willSleep),
                                                        (NSWorkspace.didWakeNotification, .didWake),
                                                        (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
                                                        (NSWorkspace.screensDidWakeNotification, .screensDidWake),
                                                        (NSWorkspace.willPowerOffNotification, .willPowerOff)]
        for (name, event) in map {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(event) }
            })
        }
        defaultObservers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeMayHaveChanged() }
        })
        // IOPS change notifications (public IOKit.ps): any change of percentage, AC attach, time remaining. The C
        // callback cannot capture, so a retained box carries a weak reference back; the source runs on the main loop.
        let box = Unmanaged.passRetained(IOPSContext(monitor: self))
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated {
                Unmanaged<IOPSContext>.fromOpaque(ctx).takeUnretainedValue().monitor?.emit(.powerSourceChanged)
            }
        }, box.toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSourceLoop = src
            context = box
        } else {
            box.release()
            log.error("IOPSNotificationCreateRunLoopSource failed; power source changes are polled only")
        }
    }

    func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.removeAll(); defaultObservers.removeAll()
        if let src = powerSourceLoop { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode) }
        powerSourceLoop = nil
        context?.release(); context = nil
    }

    private func lowPowerModeMayHaveChanged() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard on != lowPowerMode else { return }
        lowPowerMode = on
        emit(.lowPowerModeChanged(on))
    }

    private func emit(_ e: PowerEvent) {
        switch e {
        case .powerSourceChanged: log.debug("power event \(String(describing: e), privacy: .public)")
        default: log.info("power event \(String(describing: e), privacy: .public)")
        }
        onEvent(e)
    }
}

/// C-callback context for the IOPS run-loop source (main run loop only).
@MainActor private final class IOPSContext {
    weak var monitor: PowerEventMonitor?
    init(monitor: PowerEventMonitor) { self.monitor = monitor }
}
