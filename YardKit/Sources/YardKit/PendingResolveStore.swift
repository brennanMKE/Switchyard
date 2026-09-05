// PendingResolveStore.swift — the app side's pending resolve state (#0057)
//
// The store lives in YardKit, not the app target, so the package suite can
// test the blocking semantics directly: supersede, the typed timeout, and
// resolution. It is state and nothing else — it NEVER talks to AppKit. Round
// 2's resolution pane binds to `pendingResolves` and resolves through
// `resolve`; the same API a test double drives.

import Foundation

/// One pending resolve per repository common dir, replaceable (#0057).
///
/// The rules the design pins, in this type:
///
/// - **One pending per repository.** Keyed by the request's resolved
///   `commonDir` — the repository identity (#0079) — not by connection or
///   process, so a second `resolve --wait` for the same repository supersedes
///   the first no matter which CLI connection it arrived on.
/// - **Supersede, not queue.** This is the REVIEW semantics, deliberately
///   not `PendingAskStore`'s FIFO: an interactive resolve presents the
///   repository's conflicts as one sheet, so a newer request replaces the
///   older one and the first CLI receives a typed `.superseded` outcome. The
///   queue is `ask`'s distinction.
/// - **Each request arms its own timeout.** When the human never answers,
///   the store fires a typed `.timedOut` outcome after the request's own
///   `timeoutSeconds`. The CLI also runs its own backstop (timeout + 5 s) in
///   case the reply is lost on the wire, but the store's typed outcome is
///   what normally arrives.
///
/// Locking, not an actor: the app exports this store to XPC service objects
/// on XPC's own queues while the UI (round 2) reads it from the main actor.
/// `@unchecked Sendable` for the same reason as `PendingReviewStore` — the
/// lock, not the type system, is what makes concurrent use safe.
public final class PendingResolveStore: @unchecked Sendable {

    /// A pending resolve as the pane observes it: the request as registered,
    /// and the id a later `resolve(id:reply:)` names.
    public struct Pending: Sendable, Equatable {
        public let id: UUID
        public let request: ResolveRequest

        /// Public so a test can construct a pending directly — the same
        /// value shape the store hands its observers. The store generates
        /// its own ids in `awaitDecision`; a constructed one is for
        /// driving models and views.
        public init(id: UUID, request: ResolveRequest) {
            self.id = id
            self.request = request
        }
    }

    private struct Slot {
        let pending: Pending
        let continuation: CheckedContinuation<ResolveOutcome, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    /// Fired whenever a pending resolve is registered or resolves — the
    /// #0055 hook pattern, round 2's observation seam. `outcome` is nil for
    /// a registration and the typed outcome for a resolution — decided
    /// (resolutions or a cancellation), timedOut, or superseded — so the UI
    /// side can present on registration and reflect (or dismiss on) the
    /// store's outcome without polling `pendingResolves`.
    ///
    /// Called OUTSIDE the lock, on whatever task or queue touched the store,
    /// right after the store's own state change is complete. Set before
    /// serving begins; the store reads it unlocked, so a caller that mutates
    /// it mid-serving owns that race.
    public var onPendingChange: (@Sendable (Pending, ResolveOutcome?) -> Void)?

    public init() {}

    /// The pending resolves right now — one per repository. Round 2's pane
    /// binds to this snapshot; the store itself never touches AppKit.
    public var pendingResolves: [Pending] {
        lock.withLock {
            slots.values.map(\.pending).sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    /// Registers `request` and suspends until the human answers, the
    /// request's own timeout fires, or a newer request for the same
    /// repository supersedes it. The app-side body awaits this on behalf of
    /// the blocked CLI; the store is the only thing that resumes it.
    public func awaitDecision(for request: ResolveRequest) async -> ResolveOutcome {
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

    /// Resolves the pending resolve for `commonDir` with the human's answer —
    /// per-path resolutions, or `.cancelled` (which stages nothing, touches
    /// nothing, and is the arm's exit-7 path).
    /// Returns false when nothing is pending there.
    @discardableResult
    public func resolve(commonDir: String, answer: ResolveReply) -> Bool {
        finish(id: nil, commonDir: commonDir, outcome: .decided(answer))
    }

    /// Resolves one pending resolve by id — the pane's path, since it holds
    /// the id from `pendingResolves`. Returns false when that id is gone.
    @discardableResult
    public func resolve(id: UUID, answer: ResolveReply) -> Bool {
        let commonDir: String? = lock.withLock {
            slots.first(where: { $0.value.pending.id == id })?.key
        }
        guard let commonDir else { return false }
        return finish(id: id, commonDir: commonDir, outcome: .decided(answer))
    }

    /// Removes the slot when it is still current and resumes its waiter.
    /// `requiredID == nil` means "whatever is pending for this repository".
    private func finish(id requiredID: UUID?, commonDir: String, outcome: ResolveOutcome) -> Bool {
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
/// package tests (#0055 round 1's pattern): decode the request bytes,
/// register the pending resolve under the already-resolved common dir, await
/// the typed outcome, encode it.
///
/// The common dir is a parameter, not a resolution: resolving it needs the
/// engine (`WorktreeContext`, YardGit), which YardKit does not link. The
/// app-side wrapper — `runResolveRequest` in `YardCommands` — resolves the
/// repository, enumerates the conflicts, and calls this; a test passes a
/// fixture value directly.
///
/// When the request bytes cannot be decoded, or no repository could be
/// resolved (`commonDir` nil), NOTHING is registered and a failure envelope
/// is returned instead — the CLI renders it verbatim. Repository-level
/// failures are never encoded as resolve outcomes: an outcome answers "what
/// did the human say", and "there was no repository" is not an answer.
public enum ResolveServing {

    public static func handle(
        requestData: Data,
        commonDir: String?,
        store: PendingResolveStore
    ) async -> Data {
        guard let request = try? JSONDecoder().decode(ResolveRequest.self, from: requestData) else {
            return failureEnvelope(
                code: .requestFailed,
                message: "the resolve request could not be decoded")
        }
        guard let commonDir else {
            return failureEnvelope(
                code: .repositoryError,
                message: "the working directory is not inside a git repository")
        }

        // The CLI sends `commonDir` empty (it cannot resolve the repository);
        // the resolved value is what the store keys on and what the pane sees.
        var registered = request
        registered.commonDir = commonDir

        let outcome = await store.awaitDecision(for: registered)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(outcome))
            ?? failureEnvelope(code: .requestFailed, message: "Failed to encode the resolve outcome.")
    }

    private static func failureEnvelope(code: EnvelopeErrorCode, message: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return (try? encoder.encode(EnvelopeFail(code: code, message: message))) ?? Data()
    }
}
