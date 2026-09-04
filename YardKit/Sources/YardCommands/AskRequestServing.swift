// AskRequestServing.swift — the app-side body of `AppServiceProtocol
// .performAsk` (#0056)

import Foundation
import YardGit
import YardKit

/// The app-side body of `AppServiceProtocol.performAsk` (#0056) — the
/// single function the app's `AppService` forwards to, kept here (linked by
/// the app alone, like every engine-backed arm) so `swift test` exercises
/// the exact body the wire serves rather than a copy that could drift from
/// it.
///
/// `ask` is `review` without the diff: the body resolves the repository
/// (one `WorktreeContext.resolve`, the one piece of engine work), hands the
/// resolved request and context to `onPending` so the app target's bridge
/// can route the ask to the repository's tab (#0084 focus-or-open), and
/// registers into the pending ask store — where the FIFO queue, the
/// head-only timeout, and the blocking semantics live (`PendingAskStore`).
///
/// The CLI cannot resolve the repository itself (it does not link the
/// engine), so it sends `AskRequest.commonDir` empty and its working
/// directory as the protocol method's own parameter. This body fills the
/// resolved common dir in before the request is registered. When the
/// working directory does not resolve to a repository, nothing is
/// registered and the failure envelope is returned — repository-level
/// failures are never encoded as ask outcomes, because "there was no
/// repository" is not an answer to "what did the human say".
public func runAskRequest(
    requestData: Data,
    workingDirectory: String,
    store: PendingAskStore,
    onPending: (@Sendable (AskRequest, WorktreeContext) -> Void)? = nil
) async -> Data {
    let context = try? await WorktreeContext.resolve(path: workingDirectory)
    guard let context else {
        return await AskServing.handle(
            requestData: requestData,
            commonDir: nil,
            store: store)
    }

    // Deliver the resolved request BEFORE registration, the same order the
    // review body uses: the bridge routes the tab first, so the sheet's
    // registration event lands on a centre already pointed at the right
    // repository.
    if let request = try? JSONDecoder().decode(AskRequest.self, from: requestData) {
        var registered = request
        registered.commonDir = context.commonDir
        onPending?(registered, context)
    }

    return await AskServing.handle(
        requestData: requestData,
        commonDir: context.commonDir,
        store: store)
}
