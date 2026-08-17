// RepairGate.swift

import Foundation

/// Allows an action at most once for the lifetime of the process.
///
/// Repair is driven by an actually-failed broker call, never by
/// `SMAppService.status` — the two genuinely disagree after a `launchctl
/// bootout`, and a status-driven repair loop was a real source of confusion in
/// RemoteControl. A failed call is evidence; a status is an opinion.
///
/// Guarded by a lock, not an actor, matching `EndpointRegistry` in
/// `XPCProtocols.swift`: XPC error handlers fire on their own queues, so this
/// is reached from several queues concurrently, and callers need a
/// synchronous, non-`async` check.
public final class RepairGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// True exactly once, however many times or from however many queues it is
    /// called. XPC error handlers fire on their own queues, so this is reached
    /// concurrently and the check must be atomic, not a plain `Bool` read.
    @discardableResult
    public func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    public var hasClaimed: Bool {
        lock.withLock { claimed }
    }
}
