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

    public init(
        changes: WorkingChanges, repositoryPath: String, revision: Int, isBusy: Bool,
        whereAmI: WhereAmI, draft: Binding<CommitDraft>, perform: @escaping (WorkingChange) -> Void
    ) {
        self.changes = changes
        self.repositoryPath = repositoryPath
        self.revision = revision
        self.isBusy = isBusy
        self.whereAmI = whereAmI
        self._draft = draft
        self.perform = perform
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
                }
            }
            Divider()
            commitArea
        }
        .task(id: revision) {
            await reloadDiffs()
            // #0466: HEAD may have moved (a commit, an amend, an undo, a
            // push), so the checkbox's message and refusal are re-read too.
            amendTarget = try? await loadAmendTarget(at: repositoryPath)
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
                    enabled: !changes.unstaged.isEmpty
                ) {
                    perform(.stageFiles(changes.unstaged.map(\.path)))
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String, button: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
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
    }

    // MARK: - #0444: the selected file's diff

    /// The selected row, looked up in the current lists: after a stage or
    /// an unstage the row the selection names may have left its side.
    private var selectedRow: WorkingChanges.Row? {
        guard let selection else { return nil }
        return (selection.staged ? changes.staged : changes.unstaged)
            .first { $0.path == selection.path }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let selection, let row = selectedRow {
            if let diffError {
                placeholder(diffError)
            } else if let diffs {
                if let file = diffs.file(row.path, staged: selection.staged) {
                    ScrollView {
                        FileDiffView(
                            file: file,
                            hunkAction: FileDiffView.HunkAction(
                                title: selection.staged ? "Unstage Hunk" : "Stage Hunk",
                                isEnabled: !isBusy
                            ) { hunk in
                                perform(selection.staged
                                    ? .unstageHunk(id: hunk.id) : .stageHunk(id: hunk.id))
                            })
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if row.state == .untracked {
                    placeholder("\(row.path) is untracked — stage it to add it to the next commit")
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
        do {
            diffs = try await loadWorkingDiffs(at: repositoryPath)
            diffError = nil
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

    /// "N files staged", prefixed while amending with the commit it replaces.
    private var caption: String {
        let staged = changes.staged.count == 1 ? "1 file staged" : "\(changes.staged.count) files staged"
        guard draft.isAmending, let oid = amendTarget?.oid else { return staged }
        return "Amending \(oid.prefix(7)) · \(staged)"
    }
}
