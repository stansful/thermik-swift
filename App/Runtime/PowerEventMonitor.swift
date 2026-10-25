// PowerEventMonitor.swift — Thermik (MIT). STUB by Unit 0; OWNER: Unit 5 (port research/system/prod/PowerEvents.swift,
// NSWorkspace sleep/wake/screens + IOPS change + Low Power Mode). Surface FROZEN.
import Foundation
import ThermikCore

enum PowerEvent: Sendable, Equatable {
    case willSleep, didWake, screensDidSleep, screensDidWake, willPowerOff
    case powerSourceChanged
    case lowPowerModeChanged(Bool)
}

@MainActor final class PowerEventMonitor {
    var onEvent: (PowerEvent) -> Void = { _ in }
    init() {}
    func start() {}
}
