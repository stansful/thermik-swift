// XPCServer.swift — Thermik (MIT). HELPER ONLY. OWNER: Unit 4.
// Port of research/helper/skeleton/Helper/XPCServer.swift (HELP §A.6): the NSXPCListener delegate validates each
// peer (PeerValidator, I12), exports one `HelperEndpoint` per connection and reports connections coming and going
// to HelperService (I4). Works with the daemon's Mach service listener and with `NSXPCListener.anonymous()`
// (thermik-probe helper selftest).
import Foundation
import ThermikHelperShared

public final class HelperXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {   // immutable + `lock`
    private let service: HelperService
    private let validator: PeerValidator
    /// Legacy-install self-uninstall (removes the helper's own files, then boots out); nil for other install kinds.
    private let uninstallHandler: (@Sendable () throws -> Void)?
    private let lock = NSLock()
    private var nextToken: UInt64 = 0

    public init(service: HelperService, validator: PeerValidator, uninstallHandler: (@Sendable () throws -> Void)? = nil) {
        self.service = service
        self.validator = validator
        self.uninstallHandler = uninstallHandler
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validator.accept(connection) else { return false }
        let token = lock.withLock { () -> UInt64 in nextToken += 1; return nextToken }
        connection.exportedInterface = HelperWire.makeInterface()
        connection.exportedObject = HelperEndpoint(service: service, uninstallHandler: uninstallHandler)
        // Both handlers may fire for one connection; HelperService treats connectionClosed idempotently.
        connection.invalidationHandler = { [service] in service.connectionClosed(token) }
        connection.interruptionHandler = { [service] in service.connectionClosed(token) }
        service.connectionOpened(token)
        connection.activate()
        xpcLog.notice("accepted client pid \(connection.processIdentifier, privacy: .public) euid \(connection.effectiveUserIdentifier, privacy: .public)")
        return true
    }
}

/// One per connection. NSXPC calls these on its private queues; each call hops onto the service's state queue.
/// No method takes a path, a command or an SMC key (I14).
final class HelperEndpoint: NSObject, ThermikHelperXPC, @unchecked Sendable {   // immutable
    private let service: HelperService
    private let uninstallHandler: (@Sendable () throws -> Void)?

    init(service: HelperService, uninstallHandler: (@Sendable () throws -> Void)?) {
        self.service = service
        self.uninstallHandler = uninstallHandler
    }

    func hello(clientProtocolVersion: Int, reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        service.hello(clientProtocolVersion: clientProtocolVersion, reply: reply)
    }

    func getState(reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        service.getState(reply: reply)
    }

    func setFanTarget(fanIndex: Int, rpm: Double, leaseSeconds: Double, reply: @escaping @Sendable (Double, NSError?) -> Void) {
        service.setFanTarget(fanIndex: fanIndex, rpm: rpm, leaseSeconds: leaseSeconds, reply: reply)
    }

    func setFanAutomatic(fanIndex: Int, reply: @escaping @Sendable (NSError?) -> Void) {
        service.setFanAutomatic(fanIndex: fanIndex, reply: reply)
    }

    func renewLease(leaseSeconds: Double, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        service.renewLease(leaseSeconds: leaseSeconds, reply: reply)
    }

    func resetAllFans(reply: @escaping @Sendable (NSError?) -> Void) {
        service.resetAllFans(reason: "resetAll", reply: reply)
    }

    func uninstallLegacyHelper(reply: @escaping @Sendable (NSError?) -> Void) {
        service.uninstallLegacy(uninstallHandler, reply: reply)
    }
}
