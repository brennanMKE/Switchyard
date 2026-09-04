// ReviewRequestServing.swift — the app-side body of `AppServiceProtocol
// .performReview` (#0055)

import Foundation
import os
import YardGit
import YardKit

/// The app-side body of `AppServiceProtocol.performReview` (#0055) — the
/// single function the app's `AppService` forwards to, kept here (linked by
/// the app alone, like every engine-backed arm) so `swift test` exercises the
/// exact body the wire serves rather than a copy that could drift from it.
///
/// Round 2 resolves the diff as well as the repository: the request's
/// selector is computed engine-side (`--staged` → `listHunks(at:area:)`, a
/// range → `commitDiff`) over the resolved context's working tree — the
/// request may have arrived from a linked worktree or a subdirectory, where
/// a diff run against the common dir would show the wrong worktree's index.
/// The result is handed to `onPending` together with the resolved context so
/// the app target's bridge can attach it to the sheet model and route the
/// review to the repository's tab (#0084 focus-or-open); registration and
/// blocking stay with `ReviewServing` and the pending store, exactly as
/// round 1 left them.
///
/// The CLI cannot resolve the repository itself (it does not link the
/// engine), so it sends `ReviewRequest.commonDir` empty and its working
/// directory as the protocol method's own parameter. This body fills the
/// resolved common dir in before the request is registered. When the working
/// directory does not resolve to a repository, nothing is registered and the
/// failure envelope is returned — repository-level failures are never encoded
/// as review outcomes, because "there was no repository" is not an answer to
/// "what did the human say".
public func runReviewRequest(
    requestData: Data,
    workingDirectory: String,
    store: PendingReviewStore,
    onPending: (@Sendable (ReviewRequest, WorktreeContext, [FileDiff], String?) -> Void)? = nil
) async -> Data {
    let context = try? await WorktreeContext.resolve(path: workingDirectory)
    guard let context else {
        return await ReviewServing.handle(
            requestData: requestData,
            commonDir: nil,
            store: store)
    }

    // The diff is computed BEFORE registration, from the request's own
    // selector — the sheet's capture of what the agent asked to have
    // reviewed. A failure is delivered as an error message rather than an
    // empty diff: the two must not read the same ("nothing staged" vs "the
    // diff could not be computed").
    var files: [FileDiff] = []
    var diffError: String?
    var request: ReviewRequest?
    if let decoded = try? JSONDecoder().decode(ReviewRequest.self, from: requestData) {
        request = decoded
        var registered = decoded
        registered.commonDir = context.commonDir
        do {
            files = try await reviewDiff(for: registered, in: context)
        } catch {
            diffError = String(describing: error)
        }
        onPending?(registered, context, files, diffError)
    }

    let outcomeData = await ReviewServing.handle(
        requestData: requestData,
        commonDir: context.commonDir,
        store: store)

    // #0059: once the decision exists, persist it as a note on the reviewed
    // commit. The decision has already been delivered to the CLI at this
    // point — the note is a record, not a step in the exchange — so a
    // persistence failure is swallowed and logged (#0160's invariant, one
    // surface over: a record failure never breaks the human's decision).
    if let request {
        await recordDecisionNote(outcomeData: outcomeData, request: request, in: context)
    }

    return outcomeData
}

/// The unified-logging category the app-side review flow logs under. Same
/// subsystem as the app's other loggers (`ServiceNames.logSubsystem`).
private let reviewLogger = Logger(
    subsystem: ServiceNames.logSubsystem, category: "review")

/// Persists a decided outcome as a review note (#0059). The note body is the
/// `ReviewReply` JSON (encoded here — this is the one site that sees both
/// `YardKit`'s `ReviewReply` and `YardGit`'s `ReviewNotes`), attached to the
/// commit the request's selector points at: `--staged` → the worktree's
/// `HEAD`, a range → its tip (the revision right of the last `..`, or the
/// revision itself when no range was given). Nothing here can fail the
/// review: every failure — the outcome decode, the selector resolution, the
/// note write — is swallowed and logged, because the decision has already
/// reached the CLI and a record failure is never the human's problem
/// (#0160's invariant).
private func recordDecisionNote(
    outcomeData: Data,
    request: ReviewRequest,
    in context: WorktreeContext
) async {
    guard let outcome = try? JSONDecoder().decode(ReviewOutcome.self, from: outcomeData),
          case .decided(let reply) = outcome else {
        // `.timedOut` and `.superseded` are typed non-decisions (#0055) — no
        // decision, no note. An undecodable outcome is likewise not a record.
        return
    }
    do {
        let path = context.topLevel ?? context.commonDir
        guard let commitOID = try await reviewNoteTargetOID(for: request.selector, at: path) else {
            reviewLogger.warning(
                "review decision not recorded: the selector's target commit could not be resolved in \(path, privacy: .public)")
            return
        }
        try await ReviewNotes.record(body: reviewNoteBody(for: reply), forCommitOID: commitOID, at: path)
    } catch {
        reviewLogger.warning(
            "review decision not recorded as a note: \(String(describing: error), privacy: .public)")
    }
}

/// The note body for a decided review: the `ReviewReply` JSON, `sortedKeys` —
/// the same wire shape the outcome rides to the CLI in (#0055), so the note
/// is machine-readable by any reader that knows the review wire.
func reviewNoteBody(for reply: ReviewReply) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let data = (try? encoder.encode(reply)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// The commit a review decision attaches to, resolved from the request's
/// selector: `--staged` reviews the worktree's staged changes against
/// `HEAD`; a range's decision belongs on its tip — the revision right of the
/// LAST `..` (`main..HEAD` → `HEAD`, so a symmetric `a...b` also resolves to
/// `b`), or the revision itself when no separator was given (`HEAD~1` names
/// one commit). `nil` — no target — when the revision does not resolve to a
/// commit (unborn `HEAD`, a deleted repository); the caller logs that and
/// moves on.
func reviewNoteTargetOID(
    for selector: ReviewSelector,
    at path: String,
    git: GitProcess = GitProcess()
) async -> String? {
    let revision: String
    switch selector {
    case .staged:
        revision = "HEAD"
    case .range(let range):
        if let separator = range.range(of: "..", options: .backwards) {
            let right = String(range[separator.upperBound...])
            guard !right.isEmpty else { return nil }
            revision = right
        } else {
            revision = range
        }
    }
    let out = try? await git.capture(
        ["rev-parse", "--verify", "\(revision)^{commit}"], workingDirectory: path)
    guard let out, out.exitCode == 0, let line = out.lines.first, !line.isEmpty else {
        return nil
    }
    return line
}

/// The diff a review request asks for, resolved engine-side from the
/// request's selector: `--staged` lists the worktree's staged hunks, a range
/// is handed to `commitDiff` (which accepts anything `diff-tree` does,
/// including ranges — each commit's blocks concatenate through the same
/// parser). Both calls run over `context.topLevel` — the worktree the
/// request came from — falling back to the common dir for a bare repository.
public func reviewDiff(
    for request: ReviewRequest,
    in context: WorktreeContext
) async throws -> [FileDiff] {
    let path = context.topLevel ?? context.commonDir
    switch request.selector {
    case .staged:
        return try await listHunks(at: path, area: .staged)
    case .range(let revision):
        return try await commitDiff(at: path, revision: revision)
    }
}
