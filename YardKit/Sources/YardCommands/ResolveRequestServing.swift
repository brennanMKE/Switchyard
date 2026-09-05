// ResolveRequestServing.swift — the app-side body of `AppServiceProtocol
// .performResolve` (#0057)

import Foundation
import os
import YardGit
import YardKit

/// One conflicted path as round 2's resolution card renders it: the #0017
/// conflict record plus the decoded text of every stage that exists, plus the
/// working file's current text — the editor's seed.
///
/// The texts are decoded lossily as UTF-8 and are NEVER interpreted (the
/// design's untrusted-content rule): ours/base/theirs render as text with
/// conflict markers visible, the seed is plain text. A binary blob decodes to
/// lossy mojibake rather than failing the whole request — the human sees what
/// is there and can still pick a side, which is better than a sheet that
/// cannot open.
public struct ResolveConflictDetail: Sendable, Equatable {

    /// The conflicted path's own record — porcelain kind and stage oids.
    public let file: ConflictedFile

    /// Stage 1's decoded text — the merge base. Nil when the side has no
    /// entry (add/add has no base).
    public let baseText: String?

    /// Stage 2's decoded text — ours. Nil when that side has no entry.
    public let oursText: String?

    /// Stage 3's decoded text — theirs. Nil when that side has no entry.
    public let theirsText: String?

    /// The working file's current text — what git left after the conflict,
    /// conflict markers and all for a content conflict, the surviving side
    /// for delete/modify. This is what the "Edit merged" editor is seeded
    /// with. Nil when the working file does not exist.
    public let workingText: String?

    public init(
        file: ConflictedFile,
        baseText: String?,
        oursText: String?,
        theirsText: String?,
        workingText: String?
    ) {
        self.file = file
        self.baseText = baseText
        self.oursText = oursText
        self.theirsText = theirsText
        self.workingText = workingText
    }
}

/// The app-side body of `AppServiceProtocol.performResolve` (#0057) — the
/// single function the app's `AppService` forwards to, kept here (linked by
/// the app alone, like every engine-backed arm) so `swift test` exercises the
/// exact body the wire serves rather than a copy that could drift from it.
///
/// The body resolves the repository (one `WorktreeContext.resolve`, the same
/// piece of engine work `runReviewRequest` does), enumerates the conflicted
/// paths (`conflictedFiles`), reads each path's stage blobs' contents, and
/// hands the resolved request, the context, and the per-path details to
/// `onPending` so the app target's bridge (round 2) can attach them to the
/// pane model and route the resolve to the repository's tab (#0084
/// focus-or-open). Registration and blocking stay with `ResolveServing` and
/// the pending store.
///
/// Nothing here WRITES to the repository — not on registration, not on
/// cancellation, not ever. Staging happens engine-side
/// (`ResolveApply.apply`) on the human's per-card action, which round 2's
/// pane drives; the design's partial-staging rule ("nothing is staged until
/// the human presses the button on that card") is this body's invariant:
/// cancelling must leave the conflicted state exactly as it arrived.
///
/// The CLI cannot resolve the repository itself (it does not link the
/// engine), so it sends `ResolveRequest.commonDir` empty and its working
/// directory as the protocol method's own parameter. This body fills the
/// resolved common dir in before the request is registered. When the working
/// directory does not resolve to a repository, nothing is registered and the
/// failure envelope is returned — repository-level failures are never
/// encoded as resolve outcomes, because "there was no repository" is not an
/// answer to "what did the human say".
public func runResolveRequest(
    requestData: Data,
    workingDirectory: String,
    store: PendingResolveStore,
    onPending: (@Sendable (ResolveRequest, WorktreeContext, [ResolveConflictDetail], String?) -> Void)? = nil
) async -> Data {
    let context = try? await WorktreeContext.resolve(path: workingDirectory)
    guard let context else {
        return await ResolveServing.handle(
            requestData: requestData,
            commonDir: nil,
            store: store)
    }

    // The conflict list is computed BEFORE registration, from the request's
    // own pathspec scope — the pane's capture of what the agent asked to
    // have resolved. A failure is delivered as an error message rather than
    // an empty list: the two must not read the same ("nothing conflicted"
    // vs "the conflicts could not be enumerated").
    if let request = try? JSONDecoder().decode(ResolveRequest.self, from: requestData) {
        var registered = request
        registered.commonDir = context.commonDir
        var details: [ResolveConflictDetail] = []
        var enumerateError: String?
        do {
            details = try resolveConflictDetails(for: registered, in: context)
        } catch {
            enumerateError = String(describing: error)
        }
        onPending?(registered, context, details, enumerateError)
    }

    return await ResolveServing.handle(
        requestData: requestData,
        commonDir: context.commonDir,
        store: store)
}

/// The unified-logging category the app-side resolve flow logs under. Same
/// subsystem as the app's other loggers (`ServiceNames.logSubsystem`).
private let resolveLogger = Logger(
    subsystem: ServiceNames.logSubsystem, category: "resolve")

/// The per-path details a resolve request's scope covers: the conflicted
/// paths under the request's pathspec (every conflicted path when the
/// pathspec is absent — see `ResolveRequest.matches(path:)`), each carrying
/// its stage blobs' decoded texts and the working file's current text.
///
/// A stage whose blob cannot be read degrades to nil for THAT stage rather
/// than failing the enumeration: the card still renders the sides that did
/// read, and a half-readable conflict is more useful to a human than a
/// sheet that refuses to open.
func resolveConflictDetails(
    for request: ResolveRequest,
    in context: WorktreeContext,
    git: GitProcess = GitProcess()
) throws -> [ResolveConflictDetail] {
    let top = context.topLevel ?? context.commonDir
    let files = try conflictedFiles(at: top, git: git)

    return files.filter { request.matches(path: $0.path) }.map { file in
        func stageText(_ stage: ConflictedFile.StageEntry?) -> String? {
            guard let stage else { return nil }
            guard let data = try? ResolveApply.readBlob(oid: stage.oid, at: top, git: git) else {
                resolveLogger.warning(
                    "stage blob \(stage.oid, privacy: .public) for \(file.path, privacy: .public) could not be read")
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }

        let workingURL = URL(fileURLWithPath: top).appendingPathComponent(file.path)
        let workingText = (try? Data(contentsOf: workingURL))
            .map { String(decoding: $0, as: UTF8.self) }

        return ResolveConflictDetail(
            file: file,
            baseText: stageText(file.base),
            oursText: stageText(file.ours),
            theirsText: stageText(file.theirs),
            workingText: workingText)
    }
}
