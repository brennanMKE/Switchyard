// RefSnapshot.swift — capture and restore of a repository's refs and HEAD (#0027)

import Foundation

/// A point-in-time capture of every direct ref plus this worktree's `HEAD`.
/// The first journal snapshot primitive: refs are a list of name/OID pairs
/// read with `git for-each-ref`, and restore writes the whole list back
/// through `git update-ref --stdin`, one transaction, so a partial
/// application of the ref list is impossible.
///
/// Restore does **not** delete refs the snapshot did not record: the
/// repository matches the snapshot **except** for refs created since the
/// capture, which restore leaves untouched. **Guide §11 decision 20**
/// (2026-08-17, on #0231): restore previously deleted every direct ref
/// absent from the snapshot, so a branch or tag a sibling worktree created
/// after the checkpoint was removed silently — no refusal, nothing in the
/// report. What that gave up, and what this type comment used to promise,
/// is that the repository would match the snapshot exactly.
///
/// Three git behaviors, all measured on 2.50.1, dictate the shape:
///
/// - **Every `--stdin` command aimed at `HEAD` needs `option no-deref`.**
///   The commands dereference symrefs by default, so while on a branch,
///   `symref-update HEAD refs/heads/main` writes *through* `HEAD` and turns
///   `refs/heads/main` into a symref pointing at itself — after which the
///   repository reports `No commits yet` and every ref lookup dies. Without
///   no-deref, `update HEAD <oid>` likewise moves the current branch instead
///   of detaching.
///
/// - **`HEAD` cannot ride in the refs transaction.** A transaction touching
///   both `HEAD` and the branch it points at — which restore routinely must,
///   because the agent is standing on some branch — fails with `multiple
///   updates for 'HEAD' (including one via its referent '<ref>') are not
///   allowed`, with or without no-deref. So restore is two transactions:
///   `HEAD` first, alone, then every other ref in one atomic batch.
///
/// - **Symbolic refs other than `HEAD` are not captured.** `for-each-ref`
///   lists `refs/remotes/origin/HEAD` in every cloned repository, and writing
///   its resolved OID back alongside its referent's is the same
///   multiple-updates fatal — restore would fail in any clone. A symbolic ref
///   is repository furniture, not operation state the journal moves, so
///   capture drops entries whose `%(symref)` field is non-empty and restore's
///   deletion planning skips them for the same reason.
public struct RefSnapshot: Sendable, Equatable {

    /// The tool's own ref namespace: journal anchors (#0028) and every other
    /// piece of switchyard machinery live under it. Excluded from capture,
    /// and never deleted by restore as an "extra" ref: a snapshot that
    /// carried journal anchor refs would, on restore, delete the anchor
    /// keeping *itself* reachable — after which ordinary maintenance reclaims
    /// the snapshot being restored. `ServiceNames.journalRefPrefix` (YardKit,
    /// which the engine does not import) must stay inside this namespace —
    /// pinned by `RefSnapshotNamespaceTests` in `YardWireTests`.
    public static let switchyardNamespace = "refs/switchyard/"

    /// This worktree's `HEAD`. Per-worktree state: capture and restore act on
    /// the worktree the `WorktreeContext` was resolved for.
    public enum Head: Sendable, Equatable {
        /// On a branch: `HEAD` is a symref to `target`, e.g. `refs/heads/main`.
        case symbolic(target: String)
        /// Detached: `HEAD` holds `oid` directly.
        case detached(oid: String)
    }

    /// One direct ref: full name (`refs/heads/main`) and the object id it
    /// points at. For an annotated tag this is the tag object's id, which is
    /// what restore must write back.
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let oid: String

        public init(name: String, oid: String) {
            self.name = name
            self.oid = oid
        }
    }

    public let head: Head
    public let refs: [Entry]

    /// The three namespaces that are **per-worktree** despite starting with
    /// `refs/`. Measured: `for-each-ref` lists them under plain names and only
    /// in the worktree that owns them, so a snapshot taken in one worktree
    /// carries another's private refs — and restoring it elsewhere would both
    /// create them there and delete that worktree's own as "extras".
    ///
    /// Same-worktree restore must NOT filter these: they are exactly the state
    /// an in-progress bisect or rebase needs back.
    public static let perWorktreeNamespaces = [
        "refs/worktree/", "refs/bisect/", "refs/rewritten/",
    ]

    /// This snapshot with every per-worktree ref removed, for applying in a
    /// worktree other than the one that captured it (#0175).
    public var withoutPerWorktreeRefs: RefSnapshot {
        RefSnapshot(head: head, refs: refs.filter { entry in
            !Self.perWorktreeNamespaces.contains { entry.name.hasPrefix($0) }
        })
    }

    public init(head: Head, refs: [Entry]) {
        self.head = head
        self.refs = refs
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A `for-each-ref` line did not parse. Thrown rather than skipped:
        /// silently dropping a ref from a snapshot is silent data loss on
        /// restore, the exact failure the journal exists to prevent.
        case malformedRefLine(_ line: String)

        public var description: String {
            switch self {
            case let .malformedRefLine(line):
                "unparseable for-each-ref output line: \(line)"
            }
        }
    }

    // MARK: - Capture

    /// Captures every direct ref and this worktree's `HEAD`.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> RefSnapshot {
        let base = context.topLevel ?? context.gitDir
        return RefSnapshot(
            head: try captureHead(at: base, git: git),
            refs: try listDirectRefs(at: base, git: git)
        )
    }

    /// Async twin of `capture(in:git:)` (#0344), for callers already on
    /// Swift concurrency's cooperative pool: the `symbolic-ref`, `rev-parse`
    /// and `for-each-ref` subprocesses are awaited on the non-blocking
    /// `GitProcess` path, so the pool thread is released while git runs.
    /// Same calls in the same order, same parse, same `Error` values.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) async throws -> RefSnapshot {
        let base = context.topLevel ?? context.gitDir
        return RefSnapshot(
            head: try await captureHead(at: base, git: git),
            refs: try await listDirectRefs(at: base, git: git)
        )
    }

    private static func captureHead(at base: String, git: GitProcess) throws -> Head {
        // Exit 1 with empty output means detached — information, not failure.
        let symref = try git.capture(
            ["symbolic-ref", "--quiet", "HEAD"], workingDirectory: base)
        if symref.exitCode == 0, let target = symref.lines.first, !target.isEmpty {
            return .symbolic(target: target)
        }
        let oid = try git.run(
            ["rev-parse", "--verify", "HEAD"], workingDirectory: base)
        guard let line = oid.lines.first, !line.isEmpty else {
            throw Error.malformedRefLine("rev-parse --verify HEAD printed nothing")
        }
        return .detached(oid: line)
    }

    private static func captureHead(at base: String, git: GitProcess) async throws -> Head {
        // Exit 1 with empty output means detached — information, not failure.
        let symref = try await git.capture(
            ["symbolic-ref", "--quiet", "HEAD"], workingDirectory: base)
        if symref.exitCode == 0, let target = symref.lines.first, !target.isEmpty {
            return .symbolic(target: target)
        }
        let oid = try await git.run(
            ["rev-parse", "--verify", "HEAD"], workingDirectory: base)
        guard let line = oid.lines.first, !line.isEmpty else {
            throw Error.malformedRefLine("rev-parse --verify HEAD printed nothing")
        }
        return .detached(oid: line)
    }

    /// Every ref that is not a symref and not journal machinery.
    ///
    /// Ref names cannot contain space, NUL, or newline (git-check-ref-format),
    /// so the space-separated three-field format parses unambiguously: a
    /// direct ref's `%(symref)` is empty and its line ends `name` + space.
    private static func listDirectRefs(at base: String, git: GitProcess) throws -> [Entry] {
        let out = try git.run(
            ["for-each-ref", "--format=%(objectname) %(refname) %(symref)"],
            workingDirectory: base)
        var entries: [Entry] = []
        for line in out.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedRefLine(line)
            }
            guard fields[2].isEmpty else { continue } // symbolic — not captured
            let name = String(fields[1])
            guard !name.hasPrefix(switchyardNamespace) else { continue }
            // Review-decision notes (#0059) are engine bookkeeping the same way
            // journal refs are: a snapshot that captured `refs/notes
            // /switchyard-review` would, on restore, roll the recorded decisions
            // back to an older state. Notes do not change commit SHAs, so
            // leaving this ref untouched on restore is exactly right — the
            // decisions survive the undo.
            guard !name.hasPrefix(ReviewNotes.refNamespace) else { continue }
            entries.append(Entry(name: name, oid: String(fields[0])))
        }
        return entries
    }

    private static func listDirectRefs(at base: String, git: GitProcess) async throws -> [Entry] {
        let out = try await git.run(
            ["for-each-ref", "--format=%(objectname) %(refname) %(symref)"],
            workingDirectory: base)
        var entries: [Entry] = []
        for line in out.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedRefLine(line)
            }
            guard fields[2].isEmpty else { continue } // symbolic — not captured
            let name = String(fields[1])
            guard !name.hasPrefix(switchyardNamespace) else { continue }
            // Review-decision notes: same exclusion as the sync path above (#0059).
            guard !name.hasPrefix(ReviewNotes.refNamespace) else { continue }
            entries.append(Entry(name: name, oid: String(fields[0])))
        }
        return entries
    }

    // MARK: - Restore

    /// Restores `HEAD` and then writes back every ref the snapshot recorded.
    /// A ref created since capture is left untouched — restore no longer
    /// deletes refs it did not record (guide §11 decision 20). The ref
    /// transaction is atomic: if any single update cannot apply, git rejects
    /// the batch and no ref moves.
    ///
    /// `HEAD` goes first, alone, per the type comment: git rejects a
    /// transaction that touches both `HEAD` and its referent, and restore
    /// routinely touches the branch `HEAD` is on. Retargeting `HEAD` toward a
    /// branch the refs transaction only re-creates a moment later is fine — a
    /// symref may dangle.
    public func restore(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let base = context.topLevel ?? context.gitDir

        // no-deref on both arms: these commands dereference HEAD by default,
        // and the dereferenced forms corrupt the current branch (type comment).
        let headCommands: String
        switch head {
        case let .symbolic(target):
            headCommands = "option no-deref\nsymref-update HEAD \(target)\n"
        case let .detached(oid):
            headCommands = "option no-deref\nupdate HEAD \(oid)\n"
        }
        try git.run(["update-ref", "--stdin"], workingDirectory: base,
                    standardInput: Data(headCommands.utf8))

        // Every recorded ref is written back. Anything not recorded — a
        // symref like origin/HEAD, the journal's own namespace, or a ref
        // created since capture — is never touched (guide §11 decision 20).
        var commands = ""
        for entry in refs {
            commands += "update \(entry.name) \(entry.oid)\n"
        }
        try git.run(["update-ref", "--stdin"], workingDirectory: base,
                    standardInput: Data(commands.utf8))
    }
}

// MARK: - §6 exit class (#0141)

/// Unparseable plumbing output is a repository-state failure — guide §6
/// code 6, same class as every other engine failure to read this repository.
extension RefSnapshot.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
