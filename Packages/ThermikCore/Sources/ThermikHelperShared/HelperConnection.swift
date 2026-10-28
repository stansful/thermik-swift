// HelperConnection.swift — Thermik (MIT). App-side NSXPC client of the privileged helper. OWNER: Unit 4.
// Port of research/helper/skeleton/App/HelperConnection.swift (HELP §A.9), conforming to `FanHelperClient`
// (SPEC §2.6.6). Public API FROZEN (SPEC A.2).
//
// Lazily (re)connecting: an interruption (helper crashed, idle-exited, was upgraded) keeps the NSXPCConnection —
// the next message makes launchd relaunch the helper — and reports `onDisconnect(false)` so FanStore re-sends its
// targets. An invalidation (not installed, not approved, a code-signing requirement failed) drops it and reports
// `onDisconnect(true)`; the next call creates a fresh connection.
// Every call is bridged with a checked continuation guarded by a once-flag, because the reply, the proxy error
// handler and the client-side timeout (15 s: the first manual command on M3/M4 can block for the Ftst unlock) race.
import Foundation
import os

private let clientLog = Logger(subsystem: ThermikHelper.appBundleIdentifier, category: "helper-client")

public final class HelperConnection: FanHelperClient, @unchecked Sendable {   // mutable state is guarded by `lock`
    public typealias Factory = @Sendable () -> NSXPCConnection

    /// (invalidated) → true: gone (re-check install status); false: interrupted (helper restarted; re-send targets).
    /// Called on an NSXPC queue.
    public var onDisconnect: (@Sendable (_ invalidated: Bool) -> Void)? {
        get { lock.withLock { disconnectHandler } }
        set { lock.withLock { disconnectHandler = newValue } }
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var disconnectHandler: (@Sendable (_ invalidated: Bool) -> Void)?
    private let factory: Factory
    private let helperRequirement: String?
    private let timeoutSeconds: Double

    public init(factory: @escaping Factory, helperRequirement: String?, timeout: Duration = .seconds(ThermikHelper.Limits.replyTimeoutSeconds)) {
        self.factory = factory
        self.helperRequirement = helperRequirement
        let c = timeout.components
        self.timeoutSeconds = max(0.1, Double(c.seconds) + Double(c.attoseconds) / 1e18)
    }

    /// The production connection: the daemon's system-domain Mach service.
    public static func privileged(helperRequirement: String?) -> HelperConnection {
        HelperConnection(factory: { NSXPCConnection(machServiceName: ThermikHelper.machServiceName, options: .privileged) },
                         helperRequirement: helperRequirement)
    }

    /// Requirement the APP places on the helper. Defense in depth: only launchd (root) can publish a system-domain
    /// Mach service. Not a cdhash pin on purpose — the app must still reach an OLDER helper to learn it needs an upgrade.
    public static func requirementForHelper(appIdentity: CodeIdentity?) -> String {
        if let team = appIdentity?.teamID, !team.isEmpty {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(ThermikHelper.helperSigningIdentifier)\""
        }
        return "identifier \"\(ThermikHelper.helperSigningIdentifier)\""
    }

    /// Drops the current connection (after install / upgrade / uninstall, or to simulate a client exit).
    public func reset() {
        let old = lock.withLock { () -> NSXPCConnection? in
            defer { connection = nil }
            return connection
        }
        old?.invalidate()
    }

    private func current() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let c = factory()
        let id = ObjectIdentifier(c)
        c.remoteObjectInterface = HelperWire.makeInterface()
        if let helperRequirement { c.setCodeSigningRequirement(helperRequirement) }   // macOS 13+; at most once
        c.interruptionHandler = { [weak self] in
            clientLog.notice("helper connection interrupted")
            self?.onDisconnect?(false)
        }
        c.invalidationHandler = { [weak self] in
            clientLog.notice("helper connection invalidated")
            guard let self else { return }
            self.lock.withLock {
                if let cur = self.connection, ObjectIdentifier(cur) == id { self.connection = nil }
            }
            self.onDisconnect?(true)
        }
        c.activate()
        connection = c
        return c
    }

    private static func timeoutError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid,
                userInfo: [NSLocalizedDescriptionKey: "the helper did not reply in time"])
    }

    /// Bridges one NSXPC call to async/await. Exactly one resume, whichever of reply / error handler / timeout wins.
    private func call<T: Sendable>(_ body: (any ThermikHelperXPC, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        let connection = current()
        let seconds = timeoutSeconds
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
            let once = OnceFlag()
            // Cancelled as soon as the call completes, so nothing waits out the full timeout.
            let timer = Task {
                try await Task.sleep(for: .seconds(seconds))
                if once.claim() { cont.resume(throwing: Self.timeoutError()) }
            }
            let finish: @Sendable (Result<T, any Error>) -> Void = { result in
                guard once.claim() else { return }
                timer.cancel()
                cont.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in finish(.failure(error)) }
            guard let helper = proxy as? any ThermikHelperXPC else {
                finish(.failure(NSError.thermikHelper(.internalError, "bad XPC proxy")))
                return
            }
            body(helper, finish)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try HelperWire.decode(type, from: data) }
        catch let error as NSError where error.domain == ThermikHelper.errorDomain { throw error }
        catch { throw NSError.thermikHelper(.internalError, "malformed reply: \(error)") }
    }

    private static func result(_ data: Data?, _ error: NSError?) -> Result<Data, any Error> {
        if let error { return .failure(error) }
        if let data { return .success(data) }
        return .failure(NSError.thermikHelper(.internalError, "empty reply"))
    }

    private static func result(_ error: NSError?) -> Result<Void, any Error> {
        error.map { .failure($0) } ?? .success(())
    }

    // MARK: FanHelperClient

    public func hello() async throws -> HelperInfo {
        let data: Data = try await call { helper, done in
            helper.hello(clientProtocolVersion: ThermikHelper.protocolVersion) { done(Self.result($0, $1)) }
        }
        return try Self.decode(HelperInfo.self, data)
    }

    public func state() async throws -> HelperState {
        let data: Data = try await call { helper, done in
            helper.getState { done(Self.result($0, $1)) }
        }
        return try Self.decode(HelperState.self, data)
    }

    public func setFanTarget(_ index: Int, rpm: Double, leaseSeconds: Double) async throws -> Double {
        try await call { helper, done in
            helper.setFanTarget(fanIndex: index, rpm: rpm, leaseSeconds: leaseSeconds) { applied, error in
                done(error.map { .failure($0) } ?? .success(applied))
            }
        }
    }

    public func setFanAutomatic(_ index: Int) async throws {
        try await call { helper, done in helper.setFanAutomatic(fanIndex: index) { done(Self.result($0)) } }
    }

    public func renewLease(seconds: Double) async throws -> Bool {
        try await call { helper, done in
            helper.renewLease(leaseSeconds: seconds) { stillControlling, error in
                done(error.map { .failure($0) } ?? .success(stillControlling))
            }
        }
    }

    public func resetAllFans() async throws {
        try await call { helper, done in helper.resetAllFans { done(Self.result($0)) } }
    }

    public func uninstallLegacyHelper() async throws {
        try await call { helper, done in helper.uninstallLegacyHelper { done(Self.result($0)) } }
    }

    /// Bounded synchronous reset for applicationWillTerminate. Never throws. No-op when no connection exists
    /// (nothing was ever sent, or the helper was unreachable): it must not launch the daemon just to quit, and the
    /// helper restores on its own when the client goes away (I4).
    public func resetAllFansBlocking(timeout: TimeInterval) {
        guard let connection = lock.withLock({ self.connection }) else { return }
        let sem = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in sem.signal() }) as? any ThermikHelperXPC else { return }
        proxy.resetAllFans { _ in sem.signal() }
        if sem.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            clientLog.error("resetAllFans did not complete within \(timeout, privacy: .public) s")
        }
    }
}

/// One-shot latch (thread-safe).
final class OnceFlag: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
