// WorkingChangesView.swift
//
// The Detail pane's Changes view (guide §11 decision 30): what the Detail
// pane shows when no commit is selected. #0443 lists the staged and
// unstaged files with per-file Stage/Unstage; #0444 shows the selected
// file's diff with per-hunk buttons; #0445 adds the commit message and the
// Commit button. `ContentView` owns every mutation (`runWorkingChange`) so
// the busy flag, the failure alert and the in-place refresh stay in one
// place; this view only asks.

import SwiftUI
import YardGit

public struct WorkingChangesView: View {
    private let changes: WorkingChanges
    private let repositoryPath: String
    /// Bumped by `ContentView` after every refresh, so the diffs reload even
    /// when the status did not change shape (a hunk staged in an `MM` file).
    private let revision: Int
    private let isBusy: Bool
    /// #0466: the operation-in-progress flags the Amend checkbox reads.
    private let whereAmI: WhereAmI
    private let perform: (WorkingChange) -> Void
    /// #0518: Show History and Blame on a file row (guide §11 decision 39).
    /// `nil` offers neither.
    private let onInspect: ((FileInspectorTarget) -> Void)?

    /// Which file's diff the lower half shows: a path on one side.
    struct FileSelection: Hashable {
        let path: String
        let staged: Bool
    }

    @State private var selection: FileSelection?
    /// #0444: both hunk listings; `nil` while loading.
    @State private var diffs: WorkingDiffs?
    @State private var diffError: String?
    /// #0445, #0466: the draft commit message and the Amend checkbox,
    /// owned by `ContentView` so they survive selecting a commit and coming
    /// back.
    @Binding private var draft: CommitDraft
    /// #0466: what Amend would rewrite; `nil` until `loadAmendTarget`
    /// answers, and after it fails.
    @State private var amendTarget: AmendHead.Target?
    /// #0471: the Discard confirmation on screen; `nil` when none is.
    @State private var pendingDiscard: DiscardConfirmation?
    /// #0480: the selected lines in the diff (guide §11 decision 35).
    /// Cleared when another file is selected. A refresh keeps it: it names
    /// a hunk by id, and an id is a hash of the hunk's lines, so a hunk that
    /// changed (a staged line, an edit) drops out of the selection by
    /// itself, and one that did not keeps its selected lines.
    @State private var lineSelection = DiffLineSelection()
    /// #0494: whether the Stash Changes sheet is up.
    @State private var showingStashSheet = false
    /// #0539: Ignore Whitespace and Context (guide §11 decision 42). Not
    /// persisted: anything but the standard options turns hunk and line
    /// actions off, and that must not outlive the look it was for.
    @State private var diffOptions = DiffViewOptions()
    /// #0539: the options `diffs` was drawn with. Hunk and line actions wait
    /// for a standard listing, not only standard options: switching back
    /// shows the filtered listing until the reload lands.
    @State private var diffsDrawnWith = DiffViewOptions()
    /// #0566: the people the Co-Author menu offers; empty until loaded.
    @State private var coAuthors: [CoAuthors.Person] = []

    /// What the diffs are reloaded for: a refresh, or new options.
    private struct DiffLoad: Hashable {
        let revision: Int
        let options: DiffViewOptions
    }

    public init(
        changes: WorkingChanges, repositoryPath: String, revision: Int, isBusy: Bool,
        whereAmI: WhereAmI, draft: Binding<CommitDraft>, perform: @escaping (WorkingChange) -> Void,
        onInspect: ((FileInspectorTarget) -> Void)? = nil
    ) {
        self.changes = changes
        self.repositoryPath = repositoryPath
        self.revision = revision
        self.isBusy = isBusy
        self.whereAmI = whereAmI
        self._draft = draft
        self.perform = perform
        self.onInspect = onInspect
    }

    public var body: some View {
        VStack(spacing: 0) {
            if changes.isClean {
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    fileList
                        .frame(minHeight: 120, maxHeight: .infinity)
                    diffPane
                        .frame(minHeight: 120, maxHeight: .infinity)
                        // #0480: a selection belongs to the file it was made in.
                        .onChange(of: selection) { lineSelection = DiffLineSelection() }
                        // #0539: and to the listing it was made in.
                        .onChange(of: diffOptions) { lineSelection = DiffLineSelection() }
                }
            }
            Divider()
            commitArea
        }
        // #0539: the diffs reload for a refresh and for new options.
        .task(id: DiffLoad(revision: revision, options: diffOptions)) { await reloadDiffs() }
        .task(id: revision) {
            // #0466: HEAD may have moved (a commit, an amend, an undo, a
            // push), so the checkbox's message and refusal are re-read too.
            amendTarget = try? await loadAmendTarget(at: repositoryPath)
            // #0566: a commit may have brought a new author.
            coAuthors = (try? await loadCoAuthors(at: repositoryPath)) ?? []
        }
        // #0471: every discard asks first (guide §11 decision 34). Return
        // does nothing: the destructive button has no default-action
        // shortcut, #0359's rule for Delete Commit….
        .confirmationDialog(
            pendingDiscard?.title ?? "",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { confirmation in
            Button("Discard", role: .destructive) { perform(confirmation.change) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        // #0494: Stash Changes… (guide §11 decision 36). The sheet goes away
        // before the stash runs, so the progress line is not behind it.
        .sheet(isPresented: $showingStashSheet) {
            StashChangesSheet(
                hasUntracked: changes.hasUntracked,
                onStash: { change in
                    showingStashSheet = false
                    perform(change)
                },
                onCancel: { showingStashSheet = false })
        }
    }

    // MARK: - #0443: the file lists

    private var fileList: some View {
        List(selection: $selection) {
            if !changes.conflicted.isEmpty {
                Section("Conflicted (\(changes.conflicted.count))") {
                    ForEach(changes.conflicted) { row in
                        fileRow(row, staged: false, action: nil)
                    }
                }
            }
            Section {
                ForEach(changes.staged) { row in
                    fileRow(row, staged: true, action: "Unstage")
                        .tag(FileSelection(path: row.path, staged: true))
                }
            } header: {
                sectionHeader(
                    "Staged Changes (\(changes.staged.count))", button: "Unstage All",
                    enabled: !changes.staged.isEmpty
                ) {
                    perform(.unstageFiles(WorkingChanges.unstagePaths(for: changes.staged)))
                }
            }
            Section {
                ForEach(changes.unstaged) { row in
                    fileRow(row, staged: false, action: "Stage")
                        .tag(FileSelection(path: row.path, staged: false))
                }
            } header: {
                sectionHeader(
                    "Changes (\(changes.unstaged.count))", button: "Stage All",
                    enabled: !changes.unstaged.isEmpty,
                    discardAll: { pendingDiscard = DiscardConfirmation(rows: changes.discardableRows) }
                ) {
                    perform(.stageFiles(changes.unstaged.map(\.path)))
                }
            }
        }
    }

    /// `discardAll`, when given, adds #0471's Discard All… left of the
    /// section's button.
    private func sectionHeader(
        _ title: String, button: String, enabled: Bool,
        discardAll: (() -> Void)? = nil, action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let discardAll {
                Button("Discard All…", action: discardAll)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(changes.discardableRows.isEmpty || isBusy)
                    .accessibilityIdentifier("discard-all")
            }
            Button(button, action: action)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!enabled || isBusy)
        }
    }

    /// One file. `action` is the per-file button's title, `nil` for a
    /// conflicted file, which has none. The identifiers are what the VM
    /// tests click, one per side: `tracked.txt` can be on both.
    private func fileRow(_ row: WorkingChanges.Row, staged: Bool, action: String?) -> some View {
        let side = staged ? "staged" : "unstaged"
        return HStack(spacing: 8) {
            Text(row.badge)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(row.stateName)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.path)
                    .accessibilityIdentifier("changes-\(side)-\(row.path)")
                if let originalPath = row.originalPath {
                    Text("was \(originalPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let action {
                Button(action) {
                    perform(staged
                        ? .unstageFiles(WorkingChanges.unstagePaths(for: [row]))
                        : .stageFiles([row.path]))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityIdentifier("\(action.lowercased())-file-\(row.path)")
            }
        }
        // #0518: Show History and Blame on any row that has them — not an
        // untracked or a conflicted one. #0471: Discard Changes… on an
        // unstaged row. A menu with no items is not shown.
        .contextMenu {
            if let onInspect, let target = FileInspectorTarget.forWorkingRow(row, mode: .history) {
                Button("Show History") { onInspect(target) }
                Button("Blame") { onInspect(target.with(.blame)) }
                    .disabled(target.blameUnavailable != nil)
            }
            if WorkingChanges.canDiscard(row) {
                Button("Discard Changes…") {
                    pendingDiscard = DiscardConfirmation(rows: [row])
                }
                .disabled(isBusy)
            }
        }
    }

    // MARK: - #0444: the selected file's diff

    /// The selected row, looked up in the current lists: after a stage or
    /// an unstage the row the selection names may have left its side.
    private var selectedRow: WorkingChanges.Row? {
        guard let selection else { return nil }
        return (selection.staged ? changes.staged : changes.unstaged)
            .first { $0.path == selection.path }
    }

    /// #0539: the options bar over the selected file's diff.
    @ViewBuilder
    private var diffPane: some View {
        if selectedRow != nil {
            VStack(spacing: 0) {
                DiffOptionsBar(options: $diffOptions, stagingNote: true)
                Divider()
                diffBody
            }
        } else {
            diffBody
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if let selection, let row = selectedRow {
            if let diffError {
                placeholder(diffError)
            } else if let diffs {
                if let file = diffs.file(row.path, staged: selection.staged) {
                    // #0539: hunk and line actions act on the standard
                    // listing only (guide §11 decision 42).
                    let actsOnHunks = diffOptions.isStandard && diffsDrawnWith.isStandard
                    ScrollView {
                        FileDiffView(
                            file: file,
                            hunkAction: FileDiffView.HunkAction(
                                title: selection.staged ? "Unstage Hunk" : "Stage Hunk",
                                linesTitle: selection.staged ? "Unstage Lines" : "Stage Lines",
                                isEnabled: !isBusy && actsOnHunks
                            ) { hunk, lines in
                                perform(.stageOrUnstage(hunk, lines: lines, staged: selection.staged))
                            },
                            // #0472: Discard Hunk… on the unstaged side only;
                            // #0480: Discard Lines… while lines are selected.
                            discardAction: selection.staged ? nil : FileDiffView.HunkAction(
                                title: "Discard Hunk…", linesTitle: "Discard Lines…",
                                isEnabled: !isBusy && actsOnHunks
                            ) { hunk, lines in
                                pendingDiscard = lines.isEmpty
                                    ? DiscardConfirmation(hunk: hunk) : DiscardConfirmation(lines: lines, of: hunk)
                            },
                            lineSelection: actsOnHunks ? $lineSelection : nil)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if row.state == .untracked {
                    placeholder("\(row.path) is untracked — stage it to add it to the next commit")
                } else if diffsDrawnWith.ignoresWhitespace {
                    // #0539: `-w` leaves out a file whose every change is whitespace.
                    placeholder(DiffViewOptions.whitespaceOnlyNote(for: row.path))
                } else {
                    placeholder("No diff to show for \(row.path)")
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            placeholder("Select a file to see its changes")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reloadDiffs() async {
        let options = diffOptions
        do {
            diffs = try await loadWorkingDiffs(at: repositoryPath, options: options.diffOptions)
            diffsDrawnWith = options
            diffError = nil
        } catch is CancellationError {
            // #0539: new options or a refresh replaced this load; the
            // next one fills the pane.
        } catch {
            diffError = String(describing: error)
        }
    }

    // MARK: - #0445: the commit message and Commit; #0466: Amend

    private var commitArea: some View {
        let amendUnavailable = WorkingChanges.amendUnavailableReason(
            target: amendTarget, whereAmI: whereAmI)
        let blocked = draft.blockedReason(for: changes, amendUnavailable: amendUnavailable)
        return VStack(alignment: .leading, spacing: 6) {
            // #0494: Stash Changes… (guide §11 decision 36), on its own row
            // above the editor: beside Amend and Commit it truncated and
            // pushed "Amend" onto two lines in a narrow Detail pane
            // (measured in the VM).
            HStack {
                coAuthorMenu
                Spacer()
                Button("Stash Changes…") { showingStashSheet = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(changes.stashBlockedReason != nil || isBusy)
                    .help(changes.stashBlockedReason ?? "Save the changes as a stash and clean the working tree")
                    .accessibilityIdentifier("stash-changes")
            }
            TextEditor(text: $draft.message)
                .font(.body)
                .frame(minHeight: 56, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if draft.message.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("commit-message")
            // #0563: the subject and body guides (guide §11 decision 45).
            // A warning, never a block: Commit does not read it.
            if !draft.message.isEmpty {
                let guide = CommitMessageGuide(message: draft.message)
                Text(guide.summary)
                    .font(.caption)
                    .foregroundStyle(guide.isWarning ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("message-guide")
            }
            HStack {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // A checkbox that is on stays enabled while Amend is
                // unavailable, so it can always be turned off.
                Toggle("Amend", isOn: Binding(
                    get: { draft.isAmending },
                    set: { draft.setAmending($0, headMessage: amendTarget?.message ?? "") }))
                    .toggleStyle(.checkbox)
                    .disabled(isBusy || (amendUnavailable != nil && !draft.isAmending))
                    .help(amendUnavailable ?? "Replace the last commit with the staged changes and this message")
                    .accessibilityIdentifier("amend-checkbox")
                Button(draft.isAmending ? "Amend" : "Commit") {
                    perform(draft.change)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blocked != nil || isBusy)
                .help(blocked ?? (draft.isAmending
                    ? "Amend the last commit (⌘↩)" : "Commit the staged changes (⌘↩)"))
                .accessibilityIdentifier("commit-button")
            }
        }
        .padding(8)
    }

    /// #0566: Co-Author, which adds `Co-authored-by: Name <email>` to the
    /// message (guide §11 decision 45).
    private var coAuthorMenu: some View {
        Menu("Co-Author") {
            ForEach(coAuthors, id: \.self) { person in
                Button(person.identity) { addCoAuthor(person) }
            }
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(coAuthors.isEmpty || isBusy)
        .help(coAuthors.isEmpty
            ? "No one else has committed here recently"
            : "Credit someone with a Co-authored-by trailer")
        .accessibilityIdentifier("co-author-menu")
    }

    /// #0566: adds `person`'s trailer where git puts it. The editor is only
    /// changed if it still holds what was sent: a keystroke typed while git
    /// ran is never overwritten.
    private func addCoAuthor(_ person: CoAuthors.Person) {
        let sent = draft.message
        Task {
            guard let updated = try? await addingTrailer(person.trailer, to: sent, at: repositoryPath),
                  draft.message == sent else { return }
            draft.message = updated
        }
    }

    /// "N files staged", prefixed while amending with the commit it replaces.
    private var caption: String {
        let staged = changes.staged.count == 1 ? "1 file staged" : "\(changes.staged.count) files staged"
        guard draft.isAmending, let oid = amendTarget?.oid else { return staged }
        return "Amending \(oid.prefix(7)) · \(staged)"
    }
}
