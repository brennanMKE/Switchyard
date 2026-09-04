// AskSheet.swift — the human's ask surface (#0056)
//
// Three types, kept on the #0055 ReviewSheet pattern: the model is
// VALUE-DRIVEN — the app target feeds it (pending registrations from the
// `PendingAskStore` event hook, the resolved tab routing) and no test or
// preview ever touches the XPC layer. The centre owns lifecycle and tab
// routing; the view is a pure function of the model. All behaviour lives
// here in YardUI (guide §11 decision 10); the app target only constructs
// and injects.
//
// **The question is untrusted input and renders as TEXT — never as
// markdown, never as a link.** It comes from an agent; the view renders it
// through `Text(verbatim:)`, so every byte of it is literal.

import SwiftUI
import YardGit
import YardKit

/// Everything one pending ask's sheet renders, and the answer the human is
/// composing. One instance per pending ask; `askID` is the store's handle
/// the reply resolves through.
///
/// States the sheet reflects, all settable/driveable without AppKit:
/// - **pending** — `outcome == nil`, option buttons and the decline button
///   enabled;
/// - **decided** — the centre removes the model, which dismisses the sheet;
/// - **timedOut** — the store reported the typed outcome, the banner names
///   it, and the buttons disable.
@Observable
public final class AskSheetModel: Identifiable {

    /// The pending store's id this sheet resolves through.
    public let askID: UUID

    /// The repository's common dir — the tab identity the sheet belongs to.
    public let commonDir: String

    /// The question, carried VERBATIM from the request. Rendered as literal
    /// text — never markup, never a link (the untrusted-input rule).
    public let question: String

    /// The answer options in presentation order. The reply carries an index
    /// into this array, so it is fixed at registration.
    public let options: [String]

    /// How long the agent waits before its typed timeout fires.
    public let timeoutSeconds: Int

    public var id: UUID { askID }

    /// The tab the ask was routed to (`AskCenter.routeToTab`), or nil
    /// before routing ran.
    public internal(set) var tabID: UUID?

    /// The working directory the ask request came from — a path inside the
    /// repository, which may be deeper than the root the tab shows. Set by
    /// `attachOrigin` once the app-side body resolved the request.
    public private(set) var originPath: String?

    /// The free text the human typed alongside the answer or the decline
    /// (optional).
    public var message: String

    /// The store's typed outcome once the pending resolved — nil while the
    /// human still decides. `.decided` never lands here for display: the
    /// centre dismisses decided sheets instead.
    public private(set) var outcome: AskOutcome?

    /// The store resolution the option and decline buttons drive. Returns
    /// whether the pending was still there to receive it. The centre wires
    /// this to `PendingAskStore.resolve(id:answer:)`; a test can wire a
    /// double or a real store.
    @ObservationIgnored public var onAnswer: ((AskReply) -> Bool)?

    /// The banner's Close action, set by the centre (its `dismiss`).
    @ObservationIgnored public var onClose: (() -> Void)?

    public init(pending: PendingAskStore.Pending) {
        self.askID = pending.id
        self.commonDir = pending.request.commonDir
        self.question = pending.request.question
        self.options = pending.request.options
        self.timeoutSeconds = pending.request.timeoutSeconds
        self.message = ""
    }

    /// Attaches the request's resolved origin (the worktree root the ask
    /// came from), so presentation can match a tab opened at that root even
    /// when the common dir differs.
    public func attachOrigin(originPath: String) {
        self.originPath = originPath
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

    /// The option and decline buttons' enabled state: a typed outcome ends
    /// the ask — a decided or timed-out sheet must not compose a second
    /// reply.
    public var answersEnabled: Bool { outcome == nil }

    /// What the banner says for the current outcome, or nil while pending
    /// (and for `.decided`, which dismisses the sheet rather than
    /// bannering).
    public var outcomeLabel: String? {
        switch outcome {
        case .timedOut:
            "This ask timed out before the human answered."
        case .decided, nil:
            nil
        }
    }

    // MARK: - The composed answer

    /// The `AskReply` the buttons send: the picked option's index and text,
    /// or the declined marker — with the message only when typed.
    public func composedReply(forIndex index: Int) -> AskReply {
        AskReply.chosen(index: index, text: options[index], message: message.isEmpty ? nil : message)
    }

    /// The decline's `AskReply`: no option, the declined marker, and the
    /// message when typed. A decline is a decided reply with declined
    /// semantics (the CLI exits 7), never a timeout.
    public func composedDecline() -> AskReply {
        AskReply.declined(message: message.isEmpty ? nil : message)
    }

    /// Sends the answer for `options[index]` through `onAnswer`. A sheet
    /// with a typed outcome (or nothing wired to resolve through) refuses:
    /// the pending is no longer there to answer. An out-of-range index
    /// refuses too — options are fixed at registration.
    @discardableResult
    public func answer(index: Int) -> Bool {
        guard answersEnabled, index >= 0, index < options.count, let onAnswer else {
            return false
        }
        return onAnswer(composedReply(forIndex: index))
    }

    /// Sends the decline through `onAnswer`, under the same refusals as
    /// `answer(index:)`.
    @discardableResult
    public func decline() -> Bool {
        guard answersEnabled, let onAnswer else { return false }
        return onAnswer(composedDecline())
    }

    /// The store's outcome, reflected by the sheet (banner, disabled
    /// buttons) — or dismissal, which the centre performs for `.decided`.
    public func recordOutcome(_ outcome: AskOutcome) {
        self.outcome = outcome
    }

    /// The banner's Close: the centre owns removal, the model only forwards.
    public func close() {
        onClose?()
    }
}

/// The lifecycle owner of the ask sheets (#0056): one model per pending
/// ask, created from the pending store's own event hook, dismissed when the
/// store resolves it, and routed to the repository's tab through #0084's
/// focus-or-open rule. One sheet per repository shows the head of its
/// queue: queue order is registration order, so the first still-pending
/// model for a repository IS the head — answering (or timing out) the head
/// makes the next one the presented sheet, with no promotion event needed.
///
/// The store's hook fires on XPC's queues; everything here lands on the
/// main actor through a `Task`, so the sheets are observed and mutated on
/// one actor only.
@Observable
public final class AskCenter {

    /// The live models, in registration order (= queue order per
    /// repository). Decided models are removed (the sheet dismisses);
    /// timed-out models stay until the human closes their banner, so the
    /// outcome is never a silent vanish.
    public private(set) var sheets: [AskSheetModel] = []

    /// An origin that arrived before its registration event — keyed by
    /// commonDir, applied the moment the sheet exists. The serving body
    /// resolves the repository before registering, so this is normally
    /// consumed immediately; the stash only makes the two arrivals
    /// order-independent.
    private var stashedOrigins: [String: String] = [:]

    private let store: PendingAskStore

    /// - Parameter store: the app's pending-ask store. The centre wires
    ///   itself as the store's change observer for its lifetime; answers
    ///   the sheets compose go through the same store.
    public init(store: PendingAskStore) {
        self.store = store
        store.onPendingChange = { [weak self] pending, outcome in
            Task { @MainActor in
                self?.storeDidChange(pending: pending, outcome: outcome)
            }
        }
    }

    /// The sheet for a pending id, if it is still live.
    public func sheet(withID id: UUID) -> AskSheetModel? {
        sheets.first { $0.askID == id }
    }

    /// The still-pending sheet whose repository contains `path` — the
    /// binding the app's content view presents while it shows that
    /// repository by path. The FIRST match is the head of that
    /// repository's queue (registration order is queue order).
    public func activeSheet(forRepositoryPath path: String) -> AskSheetModel? {
        sheets.first { $0.outcome == nil && $0.repositoryContains(path: path) }
    }

    /// Drops a model — the banner's Close, or a decided sheet's dismissal.
    public func dismiss(_ model: AskSheetModel) {
        sheets.removeAll { $0.askID == model.askID }
    }

    /// #0084's focus-or-open for an ask's repository: an already-open
    /// repository has its tab selected; an unopened one is opened into the
    /// frontmost window. The routed tab's id is recorded on the sheet so
    /// the per-tab presentation can bind on tab identity alone.
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

    /// Attaches the app-side body's resolved origin to the still-pending
    /// sheet for `commonDir`, or stashes it until that sheet registers.
    public func attachOrigin(commonDir: String, originPath: String) {
        guard let model = sheets.last(where: { $0.commonDir == commonDir && $0.outcome == nil }) else {
            stashedOrigins[commonDir] = originPath
            return
        }
        model.attachOrigin(originPath: originPath)
    }

    private func storeDidChange(pending: PendingAskStore.Pending, outcome: AskOutcome?) {
        if let outcome {
            guard let model = sheet(withID: pending.id) else { return }
            model.recordOutcome(outcome)
            if case .decided = outcome {
                dismiss(model)
            }
        } else if sheet(withID: pending.id) == nil {
            let model = AskSheetModel(pending: pending)
            model.onAnswer = { [weak self] reply in
                guard let self else { return false }
                return self.store.resolve(id: model.askID, answer: reply)
            }
            model.onClose = { [weak self, weak model] in
                guard let self, let model else { return }
                self.dismiss(model)
            }
            if let stash = stashedOrigins.removeValue(forKey: pending.request.commonDir) {
                model.attachOrigin(originPath: stash)
            }
            sheets.append(model)
        }
    }
}

/// The ask sheet itself: the question as literal text, the option buttons
/// in presentation order, the optional message field, and the decline
/// button. Semantic colours only — everything adapts to light and dark
/// without a single literal colour.
public struct AskSheet: View {

    private let model: AskSheetModel

    public init(model: AskSheetModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                // The question is untrusted agent input: `Text(verbatim:)`
                // renders it as literal text — never markdown, never a link.
                Text(verbatim: model.question)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(model.originPath ?? model.commonDir)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let outcomeLabel = model.outcomeLabel {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(outcomeLabel)
                        .font(.callout)
                    Spacer()
                    Button("Close") { model.close() }
                }
                .padding()
                .background(.bar)
            }

            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 200)
    }

    private var composer: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            // Option buttons in presentation order — the index the reply
            // carries is this order.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.options.enumerated()), id: \.offset) { index, option in
                    Button(option) { model.answer(index: index) }
                        .disabled(!model.answersEnabled)
                }
            }
            TextField("Message (optional)", text: $model.message)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Decline to answer") { model.decline() }
                    .disabled(!model.answersEnabled)
            }
        }
        .padding()
    }
}
