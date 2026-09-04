// PendingReviewStore.swift — the app side's pending review state (#0055)
//
// The store lives in YardKit, not the app target, so the package suite can
// test the blocking semantics directly: supersede, the typed timeout, and
// resolution. It is state and nothing else — it NEVER talks to AppKit. Round
// 2's sheet binds to `pendingReviews` and resolves through `resolve`; the
// same API a test double drives.

import Foundation

/// One pending review per repository common dir, replaceable (#0055).
///
/// The rules the issue pins, in this type:
///
/// - **One pending per repository.** Keyed by the request's resolved
///   `commonDir` — the repository identity (#0079) — not by connection or
///   process, so a second `review --wait` for the same repository supersedes
///   the first no matter which CLI connection it arrived on.
/// - **A superseded waiter receives a typed superseded outcome.** Not a
///   timeout lie, not a decision: the first CLI's process exits 4
///   (`requestFailed`) with a message saying it was superseded.
/// - **Each request arms its own timeout.** When the human never answers,
///   the store fires a typed `.timedOut` outcome after the request's own
///   `timeoutSeconds`. The CLI also runs its own backstop (timeout + 5 s) in
///   case the reply is lost on the wire, but the store's typed outcome is
///   what normally arrives.
///
/// Locking, not an actor: the app exports this store to XPC service objects
/// on XPC's own queues while the UI (round 2) reads it from the main actor.
/// `@unchecked Sendable` for the same reason as `EndpointRegistry` — the
/// lock, not the type system, is what makes concurrent use safe.
public final class PendingReviewStore: @unchecked Sendable {

    /// A pending review as the sheet observes it: the request as registered,
    /// and the id a later `resolve(id:reply:)` names.
    public struct Pending: Sendable, Equatable {
        public let id: UUID
        public let request: ReviewRequest

        /// Public so a test can construct a pending directly — the same
        /// value shape the store hands its observers. The store generates
        /// its own ids in `awaitDecision`; a constructed one is for
        /// driving models and views.
        public init(id: UUID, request: ReviewRequest) {
            self.id = id
            self.request = request
        }
    }

    private struct Slot {
        let pending: Pending
        let continuation: CheckedContinuation<ReviewOutcome, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    /// Fired whenever a pending review is registered or resolves (#0055
    /// round 2). `outcome` is nil for a registration and the typed outcome
    /// for a resolution — decided, timedOut, or superseded — so the UI
    /// side can create the sheet on registration and reflect (or dismiss
    /// on) the store's outcome without polling `pendingReviews`.
    ///
    /// Called OUTSIDE the lock, on whatever task or queue touched the store,
    /// right after the store's own state change is complete — the same
    /// discipline as the continuation resume above. The observer hops where
    /// it needs to (the UI side lands on the main actor via a `Task`).
    /// Set before serving begins; the store reads it unlocked, so a caller
    /// that mutates it mid-serving owns that race.
    public var onPendingChange: (@Sendable (Pending, ReviewOutcome?) -> Void)?

    public init() {}

    /// The pending reviews right now — one per repository. Round 2's sheet
    /// binds to this snapshot; the store itself never touches AppKit.
    public var pendingReviews: [Pending] {
        lock.withLock {
            slots.values.map(\.pending).sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// Registers `request` and suspends until the human decides, the
    /// request's own timeout fires, or a newer request for the same
    /// repository supersedes it. The app-side body awaits this on behalf of
    /// the blocked CLI; the store is the only thing that resumes it.
    public func awaitDecision(for request: ReviewRequest) async -> ReviewOutcome {
        let id = UUID()
        let commonDir = request.commonDir
        return await withCheckedContinuation { continuation in
            let newPending = Pending(id: id, request: request)
            // The timeout is armed for THIS request: one sleep per pending,
            // cancelled when the slot resolves any other way. `try?` on the
            // sleep swallows only cancellation — a cancelled task returns
            // without firing, because the slot is already gone.
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Double(request.timeoutSeconds)))
                } catch {
                    return
                }
                _ = self?.finish(id: id, commonDir: commonDir, outcome: .timedOut)
            }

            var supersededSlot: Slot?
            lock.lock()
            supersededSlot = slots.removeValue(forKey: commonDir)
            slots[commonDir] = Slot(
                pending: newPending,
                continuation: continuation,
                timeoutTask: timeoutTask)
            lock.unlock()

            // Resumed outside the lock, so a waiter that immediately calls
            // back into the store cannot deadlock it.
            if let supersededSlot {
                supersededSlot.timeoutTask?.cancel()
                supersededSlot.continuation.resume(returning: .superseded)
                onPendingChange?(supersededSlot.pending, .superseded)
            }
            onPendingChange?(newPending, nil)
        }
    }

    /// Resolves the pending review for `commonDir` with the human's decision.
    /// Returns false when nothing is pending there.
    @discardableResult
    public func resolve(commonDir: String, decision: ReviewReply) -> Bool {
        finish(id: nil, commonDir: commonDir, outcome: .decided(decision))
    }

    /// Resolves one pending review by id — the sheet's path, since it holds
    /// the id from `pendingReviews`. Returns false when that id is gone.
    @discardableResult
    public func resolve(id: UUID, decision: ReviewReply) -> Bool {
        let commonDir: String? = lock.withLock {
            slots.first(where: { $0.value.pending.id == id })?.key
        }
        guard let commonDir else { return false }
        return finish(id: id, commonDir: commonDir, outcome: .decided(decision))
    }

    /// Removes the slot when it is still current and resumes its waiter.
    /// `requiredID == nil` means "whatever is pending for this repository".
    private func finish(id requiredID: UUID?, commonDir: String, outcome: ReviewOutcome) -> Bool {
        var slot: Slot?
        lock.lock()
        if let existing = slots[commonDir], requiredID == nil || existing.pending.id == requiredID {
            slot = slots.removeValue(forKey: commonDir)
        }
        lock.unlock()

        guard let slot else { return false }
        slot.timeoutTask?.cancel()
        slot.continuation.resume(returning: outcome)
        onPendingChange?(slot.pending, outcome)
        return true
    }
}

/// The app-side serving body, shared by the app's exported service and the
/// package tests (#0055 round 1): decode the request bytes, register the
/// pending review under the already-resolved common dir, await the typed
/// outcome, encode it.
///
/// The common dir is a parameter, not a resolution: resolving it needs the
/// engine (`WorktreeContext`, YardGit), which YardKit does not link. The
/// app-side wrapper — `runReviewRequest` in `YardCommands` — resolves it and
/// calls this; a test passes a fixture value directly.
///
/// When the request bytes cannot be decoded, or no repository could be
/// resolved (`commonDir` nil), NOTHING is registered and a failure envelope
/// is returned instead — the CLI renders it verbatim. Repository-level
/// failures are never encoded as review outcomes: an outcome answers "what
/// did the human say", and "there was no repository" is not an answer.
public enum ReviewServing {

    public static func handle(
        requestData: Data,
        commonDir: String?,
        store: PendingReviewStore
    ) async -> Data {
        guard let request = try? JSONDecoder().decode(ReviewRequest.self, from: requestData) else {
            return failureEnvelope(
                code: .requestFailed,
                message: "the review request could not be decoded")
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
            ?? failureEnvelope(code: .requestFailed, message: "Failed to encode the review outcome.")
    }

    private static func failureEnvelope(code: EnvelopeErrorCode, message: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(EnvelopeFail(code: code, message: message))) ?? Data()
    }
}
