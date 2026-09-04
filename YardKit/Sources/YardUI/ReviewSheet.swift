// ReviewSheet.swift — the human's review surface (#0055, rounds 2–3)
//
// Three types, kept on the #0216 TransportStatus pattern: the model is
// VALUE-DRIVEN — the app target feeds it (pending registrations from the
// `PendingReviewStore` event hook, the resolved diff from the app-side
// serving body) and no test or preview ever touches the XPC layer. The
// centre owns lifecycle and tab routing; the view is a pure function of the
// model. All behaviour lives here in YardUI (guide §11 decision 10); the
// app target only constructs and injects.
//
// Round 3 adds amend's application (the edited patch goes to the index
// through the engine's staging path before the reply resolves, with a typed
// failure to the sheet when it cannot) and the per-line picker (the hunk
// body's own new-side lines, feeding `ReviewComment.line`).
//
// The diff renders through #0082's `FileDiffView` — the same component the
// Detail pane uses; nothing here is a second diff renderer. Per-hunk comment
// affordances and amend's patch capture are composed on the MODEL, so the
// whole exchange (decision, message, comments, edited patch) is assertable
// without rendering anything.

import SwiftUI
import YardGit
import YardKit

/// Everything one pending review's sheet renders, and the decision the human
/// is composing. One instance per pending review; `pendingID` is the store's
/// handle the reply resolves through.
///
/// States the sheet reflects, all settable/driveable without AppKit:
/// - **pending** — `outcome == nil`, `files` resolved (or loading), decision
///   buttons enabled;
/// - **decided** — the centre removes the model, which dismisses the sheet;
/// - **timedOut / superseded** — the store reported a typed outcome, the
///   banner names it, and the decision buttons disable.
@Observable
public final class ReviewSheetModel: Identifiable {

    /// The pending store's id this sheet resolves through.
    public let pendingID: UUID

    /// The repository's common dir — the tab identity the sheet belongs to.
    public let commonDir: String

    /// What the agent asked to have reviewed.
    public let selector: ReviewSelector

    /// How long the agent waits before its typed timeout fires.
    public let timeoutSeconds: Int

    public var id: UUID { pendingID }

    /// The tab the review was routed to (`ReviewCenter.routeToTab`), or nil
    /// before routing ran. The seam the app's per-window tab binding presents
    /// the sheet through.
    public internal(set) var tabID: UUID?

    /// The working directory the review request came from — a path inside the
    /// repository, which may be deeper than the root the tab shows. Set by
    /// `attachDiff` once the app-side body resolved the request.
    public private(set) var originPath: String?

    /// The resolved diff. nil while loading; [] for a genuinely empty diff.
    public private(set) var files: [FileDiff]?

    /// Set when the engine could not compute the diff — distinct from an
    /// empty diff, which is a legitimate review surface.
    public private(set) var diffError: String?

    /// The free text the human typed alongside the decision (optional).
    public var message: String

    /// Per-hunk and per-line comments composed so far.
    public private(set) var comments: [ReviewComment] = []

    /// Amend's capture surface: the patch text the human can edit, seeded
    /// from the resolved diff. Round 3 applies it: sending amend writes this
    /// text to the index through the engine's staging path (`stagePatch`)
    /// BEFORE the reply resolves, so the amended index is the reviewed state
    /// the reply refers to; the reply still carries the text for the agent's
    /// record.
    public var editedPatch: String

    /// Amend's typed apply failure, or nil. Set when the apply path threw —
    /// a stale patch the index no longer matches, for example — and cleared
    /// by a successful apply or `clearApplyError()`. A failed apply never
    /// resolves the pending: the human sees this, edits the patch and sends
    /// again, or cancels back to the three decisions.
    public private(set) var applyError: String?

    /// The store's typed outcome once the pending resolved — nil while the
    /// human still decides. `.decided` never lands here for display: the
    /// centre dismisses decided sheets instead.
    public private(set) var outcome: ReviewOutcome?

    /// The store resolution the decision buttons drive. Returns whether the
    /// pending was still there to receive it. The centre wires this to
    /// `PendingReviewStore.resolve(id:decision:)`; a test can wire a double
    /// or a real store.
    @ObservationIgnored public var onDecide: ((ReviewReply) -> Bool)?

    /// Amend's application path: applies the edited patch to the index at
    /// the review's repository. The centre wires the engine's staging path
    /// (`YardGit.stagePatch` at the request's resolved origin); a test wires
    /// the same seam with a fixture repository or a double. nil means amend
    /// with a non-empty patch is refused with a typed `applyError` — never a
    /// silent success and never an unwired no-op.
    @ObservationIgnored public var onApplyPatch: ((String) throws -> Void)?

    /// The banner's Close action, set by the centre (its `dismiss`).
    @ObservationIgnored public var onClose: (() -> Void)?

    public init(pending: PendingReviewStore.Pending) {
        self.pendingID = pending.id
        self.commonDir = pending.request.commonDir
        self.selector = pending.request.selector
        self.timeoutSeconds = pending.request.timeoutSeconds
        self.message = ""
        self.editedPatch = ""
    }

    /// "Staged changes" for `--staged`, the range string otherwise.
    public var selectorLabel: String {
        switch selector {
        case .staged: "Staged changes"
        case .range(let range): range
        }
    }

    /// The decision buttons' enabled state: any typed outcome ends the
    /// review — a decided/timed-out/superseded sheet must not compose a
    /// second reply.
    public var decisionsEnabled: Bool { outcome == nil }

    /// What the banner says for the current outcome, or nil while pending
    /// (and for `.decided`, which dismisses the sheet rather than bannering).
    public var outcomeLabel: String? {
        switch outcome {
        case .timedOut:
            "This review timed out before a decision was made."
        case .superseded:
            "This review was superseded by a newer request for the same repository."
        case .decided, nil:
            nil
        }
    }

    // MARK: - Driven by the app-side bridge

    /// Attaches the resolved diff (or its error) and the request's origin.
    /// Seeds amend's patch editor from the diff; a seed never overwrites
    /// text the human already edited.
    public func attachDiff(originPath: String, files: [FileDiff], errorMessage: String?) {
        self.originPath = originPath
        if let errorMessage {
            diffError = errorMessage
        } else {
            self.files = files
            diffError = nil
            if editedPatch.isEmpty {
                editedPatch = Self.seedPatch(from: files)
            }
        }
    }

    /// The store's outcome, reflected by the sheet (banner, disabled
    /// buttons) — or dismissal, which the centre performs for `.decided`.
    public func recordOutcome(_ outcome: ReviewOutcome) {
        self.outcome = outcome
    }

    /// True when `path` — the path a window's content shows — belongs to
    /// this sheet's repository: the request's resolved origin (either path
    /// may be a subdirectory of the other) or the common dir itself.
    public func repositoryContains(path: String) -> Bool {
        if path == commonDir { return true }
        guard let origin = originPath else { return false }
        return path == origin
            || path.hasPrefix(origin + "/")
            || origin.hasPrefix(path + "/")
    }

    // MARK: - The composed decision

    /// Adds a comment attached to `hunkID` of `path`, optionally to one file
    /// line. Empty text is refused — a comment that carries nothing is noise
    /// on the wire, not data.
    public func addComment(path: String, hunkID: String, line: Int? = nil, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        comments.append(ReviewComment(path: path, hunkID: hunkID, line: line, text: trimmed))
    }

    /// Removes one composed comment (the comment list's ✕ affordance).
    public func removeComment(_ comment: ReviewComment) {
        comments.removeAll { $0 == comment }
    }

    /// The `ReviewReply` the decision buttons send: the message only when
    /// typed, the composed comments, and the patch text only for `amend` —
    /// an approve or reject must never carry a patch the decision does not
    /// answer for.
    public func composedReply(for decision: ReviewDecision) -> ReviewReply {
        ReviewReply(
            decision: decision,
            message: message.isEmpty ? nil : message,
            comments: comments,
            editedPatch: decision == .amend && !editedPatch.isEmpty ? editedPatch : nil)
    }

    /// Sends the decision through `onDecide`. A sheet with a typed outcome
    /// (or nothing wired to resolve through) refuses: the pending is no
    /// longer there to answer.
    ///
    /// Amend's application contract (#0055 round 3): the edited patch is
    /// written to the index BEFORE the reply resolves — apply-then-resolve,
    /// so a reply that leaves always refers to an index that was actually
    /// amended. An empty patch is nothing to apply and resolves without an
    /// apply call. A failed apply (a stale patch) is a typed outcome to the
    /// sheet — `applyError`, the human retries with a corrected patch or
    /// cancels back to the three decisions — never a crash, never a
    /// resolution, never a silent success.
    @discardableResult
    public func decide(_ decision: ReviewDecision) -> Bool {
        guard decisionsEnabled, let onDecide else { return false }
        if decision == .amend && !editedPatch.isEmpty {
            guard let onApplyPatch else {
                applyError = "no apply path is wired for this sheet"
                return false
            }
            do {
                try onApplyPatch(editedPatch)
                applyError = nil
            } catch {
                applyError = String(describing: error)
                return false
            }
        }
        return onDecide(composedReply(for: decision))
    }

    /// Clears amend's typed apply failure — the Cancel affordance: a stale
    /// patch the human chose not to retry must not resurface the next time
    /// Amend… is selected.
    public func clearApplyError() {
        applyError = nil
    }

    /// The banner's Close: the centre owns removal, the model only forwards.
    public func close() {
        onClose?()
    }

    // MARK: - Per-line comment affordance (#0055 round 3)

    /// One pickable line inside a hunk: its number on the NEW side of the
    /// diff, and the label the picker shows.
    public struct LineChoice: Identifiable, Equatable, Sendable {
        public let number: Int
        public let label: String

        public var id: Int { number }
    }

    /// The hunk body's pickable lines: context and added lines, numbered
    /// from `newStart` (a context line and an added line each occupy one
    /// new-side line; a deleted line occupies none and is not offered). This
    /// is what the sheet's per-line picker offers, so a per-line comment
    /// attaches to a real line of the diff — never a free-typed number that
    /// may not exist. Round 2's wire field (`ReviewComment.line`) is
    /// unchanged; this is the UI affordance feeding it.
    public static func lineChoices(for hunk: Hunk) -> [LineChoice] {
        var choices: [LineChoice] = []
        var newLine = hunk.newStart
        for body in hunk.body {
            guard let marker = body.first else { continue }
            switch marker {
            case " ", "+":
                choices.append(
                    LineChoice(number: newLine, label: "\(newLine)  \(body.dropFirst())"))
                newLine += 1
            default:
                // "-" occupies no new-side line; "\" marks a "\ No newline"
                // marker; anything else is not a diff body line.
                continue
            }
        }
        return choices
    }

    /// Amend's seed text: each file's header block followed by its hunks'
    /// patch text — byte-for-byte what `git apply` would accept, which is
    /// what round 3's application path needs the capture surface to hold.
    private static func seedPatch(from files: [FileDiff]) -> String {
        files.map { file in
            file.headerText + file.hunks.map(\.patchText).joined()
        }.joined()
    }
}

/// Why the centre could not even attempt amend's application (#0055 round
/// 3) — distinct from git's own apply failure, which the engine's
/// `stagePatch` throws and the model records verbatim.
public enum ReviewApplyError: Error, CustomStringConvertible, Sendable {
    /// The request's repository has not been resolved yet, so there is no
    /// working directory to apply the patch at.
    case originUnresolved

    public var description: String {
        switch self {
        case .originUnresolved:
            "the review's repository has not been resolved yet — the diff "
                + "has not arrived, so there is nothing to apply the patch at"
        }
    }
}

/// The lifecycle owner of the review sheets (#0055): one sheet per pending
/// review, created from the pending store's own event hook, dismissed when
/// the store resolves it, and routed to the repository's tab through #0084's
/// focus-or-open rule. A review pending on one tab never blocks another —
/// the sheets are per-repository state, and each window presents only the
/// sheet whose repository it shows.
///
/// The store's hook fires on XPC's queues; everything here lands on the main
/// actor through a `Task`, so the sheets are observed and mutated on one
/// actor only.
@Observable
public final class ReviewCenter {

    /// The live sheets, in registration order. Decided sheets are removed
    /// (the sheet dismisses); timed-out and superseded sheets stay until the
    /// human closes their banner, so the outcome is never a silent vanish.
    public private(set) var sheets: [ReviewSheetModel] = []

    /// A diff that arrived before its registration event — keyed by
    /// commonDir, applied the moment the sheet exists. The serving body
    /// computes the diff before registering, so this is normally consumed
    /// immediately; the stash only makes the two arrivals order-independent.
    private var stashedDiffs: [String: (originPath: String, files: [FileDiff], errorMessage: String?)] = [:]

    private let store: PendingReviewStore

    /// - Parameter store: the app's pending-review store. The centre wires
    ///   itself as the store's change observer for its lifetime; resolutions
    ///   the sheets compose go through the same store.
    public init(store: PendingReviewStore) {
        self.store = store
        store.onPendingChange = { [weak self] pending, outcome in
            Task { @MainActor in
                self?.storeDidChange(pending: pending, outcome: outcome)
            }
        }
    }

    /// The sheet for a pending id, if it is still live.
    public func sheet(withID id: UUID) -> ReviewSheetModel? {
        sheets.first { $0.pendingID == id }
    }

    /// The still-pending sheet routed to a tab — the per-tab binding the
    /// app's window content presents once windows carry tab chrome.
    public func activeSheet(forTabID id: UUID) -> ReviewSheetModel? {
        sheets.first { $0.outcome == nil && $0.tabID == id }
    }

    /// The still-pending sheet whose repository contains `path` — the
    /// binding the app's content view presents while it shows that
    /// repository by path. Matched against the request's resolved origin
    /// (either may be a subdirectory of the other) and the common dir.
    public func activeSheet(forRepositoryPath path: String) -> ReviewSheetModel? {
        sheets.first { $0.outcome == nil && $0.repositoryContains(path: path) }
    }

    /// Drops a sheet — the banner's Close, or a decided sheet's dismissal.
    public func dismiss(_ model: ReviewSheetModel) {
        sheets.removeAll { $0.pendingID == model.pendingID }
    }

    /// #0084's focus-or-open for a review's repository: an already-open
    /// repository has its tab selected; an unopened one is opened into the
    /// frontmost window. The routed tab's id is recorded on the sheet so the
    /// per-tab presentation can bind on tab identity alone.
    @discardableResult
    public func routeToTab(
        for context: WorktreeContext,
        tabs: RepositoryTabs = .shared,
        windowStore: WindowStore = .shared
    ) -> RepositoryTabs.Outcome {
        let outcome: RepositoryTabs.Outcome
        if let existing = tabs.tabs.first(where: { $0.context.commonDir == context.commonDir }) {
            tabs.selectedTabID = existing.id
            outcome = .focusedExisting(tab: existing, selectedWorktreeName: existing.selectedWorktreeName)
        } else {
            outcome = tabs.openInFrontmostWindow(
                path: context.topLevel ?? context.commonDir,
                windowStore: windowStore)
        }
        if let model = sheets.last(where: { $0.commonDir == context.commonDir && $0.outcome == nil }) {
            switch outcome {
            case .opened(let tab), .focusedExisting(let tab, _):
                model.tabID = tab.id
            case .refused:
                break
            }
        }
        return outcome
    }

    /// Attaches the app-side body's resolved diff to the still-pending sheet
    /// for `commonDir` (a newer request for the same repository wins), or
    /// stashes it until that sheet registers.
    public func attachDiff(
        commonDir: String,
        originPath: String,
        files: [FileDiff],
        errorMessage: String?
    ) {
        guard let model = sheets.last(where: { $0.commonDir == commonDir && $0.outcome == nil }) else {
            stashedDiffs[commonDir] = (originPath, files, errorMessage)
            return
        }
        model.attachDiff(originPath: originPath, files: files, errorMessage: errorMessage)
    }

    private func storeDidChange(pending: PendingReviewStore.Pending, outcome: ReviewOutcome?) {
        if let outcome {
            guard let model = sheet(withID: pending.id) else { return }
            model.recordOutcome(outcome)
            if case .decided = outcome {
                dismiss(model)
            }
        } else if sheet(withID: pending.id) == nil {
            let model = ReviewSheetModel(pending: pending)
            model.onDecide = { [weak self] reply in
                guard let self else { return false }
                return self.store.resolve(id: model.pendingID, decision: reply)
            }
            model.onApplyPatch = { [weak model] patch in
                guard let origin = model?.originPath else {
                    throw ReviewApplyError.originUnresolved
                }
                // The engine's staging path (#0055 round 3): the same
                // `git apply --cached` + journal checkpoint `stageHunks`
                // uses — never a second apply implementation. The origin is
                // the request's resolved worktree root, which is the root
                // the diff's paths are relative to.
                try stagePatch(patch, at: origin)
            }
            model.onClose = { [weak self, weak model] in
                guard let self, let model else { return }
                self.dismiss(model)
            }
            if let stash = stashedDiffs.removeValue(forKey: pending.request.commonDir) {
                model.attachDiff(
                    originPath: stash.originPath,
                    files: stash.files,
                    errorMessage: stash.errorMessage)
            }
            sheets.append(model)
        }
    }
}

/// The review sheet itself: the diff (through #0082's `FileDiffView`), the
/// per-hunk comment affordances, the optional message, amend's patch editor,
/// and the three decision buttons. Semantic colours only — everything adapts
/// to light and dark without a single literal colour.
public struct ReviewSheet: View {

    private let model: ReviewSheetModel

    /// Amend is a two-step decision: selecting it reveals the patch editor
    /// and swaps the buttons for send/cancel. Pure view state.
    @State private var amendSelected = false

    /// Per-hunk comment drafts, keyed by hunk id; cleared on add.
    @State private var commentDrafts: [String: String] = [:]

    /// The per-line picker's selection, keyed by hunk id: the picked
    /// new-side line number, or nil (absent) for a whole-hunk comment.
    @State private var commentLineSelections: [String: Int?] = [:]

    public init(model: ReviewSheetModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let outcomeLabel = model.outcomeLabel {
                banner(outcomeLabel)
                Divider()
            }
            ScrollView {
                diffContent
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            composer
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review — \(model.selectorLabel)")
                .font(.headline)
            Text(model.originPath ?? model.commonDir)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func banner(_ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(label)
                .font(.callout)
            Spacer()
            Button("Close") { model.close() }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var diffContent: some View {
        if let diffError = model.diffError {
            Text("Couldn't load diff: \(diffError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let files = model.files {
            if files.isEmpty {
                Text("Nothing to review — this diff is empty.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(files, id: \.path) { file in
                        fileSection(file: file)
                    }
                }
            }
        } else {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func fileSection(file: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FileDiffView(file: file)
            ForEach(file.hunks, id: \.id) { hunk in
                commentAffordance(path: file.path, hunk: hunk)
            }
            commentSection(path: file.path)
        }
    }

    /// The per-hunk comment affordance: a disclosure per hunk with a text
    /// field and a per-LINE picker — the hunk body's own new-side lines
    /// (`ReviewSheetModel.lineChoices`), "Whole hunk" when no line is
    /// picked. The comment attaches to the hunk's stable content-derived id
    /// and the picked line, so it survives the re-listing round 3's
    /// application path will do.
    private func commentAffordance(path: String, hunk: Hunk) -> some View {
        DisclosureGroup("Comment on \(hunk.header)") {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "Comment",
                    text: Binding(
                        get: { commentDrafts[hunk.id] ?? "" },
                        set: { commentDrafts[hunk.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Picker(
                    "Line (optional)",
                    selection: Binding(
                        get: { commentLineSelections[hunk.id] ?? nil },
                        set: { commentLineSelections[hunk.id] = $0 })
                ) {
                    Text("Whole hunk").tag(Int?.none)
                    ForEach(ReviewSheetModel.lineChoices(for: hunk)) { choice in
                        Text(choice.label).tag(Int?.some(choice.number))
                    }
                }
                .pickerStyle(.menu)
                Button("Add comment") {
                    model.addComment(
                        path: path,
                        hunkID: hunk.id,
                        line: commentLineSelections[hunk.id] ?? nil,
                        text: commentDrafts[hunk.id] ?? "")
                    commentDrafts[hunk.id] = nil
                    commentLineSelections[hunk.id] = nil
                }
                .disabled(!model.decisionsEnabled)
            }
            .padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func commentSection(path: String) -> some View {
        let fileComments = model.comments.filter { $0.path == path }
        if !fileComments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(fileComments.enumerated()), id: \.offset) { _, comment in
                    HStack(spacing: 6) {
                        Button {
                            model.removeComment(comment)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Text(commentLabel(comment))
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func commentLabel(_ comment: ReviewComment) -> String {
        let where_ = comment.line.map { "\(comment.hunkID) line \($0)" } ?? comment.hunkID
        return "\(comment.path) @ \(where_): \(comment.text)"
    }

    private var composer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Message (optional)", text: $model.message)
                .textFieldStyle(.roundedBorder)
            if amendSelected {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edited patch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.editedPatch)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .border(.quaternary)
                    if let applyError = model.applyError {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The edited patch could not be applied to the index: \(applyError)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Edit the patch and send again, or Cancel to choose a different decision.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                if amendSelected {
                    Button("Cancel") {
                        model.clearApplyError()
                        amendSelected = false
                    }
                    Button("Send amend") {
                        model.decide(.amend)
                        amendSelected = false
                    }
                    .disabled(!model.decisionsEnabled)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Reject") { model.decide(.reject) }
                        .disabled(!model.decisionsEnabled)
                    Button("Approve") { model.decide(.approve) }
                        .disabled(!model.decisionsEnabled)
                        .keyboardShortcut(.defaultAction)
                    Button("Amend…") { amendSelected = true }
                        .disabled(!model.decisionsEnabled)
                }
            }
        }
        .padding()
    }
}
