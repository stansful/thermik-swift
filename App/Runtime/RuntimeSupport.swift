// RuntimeSupport.swift — Thermik (MIT). OWNER: Unit 5. Small concurrency helpers for the app runtime: continuous
// observation of @Observable state from non-view code, and bounded waits.
import Foundation
import Observation

/// Calls `onChange` on the main actor every time a property read inside `read` changes, after the change.
/// `withObservationTracking` fires once per registration (on `willSet`), so the next tracking is armed from a
/// main-actor task; several changes made in one run-loop turn coalesce into a single call. The loop ends when
/// `onChange` returns `false` (the owner is gone).
@MainActor func observeContinuously(_ read: @escaping @MainActor @Sendable () -> Void,
                                    onChange: @escaping @MainActor @Sendable () -> Bool) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in
            if onChange() { observeContinuously(read, onChange: onChange) }
        }
    }
}

/// Awaits `operation` for at most `timeout`. Returns false on timeout; the operation then keeps running and its
/// completion is ignored (used where a slow reader must not hold up launch).
@MainActor @discardableResult
func waitAtMost(_ timeout: Duration, _ operation: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
    let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
    Task { @MainActor in await operation(); continuation.yield(true); continuation.finish() }
    let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(false); continuation.finish() }
    defer { timer.cancel() }
    for await finished in stream { return finished }
    return false
}

extension Duration {
    /// Seconds as a Double (`components.seconds` alone truncates).
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
