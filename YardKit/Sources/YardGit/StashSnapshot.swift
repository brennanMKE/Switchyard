// StashSnapshot.swift — the stash list as a journal piece (#0490)

import Foundation

/// The repository's stash list — every entry of `refs/stash`'s reflog,
/// newest first — captured by every journal checkpoint and put back by
/// every restore (guide §11 decision 36).
///
/// **Why refs alone are not enough.** A stash entry is a *reflog* entry,
/// not a ref: `stash@{1}` exists only as the second line of
/// `refs/stash`'s reflog. `RefSnapshot` records `refs/stash`'s oid and
/// nothing else, so, measured on git 2.54.0 (#0490):
///
/// - dropping `stash@{1}` leaves `refs/stash` where it was, so restoring
///   refs changes nothing and the entry stays gone;
/// - dropping `stash@{0}` and writing `refs/stash` back with `update-ref`
///   brings the oid back as a new reflog line with an **empty message**
///   (`stash@{0}: `);
/// - a stash pushed onto an empty list creates `refs/stash`, and a restore
///   leaves a ref its snapshot did not record (decision 20), so the stash
///   survives its own Undo.
///
/// So the list is its own piece: a blob of `<oid> <message>` lines in the
/// anchor tree (`JournalAnchor.stashTreeEntryName`), every oid a keep-alive
/// parent so a dropped stash stays reachable, and a restore that rebuilds
/// the reflog when the list differs.
///
/// **Rebuilding, not patching.** `git update-ref -d refs/stash` removes the
/// ref and its whole reflog (measured); then one `update-ref
/// --create-reflog -m <message> refs/stash <oid>` per entry, oldest first,
/// lays the lines back down in order. `git stash store` was rejected: it
/// refuses a commit that is not stash-like (`fatal: … is not a stash-like
/// commit`, exit 128), and a refusal halfway through would leave the list
/// half rebuilt. `update-ref -m ""` is refused (`fatal: Refusing to
/// perform update with empty message.`), so an empty message is written
/// with no `-m`, which records an empty message (measured). Reflog
/// timestamps become the restore's; `stash list` shows none, and the UI
/// dates an entry by its commit, which does not change.
///
/// Messages cannot hold a newline or a tab: git collapses both to a space
/// when it writes a reflog line (measured: `-m $'a\nb'` lists as `a b`).
public struct StashSnapshot: Sendable, Equatable {

    /// The ref whose reflog is the stash list.
    public static let ref = "refs/stash"

    /// One stash entry: the stash commit and its reflog message, which is
    /// what `git stash list` prints after `stash@{n}: `.
    public struct Entry: Sendable, Equatable {
        public let oid: String
        public let message: String

        public init(oid: String, message: String) {
            self.oid = oid
            self.message = message
        }
    }

    /// Newest first: `entries[n]` is `stash@{n}`.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// A listing or serialized line did not parse. Thrown, never
        /// skipped: a stash dropped from a snapshot is a stash an Undo
        /// cannot bring back.
        case malformedLine(String)

        public var description: String {
            switch self {
            case let .malformedLine(line): "unparseable stash line: \(line)"
            }
        }
    }

    // MARK: - Capture

    /// The live stash list. `git stash list` prints nothing, exit 0, when
    /// `refs/stash` does not exist (measured), where `git reflog show
    /// refs/stash` fails with exit 128. `--no-show-signature` keeps a
    /// user's `log.showSignature` out of the output.
    public static func capture(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> StashSnapshot {
        let base = context.topLevel ?? context.gitDir
        let output = try git.run(
            ["stash", "list", "--no-show-signature", "--format=%H%x00%gs"],
            workingDirectory: base)
        return StashSnapshot(entries: try output.lines.map { line in
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].count >= 40 else { throw Error.malformedLine(line) }
            return Entry(oid: String(fields[0]), message: String(fields[1]))
        })
    }

    // MARK: - Serialization

    /// `<oid> <message>\n` per entry, newest first. An empty list is an
    /// empty blob, which is not the same as no blob: it records that there
    /// were no stashes, so a restore removes any made since.
    public func serialized() -> Data {
        Data(entries.map { "\($0.oid) \($0.message)\n" }.joined().utf8)
    }

    public init(serialized data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        var entries: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].count >= 40 else {
                throw Error.malformedLine(String(line))
            }
            entries.append(Entry(oid: String(fields[0]), message: String(fields[1])))
        }
        self.entries = entries
    }

    // MARK: - Restore

    /// Makes the live stash list equal this one. Returns `false`, having
    /// run nothing but the capture, when it already is.
    @discardableResult
    public func restore(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Bool {
        let current = try Self.capture(in: context, git: git)
        guard current != self else { return false }
        let base = context.topLevel ?? context.gitDir
        if !current.entries.isEmpty {
            try git.run(["update-ref", "-d", Self.ref], workingDirectory: base)
        }
        for entry in entries.reversed() {
            let message = entry.message.isEmpty ? [] : ["-m", entry.message]
            try git.run(["update-ref", "--create-reflog"] + message + [Self.ref, entry.oid],
                        workingDirectory: base)
        }
        return true
    }
}

// MARK: - §6 exit class (#0141)

/// An unparseable stash listing is a repository-state failure — guide §6
/// code 6, the class `RefSnapshot.Error` carries for the same reason.
extension StashSnapshot.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
