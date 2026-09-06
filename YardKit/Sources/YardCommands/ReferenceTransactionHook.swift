import Foundation
import YardGit
import YardKit

/// The app-side body of `AppServiceProtocol
/// .performReferenceTransactionHook` (#0154) — the single function the
/// app's `AppService` forwards to, kept here (linked by the app alone,
/// like every engine-backed arm) so `swift test` exercises the exact body
/// the wire serves rather than a copy that could drift from it.
///
/// Runs the decision core — `ReferenceTransaction.runHook`, decide plus
/// `JournalObserved.record` — against the repository the hook process
/// stood in. The CLI shipped state + environment + stdin bytes because the
/// decision core lives in `YardGit`, which the CLI does not link
/// (layering); the core re-derives every gate from what arrived, so the
/// CLI's own gate only ever decided whether stdin was worth draining.
///
/// `watchStore` is the #0058 tap: when present, every entry the invocation
/// recorded is bridged into a `journal_observed` watch event. The bridge
/// runs through `runHook`'s `onRecord`, and its throws are swallowed here —
/// the totality invariant is unchanged by the watch stream: a delivery
/// failure must never break somebody's commit.
///
/// **Total: returns 0 for every input.** A repository that will not
/// resolve, a persistence failure, malformed stdin — all exit 0, because a
/// non-zero exit in the `prepared` state aborts the user's transaction and
/// a journal that cannot record must never break somebody's commit
/// (#0042's totality invariant, unchanged by the XPC hop).
public func runReferenceTransactionHook(
    state: String,
    environment: [String: String],
    standardInput: Data,
    workingDirectory: String,
    watchStore: WatchSessionStore? = nil
) -> Int32 {
    guard let context = try? WorktreeContext.resolve(path: workingDirectory) else {
        // Not a repository, or an unreadable one: nothing to record, and
        // nothing to fail — the transaction happened regardless.
        return 0
    }
    let outcome = ReferenceTransaction.runHook(
        stateArgument: state,
        environment: environment,
        in: context,
        readStandardInput: { standardInput },
        onRecord: { metadata in
            guard let watchStore else { return }
            try? WatchObservedBridge.broadcast(metadata, store: watchStore)
        })
    // `runHook` catches every persistence throw and carries the failure as
    // `recordingFailure`; its exit code is 0 by construction.
    return outcome.exitCode
}
