// SequencerSnapshot.swift — capture and restore an in-progress rebase (#0174)

import Foundation

/// The sequencer state of an interrupted rebase: the todo list, the done list,
/// the stopped sha, the original head.
///
/// **Refs alone do not make a rebase resumable.** `RefSnapshot` puts the refs
/// back where they were, but `git rebase --continue` reads this directory, and
/// without it there is no rebase to continue. Measured: removing the directory
/// leaves `HEAD detached` with no operation in progress; copying it back
/// byte-for-byte lets `--continue` run to completion.
///
/// The directory is self-contained — 15 files and ~44K in the measured case,
/// with no reference to anything outside it, unlike the split index (#0151).
/// So the capture unit is the whole directory and the restore is the whole
/// directory; nothing is reconstructed.
public struct SequencerSnapshot: Equatable, Sendable {

    /// The two layouts git uses: `rebase-merge` for the merge backend (the
    /// default and `--interactive`), `rebase-apply` for `--apply` and `git am`.
    public enum Layout: String, Equatable, Sendable, CaseIterable {
        case rebaseMerge = "rebase-merge"
        case rebaseApply = "rebase-apply"
    }

    public let layout: Layout
    /// A tree of the directory's files, empty ones included.
    public let tree: String
    /// `AUTO_MERGE`'s tree oid when present. It lives OUTSIDE the sequencer
    /// directory, beside `HEAD`. **Informational only** — `restore` never
    /// reads it, and a real conflicted rebase resumes with `git rebase
    /// --continue` even after `AUTO_MERGE` is deleted outright (measured,
    /// #0201). It needs no reachability path: losing it costs the three-way
    /// diff3 view tools can build from that tree, not resumability.
    public let autoMerge: String?

    public init(layout: Layout, tree: String, autoMerge: String?) {
        self.layout = layout
        self.tree = tree
        self.autoMerge = autoMerge
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case directoryUnreadable(path: String, detail: String)
        case restoreFailed(path: String, detail: String)
        case malformedPlumbingOutput(command: String)

        public var description: String {
            switch self {
            case let .directoryUnreadable(path, detail):
                "cannot read sequencer state at \(path): \(detail)"
            case let .restoreFailed(path, detail):
                "cannot restore sequencer state to \(path): \(detail)"
            case let .malformedPlumbingOutput(command):
                "\(command) printed no object id"
            }
        }
    }

    /// Captures the sequencer state, or nil when no rebase is in progress.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> SequencerSnapshot? {
        let base = context.topLevel ?? context.gitDir
        for layout in Layout.allCases {
            let directory = try context.path(for: layout.rawValue, git: git)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let tree = try buildTree(of: directory, at: base, git: git)
            var autoMerge: String?
            let autoMergePath = try context.path(for: "AUTO_MERGE", git: git)
            if let text = try? String(contentsOfFile: autoMergePath, encoding: .utf8) {
                let oid = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !oid.isEmpty { autoMerge = oid }
            }
            return SequencerSnapshot(layout: layout, tree: tree, autoMerge: autoMerge)
        }
        return nil
    }

    /// Restores the directory byte-for-byte, replacing whatever is there.
    ///
    /// **A partially restored sequencer is more dangerous than an absent one**,
    /// because `git rebase --continue` will act on it — so the tree is
    /// materialised into a sibling directory first and moved into place only
    /// once it is complete.
    public func restore(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let base = context.topLevel ?? context.gitDir
        let destination = try context.path(for: layout.rawValue, git: git)
        let staging = destination + ".switchyard-restoring"
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: staging) { try fm.removeItem(atPath: staging) }
            try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
            let listing = try git.run(["ls-tree", "-z", tree], workingDirectory: base)
            for record in listing.standardOutput.split(separator: 0) {
                guard let line = String(data: Data(record), encoding: .utf8),
                      let tab = line.firstIndex(of: "\t") else { continue }
                let name = String(line[line.index(after: tab)...])
                let fields = line[..<tab].split(separator: " ")
                guard fields.count >= 3 else { continue }
                let blob = String(fields[2])
                let bytes = try git.run(["cat-file", "blob", blob],
                                        workingDirectory: base).standardOutput
                try bytes.write(to: URL(fileURLWithPath: staging + "/" + name),
                                options: .atomic)
            }
            if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
            try fm.moveItem(atPath: staging, toPath: destination)
        } catch let error as GitProcess.Failure {
            throw error
        } catch {
            throw Error.restoreFailed(path: destination, detail: String(describing: error))
        }
    }

    /// Hashes every file in the directory — **including zero-byte ones**,
    /// whose mere existence is the state (`interactive`,
    /// `drop_redundant_commits`, `no-reschedule-failed-exec`, and
    /// `git-rebase-todo` once exhausted). Skipping them changes the rebase's
    /// behaviour without changing any content, which is the failure a careful
    /// reading misses.
    private static func buildTree(
        of directory: String, at base: String, git: GitProcess
    ) throws -> String {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            throw Error.directoryUnreadable(
                path: directory, detail: String(describing: error))
        }
        var lines = ""
        for name in names {
            let full = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: full))
            } catch {
                throw Error.directoryUnreadable(
                    path: full, detail: String(describing: error))
            }
            let blob = try singleOID(
                of: try git.run(["hash-object", "-w", "--stdin"],
                                workingDirectory: base, standardInput: data),
                command: "hash-object")
            lines += "100644 blob \(blob)\t\(name)\n"
        }
        return try singleOID(
            of: try git.run(["mktree"], workingDirectory: base,
                            standardInput: Data(lines.utf8)),
            command: "mktree")
    }

    private static func singleOID(
        of output: GitProcess.Output, command: String
    ) throws -> String {
        guard let oid = output.lines.first, !oid.isEmpty else {
            throw Error.malformedPlumbingOutput(command: command)
        }
        return oid
    }
}

extension SequencerSnapshot.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
