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
/// Round 1 resolves only the repository — one `WorktreeContext.resolve`, the
/// same call every engine arm makes — and hands the request to the pending
/// store. **The diff resolution and rendering are rounds 2/3**: nothing
/// diff-shaped is computed here yet; the sheet (round 2) renders from the
/// registered request once it exists.
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
    store: PendingReviewStore
) async -> Data {
    let context = try? await WorktreeContext.resolve(path: workingDirectory)
    return await ReviewServing.handle(
        requestData: requestData,
        commonDir: context?.commonDir,
        store: store)
}
