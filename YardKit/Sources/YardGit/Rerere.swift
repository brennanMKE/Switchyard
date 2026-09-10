// Rerere.swift — the read-only rerere surface (#0065)

import Foundation

/// What git's rerere has recorded, read from repository state — never by
/// running `git rerere` subcommands, none of which this round invokes.
///
/// Rerere's promise ("git can record how a conflict was resolved and replay
/// that resolution when the same conflict reappears") has a measured problem
/// for agents: after a replay, every `git rerere` text surface goes silent.
/// Measured (git 2.50.1) against a real fixture:
///
/// - First conflict: `git rerere status` prints the path, `git rerere diff`
///   prints the preimage-vs-working diff, `git rerere remaining` prints the
///   path, `.git/MERGE_RR` holds `<conflict-id>\t<path>` NUL-terminated, and
///   `.git/rr-cache/<conflict-id>/` holds `preimage` only. The merge prints
///   `Recorded preimage for 'f.txt'`.
/// - Resolve + commit: the commit prints `Recorded resolution for 'f.txt'.`;
///   afterwards `rr-cache/<conflict-id>/` holds `preimage` + `postimage`,
///   MERGE_RR is gone, and all three `git rerere` surfaces print nothing.
/// - Same conflict re-raised: the merge prints `Resolved 'f.txt' using
///   previous resolution.`, the working file already carries the recorded
///   resolution while the index STILL holds the unmerged stages — and
///   `git rerere status`, `diff`, and `remaining` all print nothing, because
///   MERGE_RR is emptied by the replay (measured: a zero-byte MERGE_RR) and
///   the path never reaches them. `rr-cache/<conflict-id>/` now holds
///   `preimage` + `postimage` + `thisimage`.
///
/// So this type reads the state the text surfaces do not show: the rr-cache
/// directories (each named for the conflict id — 40 hex for SHA-1
/// repositories, 64 for SHA-256), the MERGE_RR path mapping, and the
/// conflicted paths' working files. A conflict id's postimage existing is
/// what "recorded" means; preimage-only is "merely known". A live conflicted
/// path whose working file byte-equals a recorded postimage is a REPLAYED
/// resolution — the one state git itself prints nothing about after the
/// fact, and the one this type exists to report.
///
/// Read-only: `Rerere` never writes, never invokes `git rerere` in any form,
/// and never stages anything. Recording happens by git's own machinery at
/// the next rerere-aware operation (`git commit` measured above), never by
/// this code.
public enum Rerere {

    /// One conflict rerere knows about, as the rr-cache and MERGE_RR describe
    /// it. The rr-cache directory is the unit of "recorded"; `paths` and
    /// `replayedPaths` attach live conflicted paths where they can be
    /// attributed.
    public struct Entry: Sendable, Equatable {

        /// Whether a resolution is recorded, or the conflict merely known.
        public enum State: String, Sendable, Equatable {
            /// `rr-cache/<id>/postimage` exists — a resolution was recorded.
            case recorded
            /// `rr-cache/<id>/preimage` exists but no postimage — rerere saw
            /// this conflict and is waiting for a resolution to record.
            case known
        }

        /// The rr-cache directory name — the conflict id, as git computed it.
        public let conflictID: String

        /// Recorded vs merely known (see `State`).
        public let state: State

        /// Live conflicted paths attributed to this conflict id, sorted —
        /// from MERGE_RR (a first-time conflict git is tracking) and from the
        /// working-file match (a replay). Empty when no live conflict maps to
        /// this id, e.g. a resolution recorded by a past conflict.
        public let paths: [String]

        /// The subset of `paths` whose working file currently carries the
        /// recorded resolution — a replay that happened in this very conflict
        /// state and must be reported, never silent. Empty unless `state`
        /// is `.recorded`.
        public let replayedPaths: [String]

        public init(conflictID: String, state: State, paths: [String], replayedPaths: [String]) {
            self.conflictID = conflictID
            self.state = state
            self.paths = paths
            self.replayedPaths = replayedPaths
        }

        /// Stable wire keys, identical to the member names on purpose; no raw
        /// values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case conflictID, state, paths, replayedPaths
        }
    }

    /// The `rerere status` payload: whether rerere is enabled plus every
    /// conflict the rr-cache knows about.
    public struct Status: Sendable, Equatable {

        /// `rerere.enabled` in the repository's effective configuration —
        /// the repository's choice, never set by Switchyard.
        public let enabled: Bool

        /// One entry per rr-cache conflict id, sorted by id.
        public let entries: [Entry]

        public init(enabled: Bool, entries: [Entry]) {
            self.enabled = enabled
            self.entries = entries
        }

        /// Stable wire keys, identical to the member names on purpose.
        private enum CodingKeys: String, CodingKey {
            case enabled, entries
        }
    }

    /// One MERGE_RR record: a live conflicted path and the conflict id git
    /// tracks it under. A parse intermediate — the wire carries `Entry`.
    public struct TrackedPath: Equatable, Sendable {
        public let conflictID: String
        public let path: String

        public init(conflictID: String, path: String) {
            self.conflictID = conflictID
            self.path = path
        }
    }
}

// MARK: - Wire encoding

extension Rerere.Entry: Encodable {}
extension Rerere.Entry.State: Encodable {}
extension Rerere.Status: Encodable {}

// MARK: - Errors

/// Why a rerere read refused. Every case is repository-state damage the
/// caller must see, never an empty answer dressed up as one.
public enum RerereError: Error, Equatable, Sendable, CustomStringConvertible {
    /// MERGE_RR held a record that is not `<conflict-id>\t<path>` — a format
    /// this build does not know, or state damaged mid-operation. Parsed
    /// strictly, like every porcelain format in this engine: silently
    /// dropping a tracked path would hide exactly the state rerere keeps.
    case malformedMergeRR(detail: String)
    /// A directory in rr-cache whose name is not a conflict id — not git's
    /// layout, and guessing would misattribute resolutions to it.
    case unexpectedCacheEntry(name: String)
    /// A rerere state file exists but could not be read.
    case unreadableStateFile(name: String, detail: String)

    public var description: String {
        switch self {
        case let .malformedMergeRR(detail):
            "MERGE_RR did not parse as rerere's `<conflict-id>\t<path>` records: \(detail)"
        case let .unexpectedCacheEntry(name):
            "rr-cache holds a directory that is not a conflict id: \(name)"
        case let .unreadableStateFile(name, detail):
            "rerere state file \(name) could not be read: \(detail)"
        }
    }
}

extension RerereError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - The MERGE_RR parser

extension Rerere {

    /// Parses MERGE_RR's bytes: one `<conflict-id>\t<path>` record per
    /// conflicted path, NUL-terminated — measured verbatim from a fixture:
    ///
    /// ```
    /// 650b3bb115602e8f349398d8d6c560baaef932e3\tf.txt\0
    /// ```
    ///
    /// A zero-byte MERGE_RR parses as an empty array — that is the measured
    /// shape after a replay consumed the record, not a parse failure. The
    /// split is at the FIRST tab, so a path containing a tab survives; the
    /// id must be a conflict id (lowercase hex, at least 40 characters —
    /// SHA-1 repositories print 40, SHA-256 print 64). Anything else throws
    /// `.malformedMergeRR` rather than being skipped, because a dropped
    /// record is a dropped tracked conflict.
    public static func parseMergeRR(_ data: Data) throws -> [TrackedPath] {
        var tracked: [TrackedPath] = []
        for record in data.split(separator: 0x00, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09) else {
                throw RerereError.malformedMergeRR(
                    detail: "record has no tab separator: "
                        + String(decoding: record, as: UTF8.self))
            }
            let id = String(decoding: record[..<tab], as: UTF8.self)
            let pathBytes = record[record.index(after: tab)...]
            guard isConflictID(id), !pathBytes.isEmpty else {
                throw RerereError.malformedMergeRR(
                    detail: "record is not <conflict-id>\\t<path>: "
                        + String(decoding: record, as: UTF8.self))
            }
            tracked.append(TrackedPath(
                conflictID: id,
                path: String(decoding: pathBytes, as: UTF8.self)))
        }
        return tracked
    }

    /// Whether a string can be a conflict id: lowercase hex, at least the
    /// 40 characters a SHA-1 repository prints. 64 (SHA-256) also passes;
    /// anything shorter or non-hex is not git's layout.
    private static func isConflictID(_ name: String) -> Bool {
        !name.isEmpty && name.count >= 40 && name.allSatisfy { character in
            (character >= "a" && character <= "f") || (character >= "0" && character <= "9")
        }
    }
}

// MARK: - The public reads

extension Rerere {

    /// Whether `rerere.enabled` is set in the repository's effective
    /// configuration (system → global → local → worktree). Unset is `false`:
    /// git's default is disabled. A malformed value throws rather than
    /// reading as disabled — the repository's choice must not be flattened.
    public static func enabled(
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Bool {
        let context = try WorktreeContext.resolve(path: path, git: git)
        return try enabled(
            in: context.topLevel ?? context.gitDir,
            git: git, extraEnvironment: extraEnvironment)
    }

    /// The full read: what the rr-cache records, with live conflicted paths
    /// attributed where MERGE_RR or the working files allow it.
    ///
    /// The replay detection is the content match measured above: a conflicted
    /// index path whose working file byte-equals a recorded postimage. git
    /// wrote that postimage into the working file itself at merge time, so
    /// byte equality during a live conflict IS the replay; no text surface
    /// remains to parse, which is why the match is against the cache. When
    /// several postimages match, one whose directory also carries
    /// `thisimage` (the measured marker of the live replayed conflict)
    /// preferred, then the lowest id — deterministic, and the ambiguity is
    /// an id-level footnote, never a silently dropped path.
    public static func status(
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Status {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let base = context.topLevel ?? context.gitDir
        let isEnabled = try enabled(in: base, git: git, extraEnvironment: extraEnvironment)

        let cacheDir = try context.path(for: "rr-cache", git: git)
        let cache = try scanCache(cacheDir)

        let mergeRRPath = try context.path(for: "MERGE_RR", git: git)
        let tracked: [TrackedPath]
        if FileManager.default.fileExists(atPath: mergeRRPath) {
            do {
                tracked = try parseMergeRR(try Data(contentsOf: URL(fileURLWithPath: mergeRRPath)))
            } catch let error as RerereError {
                throw error
            } catch {
                throw RerereError.unreadableStateFile(
                    name: "MERGE_RR", detail: String(describing: error))
            }
        } else {
            tracked = []
        }

        // The content match only means something against live conflicted
        // paths — enumerate them once from the same index the caller sees.
        let conflicted = try conflictedFiles(at: base, git: git)
        let matched = replayedFiles(files: conflicted, topLevel: base, cache: cache)

        var entries: [Entry] = []
        for cached in cache {
            let mergePaths = tracked.filter { $0.conflictID == cached.id }.map(\.path)
            let replayPaths = matched.filter { $0.id == cached.id }.map(\.path)
            entries.append(Entry(
                conflictID: cached.id,
                state: cached.hasPostimage ? .recorded : .known,
                paths: Array(Set(mergePaths + replayPaths)).sorted(),
                replayedPaths: Array(Set(replayPaths)).sorted()))
        }
        // MERGE_RR records whose cache directory does not exist (the cache
        // was pruned under a live conflict): the tracked path is real, so
        // report it as merely known rather than dropping the record.
        let cachedIDs = Set(cache.map(\.id))
        for pair in tracked where !cachedIDs.contains(pair.conflictID) {
            entries.append(Entry(
                conflictID: pair.conflictID, state: .known,
                paths: [pair.path], replayedPaths: []))
        }
        entries.sort { $0.conflictID < $1.conflictID }
        return Status(enabled: isEnabled, entries: entries)
    }

    /// The paths, among `files`, whose working file currently carries a
    /// recorded resolution — the conflicts surface's `rerereReplayed` field.
    /// Empty when no conflict is live, which is the common case and the
    /// cheap exit.
    public static func replayedPaths(
        files: [ConflictedFile],
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> [String] {
        guard !files.isEmpty else { return [] }
        let context = try WorktreeContext.resolve(path: path, git: git)
        let base = context.topLevel ?? context.gitDir
        let cache = try scanCache(try context.path(for: "rr-cache", git: git))
        return replayedFiles(files: files, topLevel: base, cache: cache).map(\.path)
    }

    /// `rerere.enabled` against an already-resolved base, the one cheap
    /// `git config` read. Exit 0 parses; exit 1 (unset) is `false`; anything
    /// else is the failure it is — SigningConfig's pattern.
    private static func enabled(
        in base: String, git: GitProcess, extraEnvironment: [String: String]
    ) throws -> Bool {
        let arguments = ["config", "--type=bool", "--get", "rerere.enabled"]
        let output = try git.capture(
            arguments, workingDirectory: base, extraEnvironment: extraEnvironment)
        switch output.exitCode {
        case 0:
            return output.lines.first == "true"
        case 1:
            return false
        default:
            throw GitProcess.Failure.exited(
                code: output.exitCode, stderr: output.standardError, arguments: arguments)
        }
    }

    /// One rr-cache directory: the conflict id, what is cached for it, and
    /// the postimage bytes when a resolution is recorded.
    private struct CacheEntry {
        let id: String
        let hasPostimage: Bool
        let hasThisimage: Bool
        let postimage: Data?
    }

    /// Reads every conflict directory out of `cacheDir`. Plain files are not
    /// conflict ids and are ignored; a DIRECTORY that is not a conflict id is
    /// `.unexpectedCacheEntry` — git's layout has no such thing, and guessing
    /// what it means would misattribute a resolution.
    private static func scanCache(_ cacheDir: String) throws -> [CacheEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDir) else { return [] }
        var entries: [CacheEntry] = []
        for name in try fileManager.contentsOfDirectory(atPath: cacheDir).sorted() {
            let directoryURL = URL(fileURLWithPath: cacheDir).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard isConflictID(name) else {
                throw RerereError.unexpectedCacheEntry(name: name)
            }
            let postimageURL = directoryURL.appendingPathComponent("postimage")
            var postimage: Data?
            if fileManager.fileExists(atPath: postimageURL.path) {
                do {
                    postimage = try Data(contentsOf: postimageURL)
                } catch {
                    throw RerereError.unreadableStateFile(
                        name: "rr-cache/\(name)/postimage", detail: String(describing: error))
                }
            }
            let thisimage = fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent("thisimage").path)
            entries.append(CacheEntry(
                id: name,
                hasPostimage: postimage != nil,
                hasThisimage: thisimage,
                postimage: postimage))
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// The content match: live conflicted paths whose working file byte-equals
    /// a recorded postimage, each with the id whose postimage matched. See
    /// `status`'s doc comment for why byte equality against the postimage is
    /// the replay, measured.
    private static func replayedFiles(
        files: [ConflictedFile], topLevel: String, cache: [CacheEntry]
    ) -> [(path: String, id: String)] {
        let recorded = cache.filter { $0.postimage != nil }
        guard !recorded.isEmpty else { return [] }
        var matched: [(path: String, id: String)] = []
        for file in files {
            let workingURL = URL(fileURLWithPath: topLevel).appendingPathComponent(file.path)
            guard let workingBytes = try? Data(contentsOf: workingURL) else { continue }
            let candidates = recorded.filter { $0.postimage == workingBytes }
            guard let chosen = candidates.first(where: { $0.hasThisimage }) ?? candidates.first
            else { continue }
            matched.append((file.path, chosen.id))
        }
        return matched.sorted { $0.path < $1.path }
    }
}
