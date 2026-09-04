// PendingAskStore.swift — the app side's pending ask state (#0056)
//
// The store lives in YardKit, not the app target, so the package suite can
// test the blocking semantics directly: the FIFO queue, the head-only
// timeout, and resolution. It is state and nothing else — it NEVER talks
// to AppKit. The sheet binds to `pendingAsks` and resolves through
// `resolve`; the same API a test double drives.
//
// `ask` is `review` (#0055) with one behavioural difference, and it lives
// in this type: a second ask for a repository that already has one pending
// QUEUES rather than replacing it. Everything else — keyed by common dir,
// typed timeout, decided replies — matches the review store's shape.

import Foundation

/// One FIFO queue of pending asks per repository common dir (#0056).
///
/// The rules the issue pins, in this type:
///
/// - **Queued, never superseded.** Keyed by the request's resolved
///   `commonDir` — the repository identity (#0079) — each repository holds
///   an ordered queue. A new ask appends; the head is what the sheet
///   presents; answering the head presents the next. No ask is ever
///   resolved by a newer one arriving.
/// - **The timeout applies to the HEAD only, and a queued ask's timer
///   starts when it reaches the head.** Decided here, per the planning
///   pass's open question: arming at registration would run a queued
///   ask's clock while the human is looking at a different question, and
///   the human's answer would lose the race to a timeout that measures
///   waiting-behind-another-ask rather than thinking-about-this-one. The
///   head's clock is the ask the human can actually see.
/// - **A decline is a decided reply with declined semantics** — the CLI
///   exits 7 — never a timeout. `resolve` takes whatever `AskReply` the
///   sheet composed; `declined == true` on it is the CLI's signal.
/// - **Each ask arms its own timeout, at the head.** When the human never
///   answers the head, the store fires a typed `.timedOut` outcome after
///   the head's own `timeoutSeconds`, then the next ask (if any) becomes
///   the head and ITS clock starts. The CLI also runs its own backstop
///   (timeout + 5 s) in case the reply is lost on the wire, but the
///   store's typed outcome is what normally arrives.
///
/// Locking, not an actor: the app exports this store to XPC service objects
/// on XPC's own queues while the UI reads it from the main actor.
/// `@unchecked Sendable` for the same reason as `PendingReviewStore` — the
/// lock, not the type system, is what makes concurrent use safe.
public final class PendingAskStore: @unchecked Sendable {

    /// A pending ask as the sheet observes it: the request as registered,
    /// and the id a later `resolve(id:answer:)` names.
    public struct Pending: Sendable, Equatable {
        public let id: UUID
        public let request: AskRequest

        /// Public so a test can construct a pending directly — the same
        /// value shape the store hands its observers. The store generates
        /// its own ids in `awaitDecision`; a constructed one is for
        /// driving models and views.
        public init(id: UUID, request: AskRequest) {
            self.id = id
            self.request = request
        }
    }

    private struct Slot {
        let pending: Pending
        let continuation: CheckedContinuation<AskOutcome, Never>
        /// nil while the ask sits queued behind a head; armed the moment it
        /// becomes the head. See the timer rule in the type's doc comment.
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var queues: [String: [Slot]] = [:]

    /// Fired whenever a pending ask is registered or resolves — the
    /// `PendingReviewStore` hook pattern. `outcome` is nil for a
    /// registration and the typed outcome for a resolution — decided or
    /// timedOut. A promotion to head fires NO event: queue order is
    /// registration order, so the UI's "first still-pending sheet for this
    /// repository" IS the head, and the sheet model's own `outcome`
    /// transition is what re-evaluates the presentation.
    ///
    /// Called OUTSIDE the lock, on whatever task or queue touched the store,
    /// right after the store's own state change is complete. The observer
    /// hops where it needs to (the UI side lands on the main actor via a
    /// `Task`). Set before serving begins; the store reads it unlocked, so
    /// a caller that mutates it mid-serving owns that race.
    public var onPendingChange: (@Sendable (Pending, AskOutcome?) -> Void)?

    public init() {}

    /// The head of each repository's queue, one per repository — the asks
    /// the sheets present right now. The store itself never touches AppKit.
    public var pendingAsks: [Pending] {
        lock.withLock {
            queues.values.compactMap(\.first?.pending)
                .sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// One repository's full queue, head first. The observability seam for
    /// the queue rule — a test reads this to see the asks waiting behind
    /// the head.
    public func queue(for commonDir: String) -> [Pending] {
        lock.withLock {
            (queues[commonDir] ?? []).map(\.pending)
        }
    }

    /// Registers `request` at the tail of its repository's queue and
    /// suspends until the human decides the ask, the ask's own timeout
    /// fires once it is the head, or the ask is resolved from the sheet.
    /// The app-side body awaits this on behalf of the blocked CLI; the
    /// store is the only thing that resumes it.
    public func awaitDecision(for request: AskRequest) async -> AskOutcome {
        let id = UUID()
        let commonDir = request.commonDir
        return await withCheckedContinuation { continuation in
            let newPending = Pending(id: id, request: request)

            lock.lock()
            var queue = queues[commonDir] ?? []
            let slot = Slot(pending: newPending, continuation: continuation, timeoutTask: nil)
            queue.append(slot)
            if queue.count == 1 {
                // It IS the head: its clock starts now (see the timer rule).
                queue[0].timeoutTask = armedTimeout(for: newPending)
            }
            queues[commonDir] = queue
            lock.unlock()

            onPendingChange?(newPending, nil)
        }
    }

    /// Resolves the head of `commonDir`'s queue with the human's answer.
    /// Returns false when nothing is pending there.
    @discardableResult
    public func resolve(commonDir: String, answer: AskReply) -> Bool {
        let headID: UUID? = lock.withLock {
            queues[commonDir]?.first?.pending.id
        }
        guard let headID else { return false }
        return finish(id: headID, commonDir: commonDir, outcome: .decided(answer))
    }

    /// Resolves one pending ask by id — the sheet's path, since it holds
    /// the id from the centre's models. Only the HEAD may resolve: the
    /// sheet presents the head and nothing else, so an out-of-order id (a
    /// queued ask, or a gone one) returns false rather than jumping the
    /// queue. Returns false when that id is gone or not the head.
    @discardableResult
    public func resolve(id: UUID, answer: AskReply) -> Bool {
        let head: (commonDir: String, id: UUID)? = lock.withLock {
            for (commonDir, slots) in queues {
                guard let first = slots.first, first.pending.id == id else { continue }
                return (commonDir, first.pending.id)
            }
            return nil
        }
        guard let head else { return false }
        return finish(id: head.id, commonDir: head.commonDir, outcome: .decided(answer))
    }

    /// Arms the timeout for a pending that has become the head. The sleep
    /// swallows only cancellation — a cancelled task returns without
    /// firing, because the slot is already gone.
    private func armedTimeout(for pending: Pending) -> Task<Void, Never> {
        let id = pending.id
        let commonDir = pending.request.commonDir
        return Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Double(pending.request.timeoutSeconds)))
            } catch {
                return
            }
            _ = self?.finish(id: id, commonDir: commonDir, outcome: .timedOut)
        }
    }

    /// Removes the head when it is still the ask `id` names, resumes its
    /// waiter, and promotes the next queued ask (arming ITS timer). Returns
    /// whether a resolution happened.
    private func finish(id: UUID, commonDir: String, outcome: AskOutcome) -> Bool {
        var resolved: Slot?
        var promoted: Slot?
        lock.lock()
        if var queue = queues[commonDir], let head = queue.first, head.pending.id == id {
            resolved = queue.removeFirst()
            if !queue.isEmpty {
                let armed = armedTimeout(for: queue[0].pending)
                queue[0].timeoutTask = armed
                promoted = queue[0]
            }
            queues[commonDir] = queue
            if queue.isEmpty {
                queues.removeValue(forKey: commonDir)
            }
        }
        lock.unlock()

        guard let resolved else { return false }
        resolved.timeoutTask?.cancel()
        resolved.continuation.resume(returning: outcome)
        onPendingChange?(resolved.pending, outcome)
        return true
    }
}

/// The app-side serving body, shared by the app's exported service and the
/// package tests (#0056): decode the request bytes, register the pending
/// ask under the already-resolved common dir, await the typed outcome,
/// encode it.
///
/// The common dir is a parameter, not a resolution: resolving it needs the
/// engine (`WorktreeContext`, YardGit), which YardKit does not link. The
/// app-side wrapper — `runAskRequest` in `YardCommands` — resolves it and
/// calls this; a test passes a fixture value directly.
///
/// When the request bytes cannot be decoded, or no repository could be
/// resolved (`commonDir` nil), NOTHING is registered and a failure envelope
/// is returned instead — the CLI renders it verbatim. Repository-level
/// failures are never encoded as ask outcomes: an outcome answers "what did
/// the human say", and "there was no repository" is not an answer.
public enum AskServing {

    public static func handle(
        requestData: Data,
        commonDir: String?,
        store: PendingAskStore
    ) async -> Data {
        guard let request = try? JSONDecoder().decode(AskRequest.self, from: requestData) else {
            return failureEnvelope(
                code: .requestFailed,
                message: "the ask request could not be decoded")
        }
        guard let commonDir else {
            return failureEnvelope(
                code: .repositoryError,
                message: "the working directory is not inside a git repository")
        }

        // The CLI sends `commonDir` empty (it cannot resolve the repository);
        // the resolved value is what the store keys on and what the sheet sees.
        var registered = request
        registered.commonDir = commonDir

        let outcome = await store.awaitDecision(for: registered)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(outcome))
            ?? failureEnvelope(code: .requestFailed, message: "Failed to encode the ask outcome.")
    }

    private static func failureEnvelope(code: EnvelopeErrorCode, message: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(EnvelopeFail(code: code, message: message))) ?? Data()
    }
}
