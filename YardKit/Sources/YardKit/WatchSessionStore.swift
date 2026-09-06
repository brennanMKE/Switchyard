// WatchSessionStore.swift — the app side's watch sessions (#0058)
//
// The store lives in YardKit, not the app target, so the package suite can
// test the session semantics directly, the way `PendingAskStore` does. It
// is state and nothing else — it never talks to AppKit or XPC: sessions
// register a push closure, and the store's only knowledge of the client is
// that closure.
//
// **The memory criterion's structural half lives here.** The stream is
// push-based: `broadcast` encodes each event, hands the bytes to every
// session's push closure, and forgets them. No slot retains events, no
// accessor reads events back — a long session accumulates sessions (one per
// watching CLI, each a fixed-size slot), never events. RemoteControl's
// 940 MB of RSS growth while streaming is the defect this shape exists to
// make impossible; the round-2 measurement checks the number, this type
// checks the structure.

import Foundation

/// One active watch session, as the app's UI (round 2) and tests observe it:
/// the request as registered and the id later `end(id:)` calls name. No
/// event state — see the type comment on the store.
public struct WatchSession: Sendable, Equatable {
    public let id: UUID
    public let request: WatchRequest

    public init(id: UUID, request: WatchRequest) {
        self.id = id
        self.request = request
    }
}

/// The app's active watch sessions (#0058).
///
/// Locking, not an actor, for the same reason as `PendingAskStore`: the app
/// exports the serving body to XPC queues while other callers (tests, the
/// app's quit path) touch the store from elsewhere. `@unchecked Sendable`
/// because the lock, not the type system, is what makes concurrent use safe.
///
/// Sequence numbers are per session: `broadcast` bumps each slot's counter,
/// so every watching CLI sees its own monotonic 1, 2, 3, … regardless of
/// what other sessions or sources do.
public final class WatchSessionStore: @unchecked Sendable {

    private struct Slot {
        let session: WatchSession
        /// Which CLI connection registered this session (#0349) — what
        /// `dropAll(ownedBy:)` matches on.
        let owner: PendingOwner
        /// Delivers one encoded event to this session's client. The store
        /// retains no events — this closure is the only path they travel.
        let push: @Sendable (Data) -> Void
        /// Resumed exactly once, at session end, with the end reason.
        let continuation: CheckedContinuation<WatchEndReason, Never>
        /// This session's next sequence number minus one. Starts at 0; the
        /// first event gets 1.
        var sequence = 0
        /// Armed when `request.timeoutSeconds != nil`; fires `.timedOut`.
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]

    public init() {}

    /// Every active session, in stable id order. The bound test reads this:
    /// after any number of broadcasts it is exactly the registered sessions,
    /// nothing more — the store retains no history.
    public var activeSessions: [WatchSession] {
        lock.withLock {
            slots.values.map(\.session).sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// Registers one session and suspends until it ends, returning the end
    /// reason. The app-side body awaits this on behalf of the blocked CLI;
    /// the store is the only thing that resumes it — via `end`, `endAll`,
    /// `dropAll`, or the request's own timeout.
    ///
    /// `push` delivers encoded events to the session's client; `owner` names
    /// the CLI connection the request arrived on (#0349), so the connection's
    /// invalidation handler can `dropAll(ownedBy:)`.
    public func register(
        request: WatchRequest,
        owner: PendingOwner,
        push: @escaping @Sendable (Data) -> Void
    ) async -> WatchEndReason {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            var slot = Slot(
                session: WatchSession(id: id, request: request),
                owner: owner,
                push: push,
                continuation: continuation)
            lock.lock()
            if let seconds = request.timeoutSeconds {
                slot.timeoutTask = armedTimeout(id: id, seconds: seconds)
            }
            slots[id] = slot
            lock.unlock()
        }
    }

    /// Arms the session's timeout. The sleep swallows only cancellation — a
    /// cancelled task returns without firing, because the slot is already
    /// gone.
    private func armedTimeout(id: UUID, seconds: Int) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Double(seconds)))
            } catch {
                return
            }
            _ = self?.end(id: id, reason: .timedOut)
        }
    }

    /// Pushes one event to every active session, numbered per session.
    ///
    /// Delivered INSIDE the lock: two concurrent broadcasts must not
    /// interleave their pushes out of sequence order — the push order under
    /// the lock IS the sequence order every consumer asserts. Holding the
    /// lock across the pushes is safe because a one-way XPC send is a
    /// non-blocking enqueue, and the push closures never re-enter the store
    /// (they end at the client proxy).
    ///
    /// `repositoryPath` scopes the event: nil delivers to every session;
    /// a path delivers to the all-repositories sessions (request
    /// `repositoryPath` nil) and to sessions watching exactly that path —
    /// the exact-match rule `WatchRequest` documents for this round.
    public func broadcast(
        kind: WatchEvent.Kind,
        payload: [String: WatchJSON],
        repositoryPath: String? = nil
    ) {
        var deliveries: [(@Sendable (Data) -> Void, Data)] = []
        lock.lock()
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        for id in Array(slots.keys) {
            guard var slot = slots[id] else { continue }
            guard slotWants(slot.session.request, repositoryPath: repositoryPath) else { continue }
            slot.sequence += 1
            let event = WatchEvent(sequence: slot.sequence, kind: kind, payload: payload)
            guard let bytes = try? encoder.encode(event) else { continue }
            slots[id] = slot
            deliveries.append((slot.push, bytes))
        }
        for (push, bytes) in deliveries {
            push(bytes)
        }
        lock.unlock()
    }

    /// Whether a session registered with `request` receives an event scoped
    /// to `repositoryPath`. An unscoped event is for everyone; a scoped one
    /// is for the all-repositories sessions and the exact-match sessions.
    private func slotWants(_ request: WatchRequest, repositoryPath: String?) -> Bool {
        guard let repositoryPath else { return true }
        return request.repositoryPath == nil || request.repositoryPath == repositoryPath
    }

    /// Ends one session with `reason` — the app-initiated end (its timeout,
    /// or shutdown via `endAll`). Returns false when no such session is
    /// active; a second `end` for the same id is exactly that, so the
    /// awaiting body's continuation can never be resumed twice.
    @discardableResult
    public func end(id: UUID, reason: WatchEndReason) -> Bool {
        let slot: Slot? = lock.withLock { slots.removeValue(forKey: id) }
        guard let slot else { return false }
        slot.timeoutTask?.cancel()
        slot.continuation.resume(returning: reason)
        return true
    }

    /// Ends every active session — the app-shutdown path (round 2 wires the
    /// quit hook to this). Returns how many ended.
    @discardableResult
    public func endAll(reason: WatchEndReason) -> Int {
        let ended: [Slot] = lock.withLock {
            let removed = Array(slots.values)
            slots.removeAll()
            return removed
        }
        for slot in ended {
            slot.timeoutTask?.cancel()
            slot.continuation.resume(returning: reason)
        }
        return ended.count
    }

    /// Silently removes every session owned by `owner` (#0349) — the
    /// connection-death hook the app's per-connection invalidation handler
    /// calls. Unlike `endAll` this resolves the bodies with `.detached`
    /// rather than pushing a reason to a client that is gone. Idempotent.
    /// Returns how many were dropped.
    @discardableResult
    public func dropAll(ownedBy owner: PendingOwner) -> Int {
        let dropped: [Slot] = lock.withLock {
            var removed: [Slot] = []
            for (id, slot) in slots where slot.owner == owner {
                slots[id] = nil
                removed.append(slot)
            }
            return removed
        }
        for slot in dropped {
            slot.timeoutTask?.cancel()
            slot.continuation.resume(returning: .detached)
        }
        return dropped.count
    }
}

/// The app-side serving body of `AppServiceProtocol.performWatch` (#0058),
/// shared by the app's exported service and the package tests: decode the
/// request bytes, register the session into the store, await its end, and
/// deliver the end reason to the client — `sessionEnded` push first, then
/// the reply bytes the caller hands back to the CLI.
///
/// The delivery seams are closures, not the client object itself, so this
/// body is testable without any NSObject: the app target passes
/// `{ client.event($0) }` / `{ client.sessionEnded(reason: $0) }`, a test
/// passes collecting closures — the same bytes either way.
///
/// When the request bytes cannot be decoded, NOTHING is registered and a
/// failure envelope is returned instead — the CLI renders it verbatim. The
/// reply fires exactly once per session: the store resumes its continuation
/// once, and this body returns once.
public enum WatchServing {

    /// Delivers events to the session's client. The app target wraps its
    /// client proxy here; a test collects.
    public typealias Push = @Sendable (Data) -> Void

    public static func handle(
        requestData: Data,
        store: WatchSessionStore,
        push: @escaping Push,
        sessionEnder: @escaping Push,
        owner: PendingOwner = PendingOwner()
    ) async -> Data {
        guard let request = try? JSONDecoder().decode(WatchRequest.self, from: requestData) else {
            return failureEnvelope(
                code: .requestFailed,
                message: "the watch request could not be decoded")
        }

        let reason = await store.register(request: request, owner: owner, push: push)

        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let reasonBytes = (try? encoder.encode(reason)) ?? Data()
        sessionEnder(reasonBytes)
        return reasonBytes
    }

    private static func failureEnvelope(code: EnvelopeErrorCode, message: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(EnvelopeFail(code: code, message: message))) ?? Data()
    }
}
