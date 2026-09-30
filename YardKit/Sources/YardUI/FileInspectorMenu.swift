// FileInspectorMenu.swift
//
// #0519: File ▸ Show File History… and Blame File… (guide §11 decision 39)
// — the file inspector for any file in the working tree, not only one the
// Changes view or a commit lists. An open panel starts in the focused
// window's worktree; the chosen file opens in that window's Detail pane.

import AppKit
import SwiftUI

/// What the two File menu items act on: the focused window's worktree, and
/// how to open the inspector there. The same focused-scene shape as
/// `CommitMenuTarget`.
public struct FileInspectorMenuTarget {
    public let worktreePath: String
    public let open: (FileInspectorTarget) -> Void

    public init(worktreePath: String, open: @escaping (FileInspectorTarget) -> Void) {
        self.worktreePath = worktreePath
        self.open = open
    }
}

extension FocusedValues {
    @Entry public var fileInspectorMenuTarget: FileInspectorMenuTarget? = nil
}

extension FileInspectorTarget {
    /// A file chosen in the open panel, as the working tree's file at its
    /// repository-relative path. `nil` for anything that is not inside
    /// `worktreePath`, and for anything in its `.git` directory. Both paths
    /// are resolved with `realpath(3)` first: the panel hands back
    /// `/private/var/…` for a worktree opened as `/var/…`.
    public nonisolated static func forChosenFile(
        _ url: URL, worktreePath: String, mode: Mode
    ) -> FileInspectorTarget? {
        let root = canonical(worktreePath)
        let file = canonical(url.path)
        guard file.hasPrefix(root + "/") else { return nil }
        let relative = String(file.dropFirst(root.count + 1))
        // By component, not by string prefix: `noSourceConcatenatesOntoDotGit`
        // refuses any source line holding a `.git/` literal.
        guard relative.split(separator: "/").first != ".git" else { return nil }
        return FileInspectorTarget(mode: mode, path: relative, revision: nil)
    }

    private nonisolated static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public struct FileInspectorCommands: Commands {
    @FocusedValue(\.fileInspectorMenuTarget) private var target

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Show File History…") { choose(.history) }
                .disabled(target == nil)
            Button("Blame File…") { choose(.blame) }
                .disabled(target == nil)
        }
    }

    private func choose(_ mode: FileInspectorTarget.Mode) {
        guard let target else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: target.worktreePath, isDirectory: true)
        panel.prompt = mode == .history ? "Show History" : "Blame"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let chosen = FileInspectorTarget.forChosenFile(
            url, worktreePath: target.worktreePath, mode: mode) else {
            NSSound.beep()
            return
        }
        target.open(chosen)
    }
}
