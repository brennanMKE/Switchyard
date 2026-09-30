// StashDetailView.swift
//
// #0496: the Detail pane's content for a stash selected in the sidebar
// (guide §11 decision 36) — its message, the commit it was made on, and
// its files' diffs, read-only through `FileDiffView`, with Apply, Pop and
// Drop…. `ContentView` owns every mutation and the Drop… confirmation, so
// the busy flag, the alerts and the in-place refresh stay in one place;
// this view only asks, the way `WorkingChangesView` does.

import SwiftUI
import YardGit

public struct StashDetailView: View {
    private let item: Stash.Item
    /// #0541: where the stash lives, for loading it with diff options.
    private let repositoryPath: String
    /// `nil` while loading; the stash's files otherwise (`loadStashDiff`).
    private let files: [FileDiff]?
    private let diffError: String?
    private let isBusy: Bool
    private let perform: (StashAction) -> Void
    private let onDrop: () -> Void

    /// Restore staged changes: Apply and Pop pass `--index`. Off by
    /// default, git's own default (decision 36).
    @State private var restoreIndex = false
    /// #0541: Ignore Whitespace and Context (guide §11 decision 42); not
    /// persisted.
    @State private var options = DiffViewOptions()
    /// #0541: the stash drawn with `options`; `nil` for the standard
    /// options (`files` is drawn) and while it loads.
    @State private var shownFiles: [FileDiff]?

    /// What `shownFiles` is loaded for.
    private struct ShownLoad: Hashable {
        let oid: String
        let options: DiffViewOptions
    }

    public init(
        item: Stash.Item, repositoryPath: String, files: [FileDiff]?, diffError: String?, isBusy: Bool,
        perform: @escaping (StashAction) -> Void, onDrop: @escaping () -> Void
    ) {
        self.item = item
        self.repositoryPath = repositoryPath
        self.files = files
        self.diffError = diffError
        self.isBusy = isBusy
        self.perform = perform
        self.onDrop = onDrop
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                diffContent
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: ShownLoad(oid: item.oid, options: options)) { await loadShown() }
    }

    /// #0541: the stash drawn with `options`. The standard options draw
    /// `files` and load nothing.
    private func loadShown() async {
        guard !options.isStandard else {
            shownFiles = nil
            return
        }
        do {
            shownFiles = try await loadStashDiff(
                at: repositoryPath, oid: item.oid, options: options.diffOptions)
        } catch is CancellationError {
            // New options replaced this load; the next one fills the pane.
        } catch {
            // The standard diff stays on screen.
            shownFiles = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StashRowText.label(for: item))
                .font(.headline)
                .textSelection(.enabled)
            Text(StashRowText.caption(for: item) + " · on " + String(item.baseOID.prefix(7))
                + (item.includesUntracked ? " · includes untracked files" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            // The checkbox has its own line: beside the buttons it wrapped a
            // word per line in a narrow Detail pane (measured in the VM).
            HStack {
                Button("Apply") { perform(.apply(oid: item.oid, restoreIndex: restoreIndex)) }
                    .help("Apply the stash and keep it")
                    .accessibilityIdentifier("stash-apply")
                Button("Pop") { perform(.pop(oid: item.oid, restoreIndex: restoreIndex)) }
                    .help("Apply the stash and drop it")
                    .accessibilityIdentifier("stash-pop")
                Button("Drop…", role: .destructive, action: onDrop)
                    .help("Remove the stash from the list")
                    .accessibilityIdentifier("stash-drop")
            }
            .disabled(isBusy)
            Toggle("Restore staged changes", isOn: $restoreIndex)
                .toggleStyle(.checkbox)
                .help("Put staged changes back staged (git stash apply --index)")
                .accessibilityIdentifier("stash-restore-index")
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if let diffError {
            Text("Couldn't load the stash: \(diffError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let files {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(CommitDetailView.changedFilesSummary(count: files.count))
                        .font(.subheadline.weight(.semibold))
                    // #0541: the options bar, beside the count.
                    DiffOptionsBar(options: $options)
                }
                ForEach(files, id: \.path) { file in
                    if let shown = DiffViewOptions.file(file, in: shownFiles) {
                        FileDiffView(file: shown)
                    } else {
                        WhitespaceOnlyFileView(path: file.path)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// #0496: the Drop… confirmation, as a modifier so `ContentView.body` stays
/// inside the type-checker's budget. Return does nothing: the destructive
/// button has no default-action shortcut, #0359's rule for Delete Commit….
struct StashDropDialog: ViewModifier {
    @Binding var pending: StashDropConfirmation?
    let onConfirm: (StashAction) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { confirmation in
            Button("Drop", role: .destructive) {
                pending = nil
                onConfirm(confirmation.action)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
