// CommitChangesView.swift
//
// #0404: one commit's changes -- the changed files on the left, every file's
// diff in one scroll view on the right. Selecting a file scrolls its diff to
// the top. #0406 opens this in a window of its own; #0403 adds the Detail
// pane's Show Changes button.

import SwiftUI
import YardGit

/// Which commit a changes window shows. Hashable and Codable so it can be
/// the value of a `WindowGroup(for:)` scene (#0406): SwiftUI focuses an
/// existing window whose value is equal instead of opening a duplicate.
public nonisolated struct CommitChangesTarget: Hashable, Codable, Sendable {
    public let repositoryPath: String
    public let oid: String
    public let subject: String

    public init(repositoryPath: String, oid: String, subject: String) {
        self.repositoryPath = repositoryPath
        self.oid = oid
        self.subject = subject
    }

    /// The window title: the first 10 characters of the oid, then the subject.
    public var title: String { "\(oid.prefix(10)) \(subject)" }
}

/// A changed file's kind, read from its diff header. `commitDiff` pins
/// `--no-renames`, so a rename arrives as a deletion plus an addition.
public nonisolated enum FileChangeKind: String, Sendable, Equatable {
    case added
    case deleted
    case modified

    public static func of(_ file: FileDiff) -> FileChangeKind {
        let lines = file.headerText.split(separator: "\n")
        if lines.contains(where: { $0.hasPrefix("new file mode ") }) { return .added }
        if lines.contains(where: { $0.hasPrefix("deleted file mode ") }) { return .deleted }
        return .modified
    }

    public var systemImage: String {
        switch self {
        case .added: "plus.circle"
        case .deleted: "minus.circle"
        case .modified: "pencil.circle"
        }
    }
}

public struct CommitChangesView: View {
    private let target: CommitChangesTarget
    @State private var files: [FileDiff]?
    @State private var loadError: String?
    @State private var selectedPath: String?

    public init(target: CommitChangesTarget) {
        self.target = target
    }

    public var body: some View {
        HSplitView {
            fileList
                .frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
            diffScroll
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
        .navigationTitle(target.title)
        .task(id: target) { await load() }
    }

    @ViewBuilder
    private var fileList: some View {
        if let files {
            List(files, id: \.path, selection: $selectedPath) { file in
                let kind = FileChangeKind.of(file)
                Label(file.path, systemImage: kind.systemImage)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(file.path) (\(kind.rawValue))")
            }
        } else if let loadError {
            Text(loadError)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let files, files.isEmpty {
                        Text("No file changes to show. Merge commit diffs are not shown yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files ?? [], id: \.path) { file in
                        FileDiffView(file: file)
                            .id(file.path)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Selecting a file is a user event; its diff scrolls to the top.
            .onChange(of: selectedPath) { _, path in
                guard let path else { return }
                withAnimation { proxy.scrollTo(path, anchor: .top) }
            }
        }
        .background(.background)
    }

    private func load() async {
        do {
            files = try await loadCommitDiff(at: target.repositoryPath, revision: target.oid)
            loadError = nil
        } catch {
            files = nil
            loadError = "Could not load this commit's changes: \(error.localizedDescription)"
        }
    }
}
