// PowerObserver.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// Port of research/helper/skeleton/Helper/PowerObserver.swift (HELP §A.7); invariant I6 (SPEC §2.6.2).
// A daemon gets no NSWorkspace sleep notifications, so it registers with IORegisterForSystemPower and handles the
// messages on its own dispatch queue. `onWillSleep` runs synchronously BEFORE the sleep is acknowledged
// (IOAllowPowerChange), so the fans are back under macOS control when the machine goes down.
import Foundation
import IOKit
import IOKit.pwr_mgt

public final class PowerObserver: @unchecked Sendable {   // handlers set before start(); IOKit state used on `queue` only
    public var onWillSleep: (@Sendable () -> Void)?
    public var onDidWake: (@Sendable () -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let queue = DispatchQueue(label: "app.thermik.helper.power", qos: .userInitiated)

    public init() {}

    // IOMessage.h macros are not imported into Swift: iokit_common_msg(x) = 0xE0000000 | x.
    static let canSystemSleep: natural_t = 0xE000_0270       // kIOMessageCanSystemSleep (idle sleep; may veto)
    static let systemWillSleep: natural_t = 0xE000_0280      // kIOMessageSystemWillSleep (cannot be vetoed)
    static let systemWillNotSleep: natural_t = 0xE000_0290   // kIOMessageSystemWillNotSleep
    static let systemHasPoweredOn: natural_t = 0xE000_0300   // kIOMessageSystemHasPoweredOn

    /// Registers for system power messages. Returns false if IOKit refuses (the helper then relies on the app's
    /// sleep reset and on the lease).
    @discardableResult
    public func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(messageType: messageType, argument: argument)
        }, &notifier)
        guard rootPort != 0, let notifyPort else {
            powerLog.error("IORegisterForSystemPower failed")
            return false
        }
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        powerLog.info("registered for system power notifications")
        return true
    }

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        // `argument` carries the notification ID IOAllowPowerChange expects.
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)       // never veto idle sleep
        case Self.systemWillSleep:
            onWillSleep?()                                      // restore the fans first …
            IOAllowPowerChange(rootPort, notificationID)       // … then let the system sleep
        case Self.systemWillNotSleep:
            powerLog.info("sleep cancelled")
        case Self.systemHasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }
}
