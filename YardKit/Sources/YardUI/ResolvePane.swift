// ResolvePane.swift — the resolution surface for a repository's conflicts
// (#0057 round 2)
//
// The #0055 ReviewSheet pattern: the model is VALUE-DRIVEN — the app target
// feeds it (pending registrations from the `PendingResolveStore` event hook,
// the per-path conflict details from the app-side serving body) and no test
// or preview ever touches the XPC layer. The centre owns lifecycle and tab
// routing (#0084); the view is a pure function of the models. All behaviour
// lives here in YardUI (guide §11 decision 10); the app target only
// constructs and injects.
//
// The design's per-path vocabulary (#0057, signed off 2026-09-03):
//
// | kind            | choices                                             |
// |-----------------|-----------------------------------------------------|
// | content (UU)    | Use ours · Use theirs · Edit merged (seed = the     |
// |                 | working file's conflict-marked text)                |
// | add/add (AA)    | Use ours · Use theirs · Edit merged (seeded with    |
// |                 | ours' content)                                      |
// | delete/modify   | Keep the deletion · Keep the modification · Edit    |
// | (DU/UD)         | merged (seeded with the surviving side)             |
// | rename (AU/UA)  | Take ours' path+content / Take theirs' — one per    |
// |                 | record, the side whose stage the record carries     |
// | DD              | read-only with an explanation (the design table has |
// |                 | no choice for a both-deleted record; its resolution |
// |                 | is the rename group's per-record cards)             |
//
// Staging is per card, on the human's press only: the pane's `stage` runs
// the engine apply through the injected `onApply` seam and marks the card
// staged — nothing else ever stages. Partial staging is legitimate: some
// cards staged, others still open. Submit ends the blocking request with
// every path's resolution (staged or not — the reply is the record);
// Cancel stages nothing and returns `.cancelled`.
//
// Untrusted content rule: ours/base/theirs render as plain text lines
// through #0082's `FileDiffView` (context lines carry the text verbatim, so
// conflict markers stay visible); nothing is ever interpreted.

import SwiftUI
import YardGit
import YardKit

/// One conflicted path's detail as the serving body delivers it — the
/// YardUI-side value a card renders from. The texts are the stage blobs'
/// decoded UTF-8 and the working file's text, carried verbatim.
public struct ResolveCardData: Sendable, Equatable {

    /// The conflicted path, repository-relative.
    public let path: String

    /// The porcelain XY pair (#0017).
    public let kind: ConflictKind

    /// Stage 1's text — the merge base. Nil when that side has no entry.
    public let baseText: String?

    /// Stage 2's text — ours. Nil when that side has no entry.
    public let oursText: String?

    /// Stage 3's text — theirs. Nil when that side has no entry.
    public let theirsText: String?

    /// The working file's current text — the editor's seed. Nil when the
    /// working file does not exist.
    public let workingText: String?

    public init(
        path: String,
        kind: ConflictKind,
        baseText: String? = nil,
        oursText: String? = nil,
        theirsText: String? = nil,
        workingText: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.baseText = baseText
        self.oursText = oursText
        self.theirsText = theirsText
        self.workingText = workingText
    }
}

/// Which card a porcelain kind presents. `readOnly` carries the explanation
/// the card shows instead of choices — a kind the engine cannot resolve is
/// never given a fake choice (the design table's rule).
public enum ResolveCardKind: Sendable, Equatable {
    case content
    case addAdd
    case deleteModify
    case rename
    case readOnly(explanation: String)

    /// The card kind a porcelain kind renders. UU is a content conflict, AA
    /// add/add, DU/UD delete/modify, AU/UA the per-record rename cards
    /// (#0057 round 1's finding: a rename group surfaces as DD at the old
    /// path plus AU at ours' new path and UA at theirs'), and DD — both
    /// deleted — is presented read-only.
    public static func kind(for porcelain: ConflictKind) -> ResolveCardKind {
        switch porcelain {
        case .bothModified: .content
        case .bothAdded: .addAdd
        case .deletedByUs, .deletedByThem: .deleteModify
        case .addedByUs, .addedByThem: .rename
        case .bothDeleted:
            .readOnly(explanation: "Both sides deleted this path. It resolves "
                + "with its rename group's records — take one side's rename "
                + "and this path records as deleted with it.")
        }
    }

    /// The card's headline label.
    public var label: String {
        switch self {
        case .content: "Content conflict"
        case .addAdd: "Add/add conflict"
        case .deleteModify: "Delete/modify conflict"
        case .rename: "Rename conflict"
        case .readOnly: "Not resolvable by this pane"
        }
    }
}

/// One side of a card's ours/base/theirs rendering: a label and the blob's
/// verbatim text. The view wraps each in #0082's `FileDiffView`; nothing
/// interprets the text.
public struct ResolveSide: Identifiable, Sendable, Equatable {
    public let label: String
    public let text: String

    public var id: String { label }

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

/// One conflicted path's card: its side texts, the composed choice, the
/// editor seed, the note, and the staged state. One instance per conflicted
/// path, owned by the pane model.
@Observable
public final class ResolveCardModel: Identifiable {

    /// The path's detail as delivered.
    public let data: ResolveCardData

    /// Which card this porcelain kind presents.
    public let kind: ResolveCardKind

    /// The choices this card offers, in design-table order. Empty for a
    /// read-only card — no choice is offered, ever.
    public let choices: [PathChoice]

    /// The composed choice; defaults to the card's first choice. Nil only on
    /// a read-only card.
    public var selectedChoice: PathChoice?

    /// The merged editor's text, seeded per the design (the working file's
    /// conflict-marked content for a content conflict, ours' content for
    /// add/add, the surviving side for delete/modify). What the human saves
    /// is what stages for the `editedContent` choice.
    public var editorText: String

    /// The optional free-text note to the agent, per path.
    public var note: String

    /// Set by the pane's `stage` after the engine apply succeeded. Staging
    /// one card never touches another.
    public private(set) var staged = false

    /// The engine apply's typed failure, or nil. A failed stage never
    /// resolves the pending: the human sees this, changes the composition and
    /// stages again, or cancels — never a silent success.
    public private(set) var stageError: String?

    public var id: String { data.path }

    /// Constructs one card from its detail, seeded per the design table.
    public init(data: ResolveCardData) {
        self.data = data
        self.kind = ResolveCardKind.kind(for: data.kind)
        switch self.kind {
        case .content, .addAdd:
            choices = [.useOurs, .useTheirs, .editedContent]
        case .deleteModify:
            choices = [.keepDeletion, .keepModification, .editedContent]
        case .rename:
            // A rename record carries exactly one side's stage (#0057 round
            // 1): AU is ours' new path, UA theirs'. The side without a stage
            // is not offered — a choice the engine must refuse is a fake
            // choice.
            choices = data.oursText != nil ? [.renameTakeOurs] : [.renameTakeTheirs]
        case .readOnly:
            choices = []
        }
        selectedChoice = choices.first
        switch self.kind {
        case .content:
            editorText = data.workingText ?? data.oursText ?? ""
        case .addAdd:
            editorText = data.oursText ?? ""
        case .deleteModify:
            editorText = data.workingText ?? data.oursText ?? data.theirsText ?? ""
        case .rename, .readOnly:
            editorText = ""
        }
        note = ""
    }

    /// The side-by-side columns this card renders, ours first: every stage
    /// that has a text, with its design-table label.
    public var sides: [ResolveSide] {
        var result: [ResolveSide] = []
        if let ours = data.oursText { result.append(ResolveSide(label: "Ours", text: ours)) }
        if let base = data.baseText { result.append(ResolveSide(label: "Base", text: base)) }
        if let theirs = data.theirsText {
            result.append(ResolveSide(label: "Theirs", text: theirs))
        }
        return result
    }

    /// The label a choice presents — the design table's vocabulary.
    public static func label(for choice: PathChoice) -> String {
        switch choice {
        case .useOurs: "Use ours"
        case .useTheirs: "Use theirs"
        case .editedContent: "Edit merged"
        case .keepDeletion: "Keep the deletion"
        case .keepModification: "Keep the modification"
        case .renameTakeOurs: "Take ours' path+content"
        case .renameTakeTheirs: "Take theirs' path+content"
        }
    }

    /// The composed resolution for this path, or nil when the card offers no
    /// choice (read-only) or nothing is selected. The edited content rides
    /// only for the `editedContent` choice; the note rides only when
    /// non-empty — absent means absent on the wire (#0129 Decision 4).
    public func resolution() -> PathResolution? {
        guard let choice = selectedChoice else { return nil }
        return PathResolution(
            path: data.path,
            kind: data.kind,
            choice: choice,
            editedContent: choice == .editedContent ? editorText : nil,
            note: note.isEmpty ? nil : note)
    }

    /// The stage affordance's error line, when the last apply refused.
    public func clearStageError() {
        stageError = nil
    }

    /// Records the engine apply's success — the pane's `stage` calls this
    /// after the seam returned; the card owns its staged state's writer.
    func recordStaged() {
        staged = true
        stageError = nil
    }

    /// Records the engine apply's refusal — the card shows it, and the human
    /// retries or cancels; the pending is never resolved by a failed apply.
    func recordStageFailure(_ message: String) {
        stageError = message
    }
}

/// Why the pane could not even attempt one card's apply — distinct from git's
/// own refusal, which the engine's `ResolveApply` throws and the card records
/// verbatim.
public enum ResolvePaneApplyError: Error, CustomStringConvertible, Sendable {
    /// The request's repository has not been resolved yet, so there is no
    /// working directory to apply at.
    case originUnresolved

    /// No apply path is wired — the app target did not inject the engine
    /// apply, or the pane outlived its centre.
    case applyUnwired

    public var description: String {
        switch self {
        case .originUnresolved:
            "the resolve's repository has not been resolved yet — the "
                + "conflict details have not arrived, so there is nothing to apply at"
        case .applyUnwired:
            "no apply path is wired for this pane"
        }
    }
}

/// Everything one pending resolve's pane renders, and the resolutions the
/// human is composing. One instance per pending resolve; `pendingID` is the
/// store's handle the reply resolves through.
///
/// States the pane reflects, all settable/driveable without AppKit:
/// - **pending** — `outcome == nil`, details attached (or loading), submit
///   and cancel enabled;
/// - **decided** — the centre removes the model, which dismisses the pane;
/// - **timedOut / superseded** — the store reported a typed outcome, the
///   banner names it, and the buttons disable.
@Observable
public final class ResolvePaneModel: Identifiable {

    /// The pending store's id this pane resolves through.
    public let pendingID: UUID

    /// The repository's common dir — the tab identity the pane belongs to.
    public let commonDir: String

    /// How long the agent waits before its typed timeout fires.
    public let timeoutSeconds: Int

    public var id: UUID { pendingID }

    /// The tab the resolve was routed to (`ResolveCenter.routeToTab`), or nil
    /// before routing ran. The seam the app's per-window tab binding presents
    /// the pane through.
    public internal(set) var tabID: UUID?

    /// The working directory the resolve request came from — a path inside
    /// the repository. Set by `attachDetails`.
    public private(set) var originPath: String?

    /// One card per conflicted path in the request's scope, in the serving
    /// body's order. Empty until details arrive.
    public private(set) var cards: [ResolveCardModel] = []

    /// Set when the engine could not enumerate the conflicts — distinct from
    /// an empty list, which is a legitimate "nothing to resolve" surface.
    public private(set) var detailsError: String?

    /// The store's typed outcome once the pending resolved — nil while the
    /// human still decides. `.decided` never lands here for display: the
    /// centre dismisses decided panes instead.
    public private(set) var outcome: ResolveOutcome?

    /// The store resolution the buttons drive. Returns whether the pending
    /// was still there to receive it. The centre wires this to
    /// `PendingResolveStore.resolve(id:answer:)`; a test can wire a double or
    /// a real store.
    @ObservationIgnored public var onDecide: ((ResolveReply) -> Bool)?

    /// One card's engine apply: writes the chosen content and stages the
    /// path. The centre wires the engine apply (`ResolveApply.apply` through
    /// the app target's mapping seam); a test wires the same seam with a
    /// fixture repository or a counter. NOTHING stages until a card's Stage
    /// button calls this — cancel never calls it.
    @ObservationIgnored public var onApply: ((PathResolution) throws -> Void)?

    /// The banner's Close action, set by the centre (its `dismiss`).
    @ObservationIgnored public var onClose: (() -> Void)?

    public init(pending: PendingResolveStore.Pending) {
        self.pendingID = pending.id
        self.commonDir = pending.request.commonDir
        self.timeoutSeconds = pending.request.timeoutSeconds
    }

    /// True when `path` — the path a window's content shows — belongs to
    /// this pane's repository: the request's resolved origin (either path
    /// may be a subdirectory of the other) or the common dir itself.
    public func repositoryContains(path: String) -> Bool {
        if path == commonDir { return true }
        guard let origin = originPath else { return false }
        return path == origin
            || path.hasPrefix(origin + "/")
            || origin.hasPrefix(path + "/")
    }

    // MARK: - Driven by the app-side bridge

    /// Attaches the per-path conflict details (or their error) and the
    /// request's origin, building one card per path in the delivery order.
    /// A failure attaches as `detailsError` and never as an empty card list —
    /// the two must not read the same.
    public func attachDetails(
        originPath: String,
        details: [ResolveCardData],
        errorMessage: String? = nil
    ) {
        self.originPath = originPath
        if let errorMessage {
            detailsError = errorMessage
            cards = []
        } else {
            cards = details.map { ResolveCardModel(data: $0) }
            detailsError = nil
        }
    }

    /// The store's outcome, reflected by the pane (banner, disabled buttons)
    /// — or dismissal, which the centre performs for `.decided`.
    public func recordOutcome(_ outcome: ResolveOutcome) {
        self.outcome = outcome
    }

    /// The buttons' enabled state: any typed outcome ends the resolve — a
    /// decided/timed-out/superseded pane must not compose a second reply.
    public var decisionsEnabled: Bool { outcome == nil }

    /// What the banner says for the current outcome, or nil while pending
    /// (and for `.decided`, which dismisses the pane rather than bannering).
    public var outcomeLabel: String? {
        switch outcome {
        case .timedOut:
            "This resolve timed out before a decision was made."
        case .superseded:
            "This resolve was superseded by a newer request for the same repository."
        case .decided, nil:
            nil
        }
    }

    // MARK: - The per-card action

    /// One card's Stage resolution: applies the card's composed resolution
    /// through `onApply` and marks the card staged. Only THIS card is
    /// touched — partial staging is the design's contract. An already-staged
    /// card returns true without re-applying (the engine would refuse: the
    /// path is no longer conflicted). A read-only card has nothing to stage.
    @discardableResult
    public func stage(_ card: ResolveCardModel) -> Bool {
        guard decisionsEnabled else { return false }
        guard !card.staged else { return true }
        guard let resolution = card.resolution() else {
            card.recordStageFailure("this card offers no stageable resolution")
            return false
        }
        guard let onApply else {
            card.recordStageFailure(ResolvePaneApplyError.applyUnwired.description)
            return false
        }
        do {
            try onApply(resolution)
            card.recordStaged()
            return true
        } catch {
            card.recordStageFailure(String(describing: error))
            return false
        }
    }

    // MARK: - The sheet-level actions

    /// The reply Submit sends: every path's resolution, in card order —
    /// staged cards and still-open cards alike, because the reply is the
    /// record of what the human composed, and the conflicts-remaining
    /// re-check (exit 8) is what reports any consequence of what did not
    /// stage. Read-only cards contribute nothing.
    public func composedReply() -> ResolveReply {
        .resolutions(cards.compactMap { $0.resolution() })
    }

    /// Sends the composed resolutions through `onDecide`, ending the blocking
    /// request. A pane with a typed outcome (or nothing wired) refuses.
    @discardableResult
    public func submit() -> Bool {
        guard decisionsEnabled, let onDecide else { return false }
        return onDecide(composedReply())
    }

    /// Cancels the sheet: stages nothing (the apply seam is never called),
    /// touches nothing, and answers `.cancelled` — the considered human
    /// decision the arm maps to exit 7. A pane with a typed outcome (or
    /// nothing wired) refuses.
    @discardableResult
    public func cancel() -> Bool {
        guard decisionsEnabled, let onDecide else { return false }
        return onDecide(.cancelled)
    }

    /// The banner's Close: the centre owns removal, the model only forwards.
    public func close() {
        onClose?()
    }
}

/// The lifecycle owner of the resolve panes (#0057): one pane per pending
/// resolve, created from the pending store's own event hook, dismissed when
/// the store resolves it, and routed to the repository's tab through #0084's
/// focus-or-open rule. A resolve pending on one tab never blocks another —
/// the panes are per-repository state, and each window presents only the
/// pane whose repository it shows.
///
/// The store's hook fires on XPC's queues; everything here lands on the main
/// actor through a `Task`, so the panes are observed and mutated on one
/// actor only.
@Observable
public final class ResolveCenter {

    /// The live panes, in registration order. Decided panes are removed (the
    /// pane dismisses); timed-out and superseded panes stay until the human
    /// closes their banner, so the outcome is never a silent vanish.
    public private(set) var panes: [ResolvePaneModel] = []

    /// Conflict details that arrived before their registration event — keyed
    /// by commonDir, applied the moment the pane exists. The serving body
    /// computes the details before registering, so this is normally consumed
    /// immediately; the stash only makes the two arrivals order-independent.
    private var stashedDetails: [String: (originPath: String, details: [ResolveCardData], errorMessage: String?)] = [:]

    /// One card's engine apply at a resolved origin: the app target wires
    /// this to the mapping seam (`PathResolution` → `ResolveResolution` →
    /// `ResolveApply.apply`, one checkpointed action per path). nil refuses
    /// a stage with a typed `ResolvePaneApplyError` — never a silent no-op.
    @ObservationIgnored public var applyResolution: ((String, PathResolution) throws -> Void)?

    private let store: PendingResolveStore

    /// - Parameter store: the app's pending-resolve store. The centre wires
    ///   itself as the store's change observer for its lifetime; resolutions
    ///   the panes compose go through the same store.
    public init(store: PendingResolveStore) {
        self.store = store
        store.onPendingChange = { [weak self] pending, outcome in
            Task { @MainActor in
                self?.storeDidChange(pending: pending, outcome: outcome)
            }
        }
    }

    /// The pane for a pending id, if it is still live.
    public func pane(withID id: UUID) -> ResolvePaneModel? {
        panes.first { $0.pendingID == id }
    }

    /// The still-pending pane routed to a tab — the per-tab binding the
    /// app's window content presents.
    public func activePane(forTabID id: UUID) -> ResolvePaneModel? {
        panes.first { $0.outcome == nil && $0.tabID == id }
    }

    /// The still-pending pane whose repository contains `path` — the binding
    /// the app's content view presents while it shows that repository by
    /// path. Matched against the request's resolved origin (either may be a
    /// subdirectory of the other) and the common dir.
    public func activePane(forRepositoryPath path: String) -> ResolvePaneModel? {
        panes.first { $0.outcome == nil && $0.repositoryContains(path: path) }
    }

    /// Drops a pane — the banner's Close, or a decided pane's dismissal.
    public func dismiss(_ model: ResolvePaneModel) {
        panes.removeAll { $0.pendingID == model.pendingID }
    }

    /// #0084's focus-or-open for a resolve's repository: an already-open
    /// repository has its tab selected; an unopened one is opened into the
    /// frontmost window. The routed tab's id is recorded on the pane so the
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
        if let model = panes.last(where: { $0.commonDir == context.commonDir && $0.outcome == nil }) {
            switch outcome {
            case .opened(let tab), .focusedExisting(let tab, _):
                model.tabID = tab.id
            case .refused:
                break
            }
        }
        return outcome
    }

    /// Attaches the app-side body's per-path details to the still-pending
    /// pane for `commonDir` (a newer request for the same repository wins),
    /// or stashes them until that pane registers.
    public func attachDetails(
        commonDir: String,
        originPath: String,
        details: [ResolveCardData],
        errorMessage: String?
    ) {
        guard let model = panes.last(where: { $0.commonDir == commonDir && $0.outcome == nil }) else {
            stashedDetails[commonDir] = (originPath, details, errorMessage)
            return
        }
        model.attachDetails(originPath: originPath, details: details, errorMessage: errorMessage)
    }

    private func storeDidChange(pending: PendingResolveStore.Pending, outcome: ResolveOutcome?) {
        if let outcome {
            guard let model = pane(withID: pending.id) else { return }
            model.recordOutcome(outcome)
            if case .decided = outcome {
                dismiss(model)
            }
        } else if pane(withID: pending.id) == nil {
            let model = ResolvePaneModel(pending: pending)
            model.onDecide = { [weak self] answer in
                guard let self else { return false }
                return self.store.resolve(id: model.pendingID, answer: answer)
            }
            model.onApply = { [weak self, weak model] resolution in
                guard let origin = model?.originPath else {
                    throw ResolvePaneApplyError.originUnresolved
                }
                guard let apply = self?.applyResolution else {
                    throw ResolvePaneApplyError.applyUnwired
                }
                try apply(origin, resolution)
            }
            model.onClose = { [weak self, weak model] in
                guard let self, let model else { return }
                self.dismiss(model)
            }
            if let stash = stashedDetails.removeValue(forKey: pending.request.commonDir) {
                model.attachDetails(
                    originPath: stash.originPath,
                    details: stash.details,
                    errorMessage: stash.errorMessage)
            }
            panes.append(model)
        }
    }
}

/// The resolve pane itself: one resolution card per conflicted path, each
/// with ours/base/theirs side by side (#0082's `FileDiffView`), the choice
/// picker, the note field, the per-card Stage button, and the sheet-level
/// Submit/Cancel. Semantic colours only — everything adapts to light and
/// dark without a single literal colour (dark mode by construction).
public struct ResolvePane: View {

    private let model: ResolvePaneModel

    public init(model: ResolvePaneModel) {
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
                cardContent
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions
        }
        .frame(minWidth: 640, minHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resolve conflicts — \(model.cards.count) conflicted path\(model.cards.count == 1 ? "" : "s")")
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
    private var cardContent: some View {
        if let detailsError = model.detailsError {
            Text("Couldn't load the conflicts: \(detailsError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.cards.isEmpty {
            Text("Nothing to resolve — no conflicted paths in this request's scope.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.cards) { card in
                    ResolveCardView(pane: model, card: card)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }
                .disabled(!model.decisionsEnabled)
            Button("Submit resolutions") { model.submit() }
                .disabled(!model.decisionsEnabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

/// One resolution card: the kind, the sides, the choice, the note, and the
/// per-card Stage button — nothing stages until it is pressed.
public struct ResolveCardView: View {

    private let pane: ResolvePaneModel
    @Bindable private var card: ResolveCardModel

    init(pane: ResolvePaneModel, card: ResolveCardModel) {
        self.pane = pane
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.data.path)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Text(card.kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if card.staged {
                    Label("Staged", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .readOnly(let explanation) = card.kind {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                sideBySide
                HStack(spacing: 8) {
                    Picker("Resolution", selection: $card.selectedChoice) {
                        ForEach(card.choices, id: \.self) { choice in
                            Text(ResolveCardModel.label(for: choice)).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                    Spacer()
                    Button("Stage resolution") { pane.stage(card) }
                        .disabled(!pane.decisionsEnabled || card.staged)
                }
                if card.selectedChoice == .editedContent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Merged content — what you save is what stages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $card.editorText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 100)
                            .border(.quaternary)
                    }
                }
                TextField(
                    "Note to the agent (optional)",
                    text: $card.note)
                    .textFieldStyle(.roundedBorder)
                if let stageError = card.stageError {
                    Text("The resolution could not be staged: \(stageError)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(.background)
        .overlay(alignment: .top) { Divider() }
    }

    /// The card's sides, ours/base/theirs, rendered side by side through
    /// #0082's `FileDiffView` — the same component the Detail pane and the
    /// review sheet use; nothing here is a second diff renderer. Each side's
    /// text becomes context lines, so the blob renders as plain text with
    /// conflict markers visible and nothing is interpreted (the design's
    /// untrusted-content rule).
    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(card.sides) { side in
                VStack(alignment: .leading, spacing: 4) {
                    Text(side.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FileDiffView(file: Self.sideDiff(label: side.label, path: card.data.path, text: side.text))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Wraps one side's verbatim text into the `FileDiff` #0082 renders:
    /// one hunk whose body is the text's lines as context lines (the leading
    /// space is the diff marker, the text after it is the blob's line,
    /// verbatim — conflict markers included). Public so a no-`@testable`
    /// test can assert the render source carries the text uninterpreted.
    public static func sideDiff(label: String, path: String, text: String) -> FileDiff {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { " \($0)" }
        return FileDiff(
            path: path,
            oldMode: nil,
            newMode: nil,
            isBinary: false,
            headerText: label,
            hunks: [
                Hunk(
                    id: "resolve-side-\(label)-\(path)",
                    path: path,
                    oldStart: 1, oldCount: lines.count,
                    newStart: 1, newCount: lines.count,
                    header: label,
                    body: lines)
            ])
    }
}
