// ContentView.swift — moved from Switchyard/ by #0126.
//
// #0339: shows a real repository, picked by the user. No hardcoded path and
// no attempt to guess a repository at launch — a chosen folder that is not a
// repository shows the error, not an empty list (#0140, guide §9 M1
// criterion 3).
//
// #0080: splits the **loaded** state only into three panes -- Sidebar /
// History / Detail. The empty, loading and error states below stay exactly
// as #0339 left them: full-window, no panes.
//
// `HSplitView`, not `NavigationSplitView`: three fixed peer panes with plain
// drag-to-resize dividers is exactly what `HSplitView` gives for free, while
// `NavigationSplitView` bakes in a sidebar/detail *navigation* relationship
// (programmatic collapse, `columnVisibility`) this issue does not need and
// that would fight the "just three columns" shape #0080's planning settled
// on.
//
// The History and Detail panes are placeholders for #0340 and #0082/#0052,
// which are separate, concurrently-dispatched issues -- this file does not
// import or reference `CommitHistoryView` or touch `RepositoryLoader.swift`.

import AppKit
import SwiftUI
import YardGit

public struct ContentView: View {

    /// The chosen repository's folder path, or `nil` before anything is
    /// picked. `.task(id:)` reloads whenever this changes.
    @State private var repositoryPath: String?

    /// The most recent successful load. `nil` while loading or after an
    /// error, so the three states below are mutually exclusive.
    @State private var summary: RepositorySummary?

    /// Set when `loadRepositorySummary` throws — shown instead of an empty
    /// list (#0140).
    @State private var errorMessage: String?

    /// A `public struct`'s memberwise initialiser is **internal**. Without this,
    /// `ContentView()` is unreachable from the app target — the same defect
    /// #0116 found on `WorktreeStatusEntry`, and one `@testable import` hides it
    /// because `@testable` grants internal access.
    public init() {}

    public var body: some View {
        Group {
            if let repositoryPath {
                if let summary {
                    repositoryView(summary: summary)
                } else if let errorMessage {
                    statusMessageView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't open \(repositoryPath)",
                        detail: errorMessage
                    )
                } else {
                    ProgressView("Loading \(repositoryPath)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                statusMessageView(
                    systemImage: "folder.badge.questionmark",
                    title: "No repository open",
                    detail: nil
                )
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar {
            ToolbarItem {
                Button {
                    chooseFolder()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
            }
        }
        .task(id: repositoryPath) {
            await reload()
        }
    }

    private func repositoryView(summary: RepositorySummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RepositoryHeaderView(whereAmI: summary.whereAmI)
                .padding()
            Divider()
            HSplitView {
                sidebarPane
                    .frame(minWidth: PaneLayout.sidebarMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                historyPane
                    .frame(minWidth: PaneLayout.historyMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                detailPane(summary: summary)
                    .frame(minWidth: PaneLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Placeholder for #0081 -- branches, remotes, and stashes.
    private var sidebarPane: some View {
        placeholderPane(
            systemImage: "sidebar.left",
            title: "Sidebar",
            detail: "Branches, remotes, and stashes land here in #0081."
        )
    }

    /// Placeholder for #0340 (a flat commit list) and #0052 (lane rendering).
    /// Deliberately does not reference `CommitHistoryView` -- #0340 is being
    /// dispatched concurrently and owns that file.
    private var historyPane: some View {
        placeholderPane(
            systemImage: "clock.arrow.circlepath",
            title: "History",
            detail: "The commit graph lands here in #0340 and #0052."
        )
    }

    /// The existing status list, unchanged from #0339 (#0082 replaces it).
    /// Hosted here for now so nothing regresses while the Sidebar and History
    /// panes are placeholders.
    private func detailPane(summary: RepositorySummary) -> some View {
        Group {
            if summary.status.entries.isEmpty {
                Text("Working tree clean")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(summary.status.entries, id: \.path) { entry in
                    StatusRow(entry: entry)
                }
            }
        }
    }

    private func placeholderPane(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("\(title) — placeholder")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func statusMessageView(systemImage: String, title: String, detail: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Choose Folder…") {
                chooseFolder()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `NSOpenPanel` limited to directories. No repository validation
    /// happens here — `whereAmI` is the single source of truth for whether
    /// a folder is a repository, run once via `reload()`.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
    }

    private func reload() async {
        guard let repositoryPath else { return }
        errorMessage = nil
        summary = nil
        do {
            summary = try await loadRepositorySummary(at: repositoryPath)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

#Preview {
    ContentView()
}
