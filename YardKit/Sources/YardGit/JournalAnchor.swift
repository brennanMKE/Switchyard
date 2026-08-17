// JournalAnchor.swift — journal entry ids, the snapshot entry commit, and its anchor ref (#0028)

import Foundation

/// A journal entry identifier: 26 characters of Crockford base32 — a 48-bit
/// millisecond timestamp followed by 80 random bits, the ULID layout.
///
/// Three properties carry the journal's ref design:
///
/// - **Lexicographic order is creation order.** Fixed length, and the
///   alphabet ascends in ASCII, so plain string comparison — and the default
///   refname sort of `git for-each-ref` — lists entries oldest-first with no
///   metadata read at all.
/// - **Every id is a valid ref-name component.** Digits and uppercase
///   letters only, nothing `git check-ref-format` objects to, and no
///   case-only collisions on a case-insensitive filesystem.
/// - **Generation is monotonic when told what came before.** Two ids minted
///   in the same millisecond would otherwise order by their random bits;
///   `generate(now:after:)` increments the previous id instead — the ULID
///   monotonic rule — so ascent is strict, not probable.
public struct JournalEntryID: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// Crockford base32: no I, L, O, or U. Strictly ascending in ASCII,
    /// which is what makes string order equal numeric order.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Character → value, for validation and the increment carry.
    static let alphabetIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    /// 10 timestamp characters plus 16 random ones.
    public static let length = 26

    /// The 26-character canonical form. Also the last component of the
    /// entry's anchor ref name.
    public let string: String

    public var description: String { string }

    /// Parses an id, returning nil unless it is exactly 26 Crockford-base32
    /// characters whose leading character is 0–7 — a 48-bit timestamp cannot
    /// set the two high bits of the first character.
    public init?(_ string: String) {
        guard string.count == Self.length,
              string.allSatisfy({ Self.alphabetIndex[$0] != nil }),
              let first = string.first, "01234567".contains(first)
        else { return nil }
        self.string = string
    }

    /// Only `generate` and `incremented` may bypass validation, with
    /// characters drawn from the alphabet.
    private init(unchecked: String) {
        self.string = unchecked
    }

    public static func < (lhs: JournalEntryID, rhs: JournalEntryID) -> Bool {
        lhs.string < rhs.string
    }

    // MARK: - Generation

    /// Mints an id for `now`, strictly greater than `previous` when one is
    /// given. Callers writing journal entries pass the newest existing id so
    /// that same-millisecond writes — and a clock stepping backwards — still
    /// produce ascending ids rather than randomly ordered ones.
    public static func generate(
        now: Date = Date(),
        after previous: JournalEntryID? = nil
    ) -> JournalEntryID {
        let millis = UInt64(max(0, now.timeIntervalSince1970) * 1000.0)
        var characters: [Character] = []
        characters.reserveCapacity(length)
        // 10 characters hold 50 bits; a 48-bit timestamp leaves the top two
        // zero, which is the 0–7 constraint on the first character.
        for slot in stride(from: 9, through: 0, by: -1) {
            characters.append(alphabet[Int((millis >> UInt64(slot * 5)) & 0x1F)])
        }
        for _ in 0..<16 {
            characters.append(alphabet[Int.random(in: 0..<32)])
        }
        let candidate = JournalEntryID(unchecked: String(characters))
        guard let previous, candidate.string <= previous.string else { return candidate }
        return previous.incremented()
    }

    /// This id plus one, as a 130-bit base32 number with carry. Overflow —
    /// all 26 characters at Z — cannot occur before the 48-bit timestamp
    /// exhausts in the year 10889; if it somehow did, the unchanged id is
    /// returned and the collision surfaces as `write`'s refused `create`
    /// rather than as a replaced entry.
    func incremented() -> JournalEntryID {
        var characters = Array(string)
        for position in stride(from: characters.count - 1, through: 0, by: -1) {
            let value = Self.alphabetIndex[characters[position]] ?? 0
            if value < Self.alphabet.count - 1 {
                characters[position] = Self.alphabet[value + 1]
                return JournalEntryID(unchecked: String(characters))
            }
            characters[position] = Self.alphabet[0]
        }
        return self
    }
}

/// Journal anchor refs and the snapshot entry commit they point at (#0028).
///
/// Objects unreferenced by any ref are garbage. Every journal entry is one
/// commit — the *snapshot commit* — anchored by one ref, `refPrefix` plus
/// the entry id, and everything the entry must keep alive is reachable from
/// that commit:
///
/// - **Its tree** carries the entry's pieces by fixed name: `metadata.json`
///   (always), and optionally the serialized ref-state blob, the index tree
///   (or the raw index blob when unmerged), and the untracked-files tree.
/// - **Its parents** are the `keepAlive` commits — the worktree stash commit
///   and any history the captured refs point at. A commit can only reach
///   another commit through parenthood: a tree cannot hold one (a gitlink
///   confers no reachability), so keep-alive rides in the parent list.
///
/// Deleting the anchor releases the whole entry: the objects become
/// unreachable and ordinary maintenance reclaims them (measured — see
/// #0028's Givens). `switchyard` itself never runs `git gc`.
///
/// The namespace lives outside `refs/heads` and `refs/tags`, so entries
/// never appear in branch listings and are never pushed by a default
/// refspec (`git push`, `--all`, and `--tags` all measured clean; only
/// `--mirror` carries them). It sits inside `RefSnapshot.switchyardNamespace`,
/// so a ref-state restore can neither capture an anchor nor delete one.
///
/// Every ref write here goes through `GitProcess`, which marks its
/// environment with `GitProcess.markerVariable` on every invocation — the
/// `reference-transaction` hook (#0042) uses that marker to skip the
/// journal's own transactions instead of recording itself recording itself.
public enum JournalAnchor {

    /// The journal's ref namespace: `journal/` inside the namespace
    /// `RefSnapshot` already excludes from capture and restore. The full
    /// literal must not appear in this file — equality is pinned by a wire
    /// test, and a literal scan across every other Swift source verifies it.
    public static let refPrefix = RefSnapshot.switchyardNamespace + "journal/"

    /// The anchor ref for an entry id.
    public static func refName(for id: JournalEntryID) -> String {
        refPrefix + id.string
    }

    /// Tree-entry name of the metadata blob inside every snapshot commit.
    /// `git cat-file blob <anchor-ref>:metadata.json` is the whole recovery
    /// path from refs alone (#0030), so this name is wire contract.
    public static let metadataTreeEntryName = "metadata.json"

    /// Tree-entry names for the optional snapshot pieces. As much wire
    /// contract as the metadata name: #0030's rebuild and undo's restore
    /// address pieces by these.
    public static let refsTreeEntryName = "refs"
    public static let indexTreeEntryName = "index"
    public static let indexBlobTreeEntryName = "index.raw"
    public static let untrackedTreeEntryName = "untracked"
    /// Tree OID of the sequencer state snapshot, if captured. The directory
    /// is stored as a single tree object; the layout (rebase-merge vs
    /// rebase-apply) is recorded in metadata.captured.sequencer.
    public static let sequencerTreeEntryName = "sequencer"

    /// What one entry stores. Piece OIDs are produced by the snapshot
    /// primitives (#0027, #0151, #0152) and arrive here opaque; `write`
    /// stores whichever are present.
    public struct Contents: Sendable, Equatable {
        /// Entry metadata bytes, stored verbatim as the `metadata.json`
        /// blob. This type does not interpret them; the shape is #0153's.
        public var metadataJSON: Data
        /// Blob OID of the serialized ref state, if captured.
        public var refsBlob: String?
        /// Tree OID of the index snapshot, if the index was merged.
        public var indexTree: String?
        /// Blob OID of the raw index file, when conflicts made
        /// `write-tree` impossible (internals §3).
        public var indexBlob: String?
        /// Tree OID of the untracked-files snapshot, if captured.
        public var untrackedTree: String?
        /// Tree OID of the sequencer state snapshot, if captured.
        public var sequencerTree: String?
        /// Commit OIDs the entry must keep reachable — the stash commit and
        /// captured history tips. Written as the snapshot commit's parents.
        public var keepAlive: [String]

        public init(
            metadataJSON: Data,
            refsBlob: String? = nil,
            indexTree: String? = nil,
            indexBlob: String? = nil,
            untrackedTree: String? = nil,
            sequencerTree: String? = nil,
            keepAlive: [String] = []
        ) {
            self.metadataJSON = metadataJSON
            self.refsBlob = refsBlob
            self.indexTree = indexTree
            self.indexBlob = indexBlob
            self.untrackedTree = untrackedTree
            self.sequencerTree = sequencerTree
            self.keepAlive = keepAlive
        }
    }

    /// One anchored entry: its id and the snapshot commit its ref points at.
    public struct Entry: Sendable, Equatable {
        public let id: JournalEntryID
        public let commit: String

        public init(id: JournalEntryID, commit: String) {
            self.id = id
            self.commit = commit
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A ref under the journal namespace whose last component is not a
        /// valid entry id. Thrown rather than skipped: silently ignoring a
        /// ref in the journal's own namespace would let pruning and rebuild
        /// disagree about what exists.
        case foreignRef(String)
        /// A plumbing command printed something unparseable where a single
        /// OID or a `<oid> <refname>` line was required.
        case malformedPlumbingOutput(command: String, line: String)

        public var description: String {
            switch self {
            case let .foreignRef(name):
                "ref in the journal namespace is not a journal entry: \(name)"
            case let .malformedPlumbingOutput(command, line):
                "unparseable \(command) output line: \(line)"
            }
        }
    }

    /// The identity journal commits are written under. Fixed so a snapshot
    /// never depends on the user's ident configuration: with
    /// `user.useConfigOnly=true` and no ident, a bare `commit-tree` fails
    /// (measured, exit 128), and an env-supplied identity always works.
    static let commitEnvironment = [
        "GIT_AUTHOR_NAME": "switchyard",
        "GIT_AUTHOR_EMAIL": "journal@switchyard.invalid",
        "GIT_COMMITTER_NAME": "switchyard",
        "GIT_COMMITTER_EMAIL": "journal@switchyard.invalid",
    ]

    // MARK: - Writing

    /// Builds the snapshot commit for `contents` and anchors it at
    /// `refName(for: id)`. The anchor is written with `update-ref --stdin`'s
    /// `create`, which refuses an existing ref (measured: exit 128,
    /// `reference already exists`) — an id collision surfaces as a thrown
    /// `GitProcess.Failure`, never as a silently replaced entry.
    @discardableResult
    public static func write(
        _ contents: Contents,
        id: JournalEntryID,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Entry {
        let base = context.topLevel ?? context.gitDir

        let metadataBlob = try singleOID(
            of: try git.run(["hash-object", "-w", "--stdin"],
                            workingDirectory: base,
                            standardInput: contents.metadataJSON),
            command: "hash-object")

        // mktree accepts entries in any order and sorts them itself
        // (measured). Ref names, OIDs, and these fixed entry names contain
        // no tab or newline, so the line format cannot be corrupted.
        var treeLines = "100644 blob \(metadataBlob)\t\(metadataTreeEntryName)\n"
        if let oid = contents.refsBlob {
            treeLines += "100644 blob \(oid)\t\(refsTreeEntryName)\n"
        }
        if let oid = contents.indexTree {
            treeLines += "040000 tree \(oid)\t\(indexTreeEntryName)\n"
        }
        if let oid = contents.indexBlob {
            treeLines += "100644 blob \(oid)\t\(indexBlobTreeEntryName)\n"
        }
        if let oid = contents.untrackedTree {
            treeLines += "040000 tree \(oid)\t\(untrackedTreeEntryName)\n"
        }
        if let oid = contents.sequencerTree {
            treeLines += "040000 tree \(oid)\t\(sequencerTreeEntryName)\n"
        }
        let tree = try singleOID(
            of: try git.run(["mktree"], workingDirectory: base,
                            standardInput: Data(treeLines.utf8)),
            command: "mktree")

        // Parents are the keep-alive set. git itself ignores a duplicate
        // parent (measured: warning, exit 0), and a non-commit OID is a
        // clean fatal (measured: exit 128), so neither needs pre-checking.
        // commit-tree does not consult commit.gpgsign (measured: identical
        // OIDs with it set and unset), so snapshot commits are never signed.
        var commitArguments = ["commit-tree", tree,
                               "-m", "switchyard journal entry \(id.string)"]
        for parent in contents.keepAlive {
            commitArguments += ["-p", parent]
        }
        let commit = try singleOID(
            of: try git.run(commitArguments, workingDirectory: base,
                            extraEnvironment: commitEnvironment),
            command: "commit-tree")

        try git.run(["update-ref", "--stdin"], workingDirectory: base,
                    standardInput: Data("create \(refName(for: id)) \(commit)\n".utf8))
        return Entry(id: id, commit: commit)
    }

    // MARK: - Reading

    /// Every entry, oldest first. `for-each-ref` sorts by refname and ids
    /// are fixed-length with creation-ordered strings, so its default order
    /// is creation order — no metadata is read. Anchor refs are shared
    /// (nothing under `refs/` outside `refs/bisect`, `refs/worktree`, and
    /// `refs/rewritten` is per-worktree), so every worktree sees one list.
    public static func list(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [Entry] {
        let base = context.topLevel ?? context.gitDir
        let output = try git.run(
            ["for-each-ref", "--format=%(objectname) %(refname)", refPrefix],
            workingDirectory: base)
        var entries: [Entry] = []
        for line in output.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedPlumbingOutput(command: "for-each-ref", line: line)
            }
            let name = String(fields[1])
            guard name.hasPrefix(refPrefix),
                  let id = JournalEntryID(String(name.dropFirst(refPrefix.count)))
            else {
                throw Error.foreignRef(name)
            }
            entries.append(Entry(id: id, commit: String(fields[0])))
        }
        return entries
    }

    /// The entry's metadata bytes, exactly as written. Reads
    /// `<anchor-ref>:metadata.json` through `cat-file`, which is the same
    /// path #0030's rebuild uses — the repository alone suffices.
    public static func metadata(
        for id: JournalEntryID,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Data {
        let base = context.topLevel ?? context.gitDir
        let output = try git.run(
            ["cat-file", "blob", refName(for: id) + ":" + metadataTreeEntryName],
            workingDirectory: base)
        return output.standardOutput
    }

    // MARK: - Deleting

    /// Removes the entry's anchor, releasing its objects to ordinary
    /// maintenance. Guarded: the delete names the commit the caller believes
    /// is anchored, so a concurrently replaced or already-pruned entry is a
    /// thrown failure (measured: exit 1 on mismatch and on a missing ref),
    /// never a blind deletion.
    public static func delete(
        _ entry: Entry,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let base = context.topLevel ?? context.gitDir
        try git.run(["update-ref", "-d", refName(for: entry.id), entry.commit],
                    workingDirectory: base)
    }

    // MARK: - Plumbing output

    /// The single OID a plumbing command must print, or a thrown error.
    private static func singleOID(
        of output: GitProcess.Output,
        command: String
    ) throws -> String {
        guard let line = output.lines.first, !line.isEmpty else {
            throw Error.malformedPlumbingOutput(command: command, line: "")
        }
        return line
    }
}

// MARK: - §6 exit class (#0141)

/// Both cases are repository-state failures — guide §6 code 6: a foreign ref
/// squatting in the journal namespace, or plumbing output this git did not
/// produce in the shape the engine requires.
extension JournalAnchor.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
