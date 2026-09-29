// WorktreeSnapshot.swift — capture and restore of this worktree's files (#0152)

import Foundation

/// A point-in-time capture of this worktree's files, restorable exactly —
/// the third journal snapshot primitive (git internals §3). Two real git
/// objects, both always present:
///
/// - **The stash-form commit** (`commit`): a parentless commit whose tree
///   is the worktree state of every tracked file — the same tree `git
///   stash` records as its working-tree commit. It is built with plumbing,
///   not `git stash create`, because `stash create` fails outright on an
///   unmerged index (measured: the stage lines plus `Cannot save the
///   current index state`, exit 1), and the unmerged case is the one M2's
///   exit criterion names. The plumbing form works there: `git add -u`
///   against a temporary *copy* of the index folds every tracked file's
///   worktree bytes in — collapsing conflict stages to the worktree's
///   conflict-marker bytes, which is exactly what a worktree capture wants
///   — and `write-tree` then succeeds where it refuses the unmerged
///   original. The commit rides the anchor's `keepAlive` parents (#0028)
///   and maps to `captured.worktree: "stash"` (#0155). Author, committer,
///   and dates are pinned, so an unchanged worktree captures to the same
///   oid and costs nothing new.
///
/// - **The untracked tree** (`untrackedTree`): every untracked non-ignored
///   file, staged into a fresh temporary index and written as a tree — the
///   explicit capture git internals §3 requires, since no stash-form tree
///   carries untracked files. The empty tree when there are none, never
///   nil: "no untracked files existed" is a fact restore must be able to
///   re-establish, not an absence of information.
///
/// Ignored files are in neither object and are never written or deleted by
/// restore — guide §11 decision 3: excluding them is what keeps "capture
/// everything, always" affordable, and build outputs must not ride the
/// journal.
///
/// **Both objects hold raw worktree bytes (#0473).** `add -u` and
/// `update-index --add` hash through git's clean filter (`core.autocrlf`,
/// `text`/`eol`, `filter=`, `ident`, `working-tree-encoding`), and
/// `checkout-index` writes through the smudge filter, so a file whose bytes
/// are not a fixed point of `smudge(clean(x))` used to come back changed.
/// Capture re-hashes every path a conversion could touch with
/// `hash-object --no-filters`; restore re-hashes what `checkout-index`
/// wrote and overwrites any file that differs with the blob's raw bytes. A
/// path no conversion touches is stored exactly as before. The commit
/// carries a `Switchyard-Worktree-Bytes: raw` trailer; a commit without it
/// predates #0473, holds clean-filter output, and restores through the
/// smudge filter as it always did.
///
/// Capture never touches the real index, the worktree, or any ref. Every
/// index-mutating command aims at a temporary index via `GIT_INDEX_FILE` —
/// and the copy is load-bearing, not hygiene: `add -u` against the real
/// index would *resolve the user's conflict*, because staging a path
/// collapses its stages (measured). Nothing here writes `refs/stash` or any
/// other ref, so the journal's own guard and ref scans never see a capture.
///
/// Restore is deliberately destructive within its scope, mirroring
/// `IndexSnapshot`: it overwrites every captured path with its captured
/// bytes and deletes every non-ignored path that exists now but did not at
/// capture. Nothing is refused here — the safety story belongs to the
/// composing flow (#0168): the cross-tool guard refuses divergence, and the
/// pre-restore checkpoint records the state being replaced before anything
/// is written. The real index is never touched either way — restoring it is
/// `IndexSnapshot`'s job, sequenced by #0171. Directories left empty by a
/// deletion are kept; git tracks no directories, so an empty one is
/// invisible to status.
///
/// Like the other snapshot primitives, no lock is taken here: #0171
/// composes capture and restore inside `JournalLock.withLock`.
public struct WorktreeSnapshot: Sendable, Equatable {

    /// The stash-form commit: its tree is the worktree state of every
    /// tracked file, conflict markers and intent-to-add contents included.
    public let commit: String

    /// The tree of untracked non-ignored files; the empty tree when none
    /// existed at capture.
    public let untrackedTree: String

    public init(commit: String, untrackedTree: String) {
        self.commit = commit
        self.untrackedTree = untrackedTree
    }

    /// This capture as the entry metadata records it — always `.stash`; the
    /// `false` case is the caller's (an entry carrying no `WorktreeSnapshot`
    /// at all). "Stash" names the *artifact* — a stash-form worktree-state
    /// commit — not `git stash`: no commit `git stash apply` accepts can
    /// exist for an unmerged index, because the index half of a true stash
    /// commit is exactly what `write-tree` refuses to build there.
    public var captured: JournalEntryMetadata.WorktreeCapture { .stash }

    /// The `captured.untracked` value for an entry carrying this snapshot —
    /// always true: the untracked tree is captured even when empty.
    public var capturedUntracked: Bool { true }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// The index file exists but could not be copied for the tracked
        /// capture.
        case indexFileUnreadable(path: String, detail: String)
        /// A plumbing command printed nothing where a single OID was
        /// required.
        case malformedPlumbingOutput(command: String)
        /// Restore could not delete a file that did not exist at capture.
        case worktreeFileUnremovable(path: String, detail: String)
        /// Restore could not write a file's captured raw bytes (#0473).
        case worktreeFileUnwritable(path: String, detail: String)
        /// The repository is bare: there is no worktree to capture or
        /// restore.
        case noWorktree(gitDir: String)

        public var description: String {
            switch self {
            case let .indexFileUnreadable(path, detail):
                "cannot read index file \(path): \(detail)"
            case let .malformedPlumbingOutput(command):
                "\(command) printed no object id"
            case let .worktreeFileUnremovable(path, detail):
                "cannot remove worktree file \(path): \(detail)"
            case let .worktreeFileUnwritable(path, detail):
                "cannot write worktree file \(path): \(detail)"
            case let .noWorktree(gitDir):
                "repository at \(gitDir) has no worktree"
            }
        }
    }

    // MARK: - Capture

    /// Captures this worktree's files without modifying the repository.
    ///
    /// The tracked tree is seeded from a copy of the real index — never
    /// from `HEAD`, which would silently drop staged-new and intent-to-add
    /// files: both are invisible to `ls-files --others` (measured, #0151
    /// Given 6), so nothing downstream could recover them. `add -u` then
    /// records worktree modifications *and deletions* into the copy, and
    /// captures an intent-to-add file's real bytes (measured), closing the
    /// silent-loss case #0151 flagged.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> WorktreeSnapshot {
        guard let base = context.topLevel else {
            throw Error.noWorktree(gitDir: context.gitDir)
        }
        let indexPath = try context.path(for: "index", git: git)
        let trackedIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-worktree-\(UUID().uuidString)")
        let untrackedIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-untracked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: trackedIndex)
            try? FileManager.default.removeItem(at: untrackedIndex)
        }

        // The tracked side: the sanctioned index-file copy (#0151's
        // exception, reused for the same reason — the copy is the moment
        // being captured). A repository with no index file yet reads as an
        // empty index below (measured in #0151).
        if FileManager.default.fileExists(atPath: indexPath) {
            do {
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: indexPath), to: trackedIndex)
            } catch {
                throw Error.indexFileUnreadable(
                    path: indexPath, detail: String(describing: error))
            }
        }
        let trackedEnvironment = ["GIT_INDEX_FILE": trackedIndex.path]
        try git.run(["add", "-u"],
                    workingDirectory: base, extraEnvironment: trackedEnvironment)
        try overlayRawBytes(base: base, environment: trackedEnvironment, git: git)
        let tree = try singleOID(
            of: try git.run(["write-tree"],
                            workingDirectory: base,
                            extraEnvironment: trackedEnvironment),
            command: "write-tree")
        let commit = try singleOID(
            of: try git.run(["commit-tree", tree,
                             "-m", "switchyard worktree snapshot",
                             "-m", Self.rawBytesTrailer],
                            workingDirectory: base,
                            extraEnvironment: Self.commitEnvironment),
            command: "commit-tree")

        // The untracked side: list against the REAL index — untracked means
        // not tracked by the worktree's actual index — and stage into a
        // fresh temporary one. `write-tree` against a still-absent index
        // file prints the empty tree (measured), which is the "none
        // existed" capture.
        let others = try git.run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            workingDirectory: base)
        let untrackedEnvironment = ["GIT_INDEX_FILE": untrackedIndex.path]
        if !others.standardOutput.isEmpty {
            try git.run(["update-index", "--add", "-z", "--stdin"],
                        workingDirectory: base,
                        standardInput: others.standardOutput,
                        extraEnvironment: untrackedEnvironment)
            try overlayRawBytes(base: base, environment: untrackedEnvironment, git: git)
        }
        let untracked = try singleOID(
            of: try git.run(["write-tree"],
                            workingDirectory: base,
                            extraEnvironment: untrackedEnvironment),
            command: "write-tree")

        return WorktreeSnapshot(commit: commit, untrackedTree: untracked)
    }

    // MARK: - Restore

    /// Applies the capture to this worktree's files: every captured path is
    /// rewritten with its captured bytes, and every non-ignored path
    /// present now but absent from the capture is deleted. The real index
    /// is untouched; restored files simply read as modified against it,
    /// which is what they are until `IndexSnapshot` restores its half.
    ///
    /// The union of both trees is read into one temporary index —
    /// `read-tree` peels the stash-form commit, `update-index --index-info`
    /// accepts `ls-tree -r -z` output verbatim (both measured), and the two
    /// path sets are disjoint by construction — then `checkout-index -a -f`
    /// writes every file, creating directories as needed and overwriting
    /// what moved on (measured). The deletion scope is computed from the
    /// real index and the real exclude rules *before* anything is written,
    /// so an ignored file is never deleted and a captured file never reads
    /// as extraneous.
    public func restore(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        guard let base = context.topLevel else {
            throw Error.noWorktree(gitDir: context.gitDir)
        }
        let restoreIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: restoreIndex) }
        let environment = ["GIT_INDEX_FILE": restoreIndex.path]

        // What exists now, before anything is rewritten: tracked paths from
        // the real index plus untracked non-ignored paths. Ignored files
        // are outside the scope entirely, so restore can never touch them.
        let tracked = try git.run(["ls-files", "-z"], workingDirectory: base)
        let others = try git.run(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            workingDirectory: base)
        let currentPaths = Self.nulSeparated(tracked.standardOutput)
            .union(Self.nulSeparated(others.standardOutput))

        // The union index: tracked tree, then the untracked entries.
        try git.run(["read-tree", commit],
                    workingDirectory: base, extraEnvironment: environment)
        let untrackedListing = try git.run(
            ["ls-tree", "-r", "-z", untrackedTree], workingDirectory: base)
        if !untrackedListing.standardOutput.isEmpty {
            try git.run(["update-index", "-z", "--index-info"],
                        workingDirectory: base,
                        standardInput: untrackedListing.standardOutput,
                        extraEnvironment: environment)
        }
        try git.run(["checkout-index", "-a", "-f"],
                    workingDirectory: base, extraEnvironment: environment)

        if try Self.holdsRawBytes(commit: commit, base: base, git: git) {
            try Self.rewriteRawBytes(base: base, environment: environment, git: git)
        }

        // Delete what the capture did not contain. A path listed by the
        // real index but already gone from disk is a no-op, caught by the
        // not-found catch rather than a pre-check so a broken symlink is
        // still removed.
        let snapshotPaths = Self.nulSeparated(
            try git.run(["ls-files", "-z"],
                        workingDirectory: base,
                        extraEnvironment: environment).standardOutput)
        for path in currentPaths.subtracting(snapshotPaths).sorted() {
            let absolute = base + "/" + path
            do {
                try FileManager.default.removeItem(atPath: absolute)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                throw Error.worktreeFileUnremovable(
                    path: absolute, detail: String(describing: error))
            }
        }
    }

    // MARK: - Raw bytes (#0473)

    /// The trailer on a snapshot commit whose blobs hold raw worktree bytes.
    /// A commit without it was captured before #0473, through the clean
    /// filter; restore leaves those to `checkout-index` alone, exactly as
    /// they were restored when they were written.
    static let rawBytesTrailer = "Switchyard-Worktree-Bytes: raw"

    /// Every attribute git's conversion layer consults (`crlf` is the legacy
    /// spelling of `text`). A path with all of these unspecified or unset,
    /// under `core.autocrlf` off, is stored byte-for-byte by `add` already.
    static let conversionAttributes =
        ["crlf", "ident", "filter", "eol", "text", "working-tree-encoding"]

    /// One stage-0 regular-file entry of a temporary index. The path stays
    /// as bytes so it round-trips into `update-index` unchanged.
    private struct Entry {
        let mode: String
        let oid: String
        let path: Data
    }

    /// Capture half: `add -u` and `update-index --add` hash through the
    /// clean filter. For every path a conversion could apply to, re-hash the
    /// file with `--no-filters` and point the temporary index at that blob
    /// instead. A path no conversion touches is never re-read, so its blob —
    /// and the tree — is exactly what it was before #0473.
    private static func overlayRawBytes(
        base: String, environment: [String: String], git: GitProcess
    ) throws {
        let entries = try regularFileEntries(
            base: base, environment: environment, git: git)
        guard !entries.isEmpty else { return }
        let candidates = try conversionCandidates(
            entries.map(\.path), base: base, environment: environment, git: git)
        let hashed = entries.filter { candidates.contains($0.path) }
        guard !hashed.isEmpty else { return }
        let raw = try rawHashes(
            of: hashed.map(\.path), write: true, base: base, git: git)
        var info = Data()
        for (entry, oid) in zip(hashed, raw) where oid != entry.oid {
            info.append(Data("\(entry.mode) \(oid) 0\t".utf8))
            info.append(entry.path)
            info.append(0)
        }
        guard !info.isEmpty else { return }
        try git.run(["update-index", "-z", "--index-info"],
                    workingDirectory: base,
                    standardInput: info,
                    extraEnvironment: environment)
    }

    /// Restore half: `checkout-index` wrote every file through the smudge
    /// filter. Re-hash every regular file it wrote with `--no-filters` and
    /// overwrite the ones whose bytes are not the captured blob. Every file,
    /// not only conversion candidates: the attributes in force now need not
    /// be the ones in force at capture.
    private static func rewriteRawBytes(
        base: String, environment: [String: String], git: GitProcess
    ) throws {
        let entries = try regularFileEntries(
            base: base, environment: environment, git: git)
        guard !entries.isEmpty else { return }
        let written = try rawHashes(
            of: entries.map(\.path), write: false, base: base, git: git)
        let stale = zip(entries, written).filter { $0.1 != $0.0.oid }.map(\.0)
        guard !stale.isEmpty else { return }
        let request = Data(stale.map { "\($0.oid)\n" }.joined().utf8)
        let batch = try git.run(["cat-file", "--batch"],
                                workingDirectory: base,
                                standardInput: request).standardOutput
        // `--batch` output: `<oid> blob <size>` LF, the bytes, LF — in
        // request order.
        var cursor = batch.startIndex
        for entry in stale {
            guard let newline = batch[cursor...].firstIndex(of: 0x0A) else {
                throw Error.malformedPlumbingOutput(command: "cat-file --batch")
            }
            let header = String(decoding: batch[cursor..<newline], as: UTF8.self)
                .split(separator: " ")
            let start = batch.index(after: newline)
            guard header.count == 3, header[1] == "blob",
                  let size = Int(header[2]),
                  batch.distance(from: start, to: batch.endIndex) > size else {
                throw Error.malformedPlumbingOutput(command: "cat-file --batch")
            }
            let end = batch.index(start, offsetBy: size)
            let path = base + "/" + String(decoding: entry.path, as: UTF8.self)
            try overwrite(path, with: Data(batch[start..<end]))
            cursor = batch.index(after: end)
        }
    }

    /// Whether `commit` was captured with raw bytes: its message carries
    /// `rawBytesTrailer`.
    private static func holdsRawBytes(
        commit: String, base: String, git: GitProcess
    ) throws -> Bool {
        try git.run(["cat-file", "commit", commit], workingDirectory: base)
            .text.contains("\n\(rawBytesTrailer)\n")
    }

    /// Stage-0 `100644`/`100755` entries of the index `environment` names.
    /// Symlinks and gitlinks are skipped: neither has filterable content,
    /// and hashing a symlink's path would read its target.
    private static func regularFileEntries(
        base: String, environment: [String: String], git: GitProcess
    ) throws -> [Entry] {
        let listing = try git.run(["ls-files", "-s", "-z"],
                                  workingDirectory: base,
                                  extraEnvironment: environment).standardOutput
        return listing.split(separator: 0).compactMap { record in
            guard let tab = record.firstIndex(of: 0x09) else { return nil }
            let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self)
                .split(separator: " ")
            guard fields.count == 3, fields[2] == "0",
                  fields[0] == "100644" || fields[0] == "100755" else { return nil }
            return Entry(mode: String(fields[0]), oid: String(fields[1]),
                         path: Data(record[record.index(after: tab)...]))
        }
    }

    /// The subset of `paths` a content conversion could change: any
    /// conversion attribute set, or `core.autocrlf` on and the path not
    /// marked binary.
    private static func conversionCandidates(
        _ paths: [Data], base: String, environment: [String: String],
        git: GitProcess
    ) throws -> Set<Data> {
        var input = Data()
        for path in paths {
            input.append(path)
            input.append(0)
        }
        let output = try git.run(["check-attr", "-z", "--stdin"] + conversionAttributes,
                                 workingDirectory: base,
                                 standardInput: input,
                                 extraEnvironment: environment).standardOutput
        // `-z` output: path NUL attribute NUL value NUL, once per attribute.
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        var attributes: [Data: [String: String]] = [:]
        for i in stride(from: 0, to: fields.count - 2, by: 3) {
            attributes[Data(fields[i]), default: [:]][
                String(decoding: fields[i + 1], as: UTF8.self)] =
                String(decoding: fields[i + 2], as: UTF8.self)
        }
        let autocrlf = try autocrlfEnabled(base: base, git: git)
        return Set(paths.filter {
            needsRawCapture(attributes[$0] ?? [:], autocrlf: autocrlf)
        })
    }

    /// The conversion predicate, over `check-attr` values (`set`, `unset`,
    /// `unspecified`, or a value). Conservative: an attribute git would
    /// ignore still counts, because a false positive costs one extra hash
    /// and a false negative is the #0473 bug.
    static func needsRawCapture(_ attributes: [String: String], autocrlf: Bool) -> Bool {
        let active = conversionAttributes.contains {
            let value = attributes[$0] ?? "unspecified"
            return value != "unspecified" && value != "unset"
        }
        if active { return true }
        let binary = attributes["text"] == "unset" || attributes["crlf"] == "unset"
        return autocrlf && !binary
    }

    /// `core.autocrlf` as git reads it: `input` or any true boolean is on;
    /// absent or any false boolean is off.
    private static func autocrlfEnabled(base: String, git: GitProcess) throws -> Bool {
        let result = try git.capture(["config", "--get", "core.autocrlf"],
                                     workingDirectory: base)
        guard result.exitCode == 0 else { return false }
        let value = result.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["false", "no", "off", "0", ""].contains(value)
    }

    /// The raw-byte blob oid of each path, via one `hash-object --no-filters
    /// --stdin-paths`. Every path is C-quoted, which that command unquotes,
    /// so a newline, quote, backslash or trailing CR in a name survives.
    private static func rawHashes(
        of paths: [Data], write: Bool, base: String, git: GitProcess
    ) throws -> [String] {
        var input = Data()
        for path in paths {
            input.append(0x22)
            for byte in path {
                switch byte {
                case 0x22: input.append(contentsOf: [0x5C, 0x22])
                case 0x5C: input.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: input.append(contentsOf: [0x5C, 0x6E])
                default: input.append(byte)
                }
            }
            input.append(contentsOf: [0x22, 0x0A])
        }
        let arguments = ["hash-object", "--no-filters", "--stdin-paths"]
            + (write ? ["-w"] : [])
        let lines = try git.run(arguments, workingDirectory: base,
                                standardInput: input).lines
        guard lines.count == paths.count else {
            throw Error.malformedPlumbingOutput(command: "hash-object")
        }
        return lines
    }

    /// Overwrites an existing regular file in place — same inode, so the
    /// mode `checkout-index` just set is kept.
    private static func overwrite(_ path: String, with bytes: Data) throws {
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: bytes)
        } catch {
            throw Error.worktreeFileUnwritable(
                path: path, detail: String(describing: error))
        }
    }

    // MARK: - Plumbing helpers

    /// Pinned identity and dates: a snapshot commit's oid is a pure
    /// function of its tree, so an unchanged worktree deduplicates to zero
    /// new objects across checkpoints. `commit-tree` does not consult
    /// `commit.gpgsign` (measured, #0028), so snapshot commits are never
    /// signed.
    static let commitEnvironment = [
        "GIT_AUTHOR_NAME": "switchyard",
        "GIT_AUTHOR_EMAIL": "journal@switchyard.invalid",
        "GIT_COMMITTER_NAME": "switchyard",
        "GIT_COMMITTER_EMAIL": "journal@switchyard.invalid",
        "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
        "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
    ]

    private static func singleOID(
        of output: GitProcess.Output, command: String
    ) throws -> String {
        guard let oid = output.lines.first, !oid.isEmpty else {
            throw Error.malformedPlumbingOutput(command: command)
        }
        return oid
    }

    /// NUL-separated plumbing output (`-z`) as a path set; `-z` because
    /// agent-generated paths will eventually contain something awkward.
    private static func nulSeparated(_ data: Data) -> Set<String> {
        Set(data.split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) })
    }
}

// MARK: - §6 exit class (#0141)

/// Every case is a repository-state failure — guide §6 code 6, the same
/// class as the other snapshot primitives' failures.
extension WorktreeSnapshot.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
