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
    private let isBusy: Bool
    private let perform: (WorkingChange) -> Void

    /// Which file's diff the lower half shows: a path on one side.
    struct FileSelection: Hashable {
        let path: String
        let staged: Bool
    }

    @State private var selection: FileSelection?

    public init(
        changes: WorkingChanges, repositoryPath: String, isBusy: Bool,
        perform: @escaping (WorkingChange) -> Void
    ) {
        self.changes = changes
        self.repositoryPath = repositoryPath
        self.isBusy = isBusy
        self.perform = perform
    }

    public var body: some View {
        VStack(spacing: 0) {
            if changes.isClean {
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
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
}
