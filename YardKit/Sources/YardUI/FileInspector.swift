// FileInspector.swift
//
// #0516: the data layer of the Detail pane's file inspector (guide §11
// decision 39) — one file's history (`git log --follow`) or its blame, at a
// commit or in the working tree. Read-only: nothing here writes a journal
// entry. The view is `FileInspectorView` (#0517).

import Foundation
import YardGit

/// Which file the inspector shows, at which revision, in which mode.
public nonisolated struct FileInspectorTarget: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable, CaseIterable {
        case history, blame

        public var title: String {
            switch self {
            case .history: "History"
            case .blame: "Blame"
            }
        }
    }

    public var mode: Mode
    /// The file, repository-relative: the path blamed and the one shown.
    public let path: String
    /// The commit the file is read at; `nil` is the working tree — Blame
    /// reads the file on disk, and History starts at `HEAD`.
    public let revision: String?
    /// The path `git log --follow` starts from: `path`, except a rename in
    /// the working tree, whose original path is the one `HEAD` has.
    public let historyPath: String
    /// Why Blame is unavailable here; `nil` when it is available.
    public let blameUnavailable: String?

    public init(mode: Mode, path: String, revision: String?,
                historyPath: String? = nil, blameUnavailable: String? = nil) {
        self.mode = mode
        self.path = path
        self.revision = revision
        self.historyPath = historyPath ?? path
        self.blameUnavailable = blameUnavailable
    }

    /// The same file in another mode.
    public func with(_ mode: Mode) -> FileInspectorTarget {
        var copy = self
        copy.mode = mode
        return copy
    }

    /// The revision History starts from.
    public var historyRevision: String { revision ?? "HEAD" }

    /// The modes the header offers: Blame only where it is available.
    public var modes: [Mode] { blameUnavailable == nil ? Mode.allCases : [.history] }

    /// The header's second line: "Working tree" or "At <7-char oid>".
    public var revisionLabel: String {
        revision.map { "At \($0.prefix(7))" } ?? "Working tree"
    }

    /// A row of the Changes view, or `nil` for a row with neither history
    /// nor blame: an untracked file (no commit has it and `git blame`
    /// refuses it) and a conflicted one (resolve it first).
    public static func forWorkingRow(_ row: WorkingChanges.Row, mode: Mode) -> FileInspectorTarget? {
        switch row.state {
        case .untracked, .conflicted, .unmerged, .ignored, .unmodified:
            return nil
        case .deleted:
            return FileInspectorTarget(
                mode: .history, path: row.path, revision: nil,
                blameUnavailable: "\(row.path) is deleted in the working tree")
        case .modified, .added, .typechange:
            return FileInspectorTarget(
                mode: mode, path: row.path, revision: nil, historyPath: row.originalPath)
        }
    }

    /// A file a commit changed (`commitDiff`'s entries; renames arrive as a
    /// deletion and an addition, `--no-renames`). A file the commit deleted
    /// has history and nothing to blame.
    public static func forCommitFile(_ file: FileDiff, oid: String, mode: Mode) -> FileInspectorTarget {
        if FileChangeKind.of(file) == .deleted {
            return FileInspectorTarget(
                mode: .history, path: file.path, revision: oid,
                blameUnavailable: "\(file.path) is deleted in this commit")
        }
        return FileInspectorTarget(mode: mode, path: file.path, revision: oid)
    }

    /// A row of the inspector's own History: the file as that commit left
    /// it, blamed. `nil` for the commit that deleted it.
    public static func blame(of entry: FileHistory.Entry) -> FileInspectorTarget? {
        entry.isDeletion ? nil : FileInspectorTarget(mode: .blame, path: entry.path, revision: entry.oid)
    }
}

/// What clicking a commit in the inspector does (guide §11 decision 39):
/// select it in History when History has loaded it, else open its changes
/// window — History loads the newest `historyLoadLimit` commits, and a blame
/// of an old file reaches far past them (most of git/git's).
public nonisolated enum FileInspectorLink: Equatable, Sendable {
    case selectInHistory(oid: String)
    case openChanges(CommitChangesTarget)

    public static func resolve(
        oid: String, subject: String, repositoryPath: String, loaded: Set<String>
    ) -> FileInspectorLink {
        loaded.contains(oid)
            ? .selectInHistory(oid: oid)
            : .openChanges(CommitChangesTarget(repositoryPath: repositoryPath, oid: oid, subject: subject))
    }
}

/// One line of the blame view, with its gutter text worked out off the main
/// actor.
public nonisolated struct BlameRow: Identifiable, Equatable, Sendable {
    /// The commit a run of lines came from, shown on the run's first line.
    public struct Commit: Equatable, Sendable {
        /// Full oid; `nil` for lines not committed yet.
        public let oid: String?
        /// Seven characters, or "" for uncommitted lines.
        public let shortOid: String
        /// The author, or "Not Committed Yet".
        public let author: String
        /// The author date, relative to the time the rows were made.
        public let date: String
        public let summary: String

        public init(oid: String?, shortOid: String, author: String, date: String, summary: String) {
            self.oid = oid
            self.shortOid = shortOid
            self.author = author
            self.date = date
            self.summary = summary
        }
    }

    /// The line number in the file as blamed, 1-based.
    public let id: Int
    public let content: String
    /// Set on the first line of each run of consecutive lines from one
    /// commit; `nil` on the rest, which draw an empty gutter.
    public let commit: Commit?
    /// Counts runs from 0, so the view can shade alternate runs.
    public let run: Int

    public init(id: Int, content: String, commit: Commit?, run: Int) {
        self.id = id
        self.content = content
        self.commit = commit
        self.run = run
    }
}

public nonisolated enum BlameRows {
    /// Rows for `lines`, in order. One formatter for the whole file.
    public static func make(_ lines: [BlameLine], now: Date) -> [BlameRow] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        var rows: [BlameRow] = []
        rows.reserveCapacity(lines.count)
        var previousOid: String?
        var run = -1
        for line in lines {
            var commit: BlameRow.Commit?
            if line.oid != previousOid {
                run += 1
                previousOid = line.oid
                let date = Date(timeIntervalSince1970: TimeInterval(line.authorTime))
                commit = line.isUncommitted
                    ? BlameRow.Commit(oid: nil, shortOid: "", author: "Not Committed Yet",
                                      date: "", summary: "")
                    : BlameRow.Commit(oid: line.oid, shortOid: String(line.oid.prefix(7)),
                                      author: line.author,
                                      date: formatter.localizedString(for: date, relativeTo: now),
                                      summary: line.summary)
            }
            rows.append(BlameRow(id: line.finalLine, content: line.content, commit: commit, run: run))
        }
        return rows
    }
}

public nonisolated enum FileHistoryRowText {
    /// "<7-char oid> · <author> · <relative date>".
    public static func caption(for entry: FileHistory.Entry, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(entry.authorTime))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "\(entry.oid.prefix(7)) · \(entry.author) · \(formatter.localizedString(for: date, relativeTo: now))"
    }

    /// "Renamed from <old>", "Added", "Deleted", or `nil` for an edit.
    public static func change(for entry: FileHistory.Entry) -> String? {
        switch entry.status {
        case "R": entry.previousPath.map { "Renamed from \($0)" }
        case "C": entry.previousPath.map { "Copied from \($0)" }
        case "A": "Added"
        case "D": "Deleted"
        default: nil
        }
    }
}

/// The inspector's History: the commits that changed the file, following
/// renames. `@concurrent` keeps `git log` and its parsing off the main
/// actor; cancelling the view's task stops `git`.
@concurrent
public func loadFileHistory(at path: String, target: FileInspectorTarget) async throws -> [FileHistory.Entry] {
    try await FileHistory.run(path: path, file: target.historyPath, revision: target.historyRevision)
}

/// The inspector's Blame, as rows ready to draw. `@concurrent` keeps
/// `git blame`, the parse and the row text off the main actor — about
/// 2,800 lines for git/git's `builtin/log.c`.
@concurrent
public func loadBlameRows(at path: String, target: FileInspectorTarget, now: Date = Date()) async throws -> [BlameRow] {
    let lines: [BlameLine] = try await blameFile(at: path, file: target.path, revision: target.revision)
    return BlameRows.make(lines, now: now)
}
