// FileInspectorView.swift
//
// #0517: the Detail pane's file inspector (guide §11 decision 39) — one
// file's History (the commits that changed it, following renames) or its
// Blame (each line's commit, author and date). It stays until its close
// button or another selection replaces it; clicking a commit in it selects
// that commit in the History pane beside it (`onOpenCommit`), so the two are
// on screen together. `ContentView` owns the target; this view loads.

import SwiftUI
import YardGit

public struct FileInspectorView: View {
    @Binding private var target: FileInspectorTarget
    private let repositoryPath: String
    /// Bumped by `ContentView` after every refresh, so a working-tree blame
    /// reloads after a stage, a commit or an edit made in another app.
    private let revision: Int
    /// A commit was clicked: its oid and subject.
    private let onOpenCommit: (String, String) -> Void
    private let onClose: () -> Void

    @State private var history: [FileHistory.Entry]?
    @State private var blame: [BlameRow]?
    @State private var loadError: String?

    /// What a load is keyed on: the target (its mode included) and the
    /// refresh counter.
    private struct LoadKey: Hashable {
        let target: FileInspectorTarget
        let revision: Int
    }

    public init(
        target: Binding<FileInspectorTarget>, repositoryPath: String, revision: Int,
        onOpenCommit: @escaping (String, String) -> Void, onClose: @escaping () -> Void
    ) {
        self._target = target
        self.repositoryPath = repositoryPath
        self.revision = revision
        self.onOpenCommit = onOpenCommit
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        .task(id: LoadKey(target: target, revision: revision)) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.path)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target.path)
                    .accessibilityIdentifier("file-inspector-path")
                Text(target.revisionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Mode", selection: $target.mode) {
                ForEach(target.modes, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(target.blameUnavailable ?? "History or Blame")
            .accessibilityIdentifier("file-inspector-mode")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("file-inspector-close")
        }
        .padding(8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            placeholder(loadError)
        } else {
            switch target.mode {
            case .history:
                if let history {
                    if history.isEmpty {
                        placeholder("No commit changes \(target.historyPath) yet")
                    } else {
                        historyList(history)
                    }
                } else {
                    loading
                }
            case .blame:
                if let blame {
                    blameList(blame)
                } else {
                    loading
                }
            }
        }
    }

    private func historyList(_ entries: [FileHistory.Entry]) -> some View {
        let now = Date()
        return List(entries, id: \.oid) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subject)
                    .lineLimit(1)
                Text(FileHistoryRowText.caption(for: entry, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let change = FileHistoryRowText.change(for: entry) {
                    Text(change)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpenCommit(entry.oid, entry.subject) }
            .contextMenu {
                if let blameTarget = FileInspectorTarget.blame(of: entry) {
                    Button("Blame This Version") { target = blameTarget }
                }
            }
        }
    }

    /// Lazy in both directions that matter: rows are built as they scroll
    /// into view, and the gutter text was made off the main actor
    /// (`loadBlameRows`). Horizontal scrolling instead of wrapping keeps a
    /// line one row tall. `defaultScrollAnchor(.topLeading)`: a two-axis
    /// scroll view centres content smaller than itself, which floated a
    /// short file to the middle of the pane (measured in the VM).
    private func blameList(_ rows: [BlameRow]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    BlameRowView(row: row, onOpenCommit: onOpenCommit)
                }
            }
            .padding(.vertical, 4)
        }
        .defaultScrollAnchor(.topLeading)
        .font(.system(.caption, design: .monospaced))
    }

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loadError = nil
        do {
            switch target.mode {
            case .history:
                history = nil
                history = try await loadFileHistory(at: repositoryPath, target: target)
            case .blame:
                blame = nil
                blame = try await loadBlameRows(at: repositoryPath, target: target)
            }
        } catch is CancellationError {
            // A newer load replaced this one.
        } catch {
            loadError = "Couldn't load \(target.mode.title.lowercased()) for \(target.path): \(error)"
        }
    }
}

/// One blame line: the gutter (on a run's first line: the oid as a link,
/// the author, the date), the line number, and the line.
private struct BlameRowView: View {
    let row: BlameRow
    let onOpenCommit: (String, String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            gutter
                .frame(width: 190, alignment: .leading)
            Text("\(row.id)")
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(row.content)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(row.run.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.08))
    }

    @ViewBuilder
    private var gutter: some View {
        if let commit = row.commit {
            HStack(spacing: 6) {
                if let oid = commit.oid {
                    Button(commit.shortOid) { onOpenCommit(oid, commit.summary) }
                        .buttonStyle(.link)
                        .help(commit.summary)
                        .accessibilityIdentifier("blame-commit-\(commit.shortOid)")
                }
                Text(commit.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(commit.date)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

#Preview {
    @Previewable @State var target = FileInspectorTarget(mode: .history, path: "Sources/Example.swift", revision: nil)
    FileInspectorView(
        target: $target, repositoryPath: "/tmp", revision: 0,
        onOpenCommit: { _, _ in }, onClose: {})
        .frame(width: 520, height: 400)
}
