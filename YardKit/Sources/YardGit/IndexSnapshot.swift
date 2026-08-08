// IndexSnapshot.swift — capture and restore of this worktree's index (#0151)

import Foundation

/// A point-in-time capture of this worktree's index, restorable exactly —
/// the second journal snapshot primitive (git internals §3). The index is
/// per-worktree state, resolved through `WorktreeContext.path(for: "index")`,
/// never by concatenating onto `.git/`.
///
/// Two capture forms, matching the entry metadata's wire values
/// (`JournalEntryMetadata.IndexCapture`: `"tree"` / `"raw"`) and the anchor
/// tree-entry names (#0028: `index` / `index.raw`):
///
/// - **`.tree`** — the ordinary case. The index is copied to a temporary
///   file and `git write-tree` runs against the copy via `GIT_INDEX_FILE`,
///   so the real index is never touched. Measured: a *successful*
///   `write-tree` writes a cache-tree extension back into its index file,
///   which is why capture must never aim it at the real one.
///
/// - **`.raw`** — the index file's own bytes, stored as a blob. This is the
///   one place in the project where reading a git file directly is correct,
///   because the file *is* the state (CLAUDE.md): `git write-tree` refuses
///   an unmerged index outright (measured: the stage lines plus
///   `fatal: git-write-tree: error building trees`, exit 128), and a tree
///   cannot carry per-entry index flags at all. The blob round-trips
///   byte-for-byte (measured: `hash-object -w` → `cat-file blob` → `cmp`,
///   identical).
///
/// The raw form is taken whenever a tree would lose something, each trigger
/// measured on git 2.50.1:
///
/// - **Unmerged entries.** `ls-files -v` tags them `M`, and `write-tree`
///   refuses them.
/// - **`skip-worktree` and `assume-unchanged` flags** (`S` / lowercase
///   tags). A tree round trip silently clears them — measured: `S sw.txt`
///   became `H sw.txt` — and a cleared skip-worktree bit in a sparse
///   checkout reads as mass deletion.
/// - **Intent-to-add entries.** `write-tree` *succeeds* and silently drops
///   them from the tree (measured: the entry present in `ls-files -s`,
///   absent from `ls-tree -r`), so success alone does not prove the tree is
///   faithful; the entry-count comparison catches what the flag probe and
///   the exit code both miss.
///
/// A split index (`git update-index --split-index`) is normalized before
/// either form: the raw link file references `sharedindex.<sha>`, which git
/// prunes on its own schedule, and a blob of the link alone dangles once it
/// does (measured: `fatal: … index file open failed`, exit 128). Running
/// `update-index --no-split-index` against the *copy* merges the shared
/// entries in — conflict stages preserved, real index untouched — and is a
/// byte-identical no-op on a non-split copy (both measured), so the ordinary
/// byte-for-byte claim survives normalization.
///
/// Like `RefSnapshot`, this primitive takes no lock: the composing flows
/// (#0171) run it inside `JournalLock.withLock`.
public enum IndexSnapshot: Sendable, Equatable {

    /// A plain merged index, captured as the tree `write-tree` built from
    /// the temporary copy. Deduplicates against existing objects — an index
    /// matching `HEAD` costs nothing new — and stays valid as long as the
    /// anchor holds it reachable.
    case tree(oid: String)

    /// The index file's bytes as a blob, self-contained (split form merged),
    /// restored byte-for-byte.
    case raw(blob: String)

    /// This capture as the entry metadata records it — the `false` case is
    /// the caller's (an entry that carries no `IndexSnapshot` at all).
    public var captured: JournalEntryMetadata.IndexCapture {
        switch self {
        case .tree: .tree
        case .raw: .raw
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// The index file exists but could not be copied or read.
        case indexFileUnreadable(path: String, detail: String)
        /// A raw restore could not write the index file back.
        case indexFileUnwritable(path: String, detail: String)
        /// A plumbing command printed nothing where a single OID was
        /// required.
        case malformedPlumbingOutput(command: String)

        public var description: String {
            switch self {
            case let .indexFileUnreadable(path, detail):
                "cannot read index file \(path): \(detail)"
            case let .indexFileUnwritable(path, detail):
                "cannot write index file \(path): \(detail)"
            case let .malformedPlumbingOutput(command):
                "\(command) printed no object id"
            }
        }
    }

    // MARK: - Capture

    /// Captures this worktree's index without modifying it.
    ///
    /// A repository whose index file does not exist yet (fresh `git init`)
    /// reads as empty everywhere below — measured: `ls-files -v` prints
    /// nothing and `write-tree` prints the empty tree, both exit 0 — so it
    /// captures as `.tree` of the empty tree with no special case.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> IndexSnapshot {
        let base = context.topLevel ?? context.gitDir
        let indexPath = try context.path(for: "index", git: git)
        let workCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workCopy) }
        let environment = ["GIT_INDEX_FILE": workCopy.path]

        // The one sanctioned direct read of a `$GIT_DIR` file: the copy is
        // the moment being captured, and every probe below runs against it,
        // so the decision and the captured bytes cannot describe different
        // states of the index.
        var snapshotBytes: Data?
        if FileManager.default.fileExists(atPath: indexPath) {
            do {
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: indexPath), to: workCopy)
            } catch {
                throw Error.indexFileUnreadable(
                    path: indexPath, detail: String(describing: error))
            }
            // Normalize a split index into its self-contained form on the
            // copy (byte-identical no-op otherwise, measured) — a blob of
            // the split link file would dangle when git prunes
            // sharedindex.<sha>. Reads the shared file from the real
            // repository via `-C`.
            try git.run(["update-index", "--no-split-index"],
                        workingDirectory: base, extraEnvironment: environment)
            do {
                snapshotBytes = try Data(contentsOf: workCopy)
            } catch {
                throw Error.indexFileUnreadable(
                    path: workCopy.path, detail: String(describing: error))
            }
        }

        // Raw trigger 1: any entry not plainly cached. `M` is an unmerged
        // stage (one line per stage, measured), `S`/lowercase are
        // skip-worktree and assume-unchanged flags a tree cannot carry.
        let flags = try git.run(["ls-files", "-v"],
                                workingDirectory: base, extraEnvironment: environment)
        if flags.lines.allSatisfy({ $0.hasPrefix("H ") }) {
            // Raw trigger 2: write-tree refuses (the unmerged fatal, and
            // any refusal a future git adds — falling back is always safe,
            // so no output parsing decides this).
            let written = try git.capture(["write-tree"],
                                          workingDirectory: base,
                                          extraEnvironment: environment)
            if written.exitCode == 0, let tree = written.lines.first, !tree.isEmpty {
                // Raw trigger 3: the tree must carry every entry.
                // write-tree succeeds while silently dropping intent-to-add
                // entries (measured), so the entry counts are compared —
                // write-tree can only omit, never invent, and both listings
                // quote special characters into single lines.
                let inIndex = try git.run(["ls-files", "-s"],
                                          workingDirectory: base,
                                          extraEnvironment: environment)
                let inTree = try git.run(["ls-tree", "-r", tree],
                                         workingDirectory: base)
                if inIndex.lines.count == inTree.lines.count {
                    return .tree(oid: tree)
                }
            }
        }

        guard let snapshotBytes else {
            // Unreachable: a missing index file is empty, and an empty index
            // has no flags, no refusal, and no dropped entries.
            throw Error.indexFileUnreadable(
                path: indexPath, detail: "no index file to snapshot")
        }
        let hashed = try git.run(["hash-object", "-w", "--stdin"],
                                 workingDirectory: base,
                                 standardInput: snapshotBytes)
        guard let blob = hashed.lines.first, !blob.isEmpty else {
            throw Error.malformedPlumbingOutput(command: "hash-object")
        }
        return .raw(blob: blob)
    }

    // MARK: - Restore

    /// Applies the capture to this worktree's index.
    ///
    /// - `.tree` restores through `git read-tree`, which writes under git's
    ///   own `index.lock` protocol and replaces an unmerged index without
    ///   complaint (measured: exit 0 over a three-stage conflict, entry
    ///   list identical to the capture). The restored entries carry no stat
    ///   cache, so the next status re-stats the worktree — slower once,
    ///   never wrong.
    ///
    /// - `.raw` writes the blob's bytes back to the index file atomically:
    ///   `Data.write(options: .atomic)` stages into a temporary file and
    ///   renames it into place, so no reader ever sees a partial index. The
    ///   worktree is untouched either way; entries whose files moved on
    ///   simply read as modified, which is what they are.
    public func restore(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let base = context.topLevel ?? context.gitDir
        switch self {
        case let .tree(oid):
            try git.run(["read-tree", oid], workingDirectory: base)
        case let .raw(blob):
            let bytes = try git.run(["cat-file", "blob", blob],
                                    workingDirectory: base).standardOutput
            let indexPath = try context.path(for: "index", git: git)
            do {
                try bytes.write(
                    to: URL(fileURLWithPath: indexPath), options: .atomic)
            } catch {
                throw Error.indexFileUnwritable(
                    path: indexPath, detail: String(describing: error))
            }
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Every case is a repository-state failure — guide §6 code 6, the same
/// class as the other snapshot primitives' failures.
extension IndexSnapshot.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
