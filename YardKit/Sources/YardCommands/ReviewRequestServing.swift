// ReviewRequestServing.swift — the app-side body of `AppServiceProtocol
// .performReview` (#0055)

import Foundation
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
    if let request = try? JSONDecoder().decode(ReviewRequest.self, from: requestData) {
        var registered = request
        registered.commonDir = context.commonDir
        do {
            files = try await reviewDiff(for: registered, in: context)
        } catch {
            diffError = String(describing: error)
        }
        onPending?(registered, context, files, diffError)
    }

    return await ReviewServing.handle(
        requestData: requestData,
        commonDir: context.commonDir,
        store: store)
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
