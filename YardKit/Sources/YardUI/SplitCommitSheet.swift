// SplitCommitSheet.swift — the Split sheet: choose the change that becomes
// the new commit (#0375).
//
// Presented from `ContentView` when the History context menu's Split… item
// is chosen (#0359 will replace that minimal item with its
// `CommitActionMenuItems`). The sheet loads the commit's diff with the same
// `loadCommitDiff` call the Detail pane uses, lists every hunk, and hands
// the composed `SplitArguments` back to the caller — which dismisses the
// sheet and runs `Split.run`, one journal checkpoint, undoable. The pure
// state lives in `SplitChoice` (`SplitChoice.swift`), so every rule — the
// nothing-to-split refusal, the stale-selection refusal, the
// unchanged-message-is-nil mapping — is testable without this view.

import SwiftUI
import YardGit

/// #0375: one pending Split… presentation — the commit the context menu
/// named, with the subject for the sheet's header and the full message the
/// two editors pre-fill from, resolved from the History pane's entries at
/// menu time so a refresh while the sheet is open cannot change them.
public nonisolated struct SplitCommitRequest: Identifiable, Equatable {
    public let commit: String
    public let subject: String
    public let message: String

    public var id: String { commit }

    public init(commit: String, subject: String, message: String) {
        self.commit = commit
        self.subject = subject
        self.message = message
    }
}

/// The Split sheet itself. The Split button hands `SplitChoice.arguments`
/// to `onSplit`; the caller dismisses the sheet first, then runs the
/// engine call, shows its failure alert and refreshes the panes. Cancel
/// and Close both go through `onCancel`, which dismisses.
public struct SplitCommitSheet: View {
    /// The commit being split — typically an oid, any `Split.run`-accepted
    /// revision. Keys the diff load.
    public let commit: String
    /// The commit's subject, beneath the sheet's title in `.secondary`.
    public let subject: String
    /// The repository the split runs against.
    public let repositoryPath: String
    /// The commit's full message, pre-filling both editors.
    public let originalMessage: String
    /// The Split button's action — the caller owns the run, the failure
    /// alert and the refresh; the sheet only composes the arguments.
    public var onSplit: (SplitArguments) -> Void
    /// Cancel and Close, both of which dismiss the sheet.
    public var onCancel: () -> Void

    /// `loadCommitDiff`'s result, nil while loading — the ProgressView
    /// state — and set together with `choice` once it returns.
    @State private var files: [FileDiff] = []
    /// Set when `loadCommitDiff` throws — the error message replaces the
    /// list, and only Close remains.
    @State private var loadError: String?
    /// The pure sheet state, built once the diff is loaded. Nil while
    /// loading or after a load failure.
    @State private var choice: SplitChoice?

    public init(
        commit: String, subject: String, repositoryPath: String, originalMessage: String,
        onSplit: @escaping (SplitArguments) -> Void, onCancel: @escaping () -> Void
    ) {
        self.commit = commit
        self.subject = subject
        self.repositoryPath = repositoryPath
        self.originalMessage = originalMessage
        self.onSplit = onSplit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Split Commit")
                    .font(.headline)
                Text(subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()
            Divider()
            content
            Divider()
            buttons
        }
        // #0375: the sheet's minimum size.
        .frame(minWidth: 640, minHeight: 480)
        .task(id: commit) { await loadDiff() }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            // Load failure: the error message in place of the list.
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let choice {
            if let reason = choice.unavailableReason {
                // Fewer than two hunks — nothing to split. The sentence
                // replaces the list and the editors.
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The change you select becomes a new commit just before the rest.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    hunkList
                }
                .padding([.horizontal, .top])
                messages
            }
        } else {
            // Loading.
            ProgressView("Loading the commit’s changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One `Section` per file, its path the header; each row the hunk's
    /// `@@` header, then up to three of its `+`/`-` lines. A file with no
    /// hunks — binary, or mode-only — shows one disabled row instead:
    /// there is no boundary to split at inside it.
    private var hunkList: some View {
        List(selection: selectedHunkID) {
            ForEach(files, id: \.path) { file in
                Section(file.path) {
                    if file.hunks.isEmpty {
                        Text(file.isBinary
                             ? "Binary file — can’t be split"
                             : "Mode-only change — can’t be split")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(file.hunks, id: \.id) { hunk in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hunk.header)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                ForEach(previewLines(of: hunk), id: \.offset) { line in
                                    Text(line.element)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// The first three `+`/`-` lines of the hunk's body, with their
    /// offsets as stable `ForEach` ids — context and `\ No newline` lines
    /// are not the change the row previews.
    private func previewLines(of hunk: Hunk) -> [(offset: Int, element: String)] {
        Array(
            hunk.body.enumerated()
                .filter { $0.element.hasPrefix("+") || $0.element.hasPrefix("-") }
                .prefix(3))
    }

    /// The two editors, pre-filled with the original message. Plain Return
    /// belongs to the editors — that is why Split's shortcut is ⌘Return.
    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            editor(label: "New commit (the selected change)", text: firstMessage)
            editor(label: "Remaining changes", text: secondMessage)
        }
        .padding([.horizontal, .bottom])
    }

    private func editor(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body.monospaced())
                .frame(minHeight: 56)
        }
    }

    /// Cancel (Esc) and Split (⌘Return — plain Return belongs to the
    /// editors), Split disabled until the state composes arguments. When
    /// the commit cannot be split at all, or its diff failed to load, only
    /// Close remains.
    private var buttons: some View {
        HStack {
            Spacer()
            if let choice, choice.unavailableReason == nil, loadError == nil {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Split") {
                    guard let arguments = choice.arguments else { return }
                    onSplit(arguments)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(choice.arguments == nil)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Close") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    // MARK: - State

    private func loadDiff() async {
        loadError = nil
        files = []
        choice = nil
        do {
            let loaded = try await loadCommitDiff(at: repositoryPath, revision: commit)
            files = loaded
            choice = SplitChoice(commit: commit, message: originalMessage, files: loaded)
        } catch {
            loadError = String(describing: error)
        }
    }

    private var selectedHunkID: Binding<String?> {
        Binding(
            get: { choice?.selectedHunkID },
            set: { choice?.selectedHunkID = $0 })
    }

    private var firstMessage: Binding<String> {
        Binding(
            get: { choice?.firstMessage ?? "" },
            set: { choice?.firstMessage = $0 })
    }

    private var secondMessage: Binding<String> {
        Binding(
            get: { choice?.secondMessage ?? "" },
            set: { choice?.secondMessage = $0 })
    }
}
