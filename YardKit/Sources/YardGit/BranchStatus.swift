// BranchStatus.swift — per-branch ahead/behind and merged state for the
// sidebar's local branch rows (#0372).
//
// Guide §11 decision 27 (2026-09-13, on #0373) defines both terms:
//
// - **Ahead/behind = A3.** Against the branch's upstream when one is set —
//   `%(upstream:track)`'s numbers, the same meaning `whereAmI` reports for
//   `HEAD` — else against the default branch. The row carries which baseline
//   it is showing, because the two readings differ: ahead of the upstream
//   returns to 0 on push, while ahead of the default never returns to 0
//   after a squash landing.
// - **Merged = M6, the composite.** `merged` by ancestry when the branch's
//   tip is reachable from the default branch (M1 — `%(ahead-behind:<default>)`'s
//   ahead count 0); else `merged` when the upstream reads `[gone]` (M4, the
//   delete-branch-on-merge hosting workflow's signature); else the content
//   check — `git merge-tree --write-tree <default> <branch>` — answers
//   `merged` when it yields the default branch's tree and `not merged` when
//   it does not (M3, the only candidate that recognises a squash landing of
//   any size), and a conflict answer is `unknown`. M1's "not merged" is
//   never final: ahead > 0 against the default is exactly the squash
//   false-negative the composite exists to repair, so it means "keep
//   looking".
//
// The default branch is `refs/remotes/origin/HEAD`'s symbolic target with
// its remote prefix stripped, falling back to the literal `main`, read with
// one `git symbolic-ref refs/remotes/origin/HEAD`. A per-repository setting
// is rejected until a repository is found where `origin/HEAD` is wrong.
//
// Cost budget, same decision: the synchronous sidebar-load read is **one
// `for-each-ref` process** carrying `%(upstream:track)` and
// `%(ahead-behind:<default>)` together (plus the one `symbolic-ref` that
// names `<default>`) — never one process per branch. Measured on git
// 2.50.1: 30 ms on 122 branches, 53 ms on 309. The M3 content check is a
// **background pass** of per-branch `merge-tree` spawns that fills the
// merged column after the sidebar appears — measured 7.7 s for 309
// branches, far over any sidebar-load budget, which is why it must not run
// on the load path.
//
// One measured degradation: git fatals the whole `for-each-ref` enumeration
// (exit 128, "failed to find '<default>'") when the ahead-behind argument
// does not resolve — a repository with no local branch of the default
// name. The read retries once without the atom on that path: rows keep
// their `%(upstream:track)` numbers, lose the default-relative ones, and
// M6 loses its ancestry input (rows answer gone-or-unknown).

import Foundation

/// Per-branch ahead/behind (A3) and merged state (M6) for local branches,
/// as guide §11 decision 27 defines them. See the file comment.
public enum BranchStatus {

    /// Which branch the A3 numbers are measured against. `.upstream` carries
    /// the upstream's full ref name (`refs/remotes/origin/main`, or a local
    /// `refs/heads/…` upstream); `.defaultBranch` carries the default
    /// branch's name. `displayName` is the row-facing short form.
    public enum Baseline: Sendable, Equatable {
        case upstream(String)
        case defaultBranch(String)

        /// The name the row shows: remote-tracking and local prefixes
        /// stripped (`refs/remotes/origin/main` → `origin/main`,
        /// `refs/heads/main` → `main`).
        public var displayName: String {
            switch self {
            case let .upstream(refName): Self.shortRefName(refName)
            case let .defaultBranch(name): Self.shortRefName(name)
            }
        }

        static func shortRefName(_ refName: String) -> String {
            if refName.hasPrefix("refs/remotes/") {
                return String(refName.dropFirst("refs/remotes/".count))
            }
            if refName.hasPrefix("refs/heads/") {
                return String(refName.dropFirst("refs/heads/".count))
            }
            return refName
        }
    }

    /// Which M6 rule answered "merged" — ancestry (M1), a deleted upstream
    /// (M4), or the content check (M3).
    public enum MergedBy: Sendable, Equatable {
        case ancestry
        case upstreamGone
        case content
    }

    /// The M6 composite answer for one branch.
    public enum MergedState: Sendable, Equatable {
        case merged(by: MergedBy)
        case notMerged
        case unknown
    }

    /// One local branch's status.
    public struct Row: Sendable, Equatable {
        /// The branch's full ref name, `refs/heads/<name>`.
        public let ref: String

        /// The upstream's full ref name when one is set, else `nil`.
        public let upstream: String?

        /// True when `%(upstream:track)` read `[gone]` — the upstream was
        /// deleted on the remote (as far as the local tracking refs know).
        public let upstreamGone: Bool

        /// Which branch `ahead`/`behind` measure against (A3).
        public let baseline: Baseline

        /// A3's numbers. `nil` when there is nothing to measure: no upstream
        /// set and the default branch does not resolve.
        public let ahead: Int?
        public let behind: Int?

        /// Ahead/behind against the default branch regardless of the A3
        /// baseline — M1's ancestry input, always default-relative. `nil`
        /// when the default does not resolve.
        public let defaultAhead: Int?
        public let defaultBehind: Int?

        public init(
            ref: String, upstream: String?, upstreamGone: Bool,
            baseline: Baseline, ahead: Int?, behind: Int?,
            defaultAhead: Int?, defaultBehind: Int?
        ) {
            self.ref = ref
            self.upstream = upstream
            self.upstreamGone = upstreamGone
            self.baseline = baseline
            self.ahead = ahead
            self.behind = behind
            self.defaultAhead = defaultAhead
            self.defaultBehind = defaultBehind
        }
    }

    /// One read of every local branch's status.
    public struct Report: Sendable, Equatable {
        /// The default branch the read measured against — the branch name
        /// `origin/HEAD`'s target names, or the literal `main` fallback.
        public let defaultBranch: String
        public let rows: [Row]

        public init(defaultBranch: String, rows: [Row]) {
            self.defaultBranch = defaultBranch
            self.rows = rows
        }

        /// The row for a full branch ref name (`refs/heads/main`).
        public func row(forBranchNamed refName: String) -> Row? {
            rows.first { $0.ref == refName }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A `for-each-ref` status line did not parse. Thrown rather than
        /// skipped: a silently dropped row is a silently wrong sidebar.
        case malformedStatusLine(_ line: String)

        public var description: String {
            switch self {
            case let .malformedStatusLine(line):
                "unparseable for-each-ref status line: \(line)"
            }
        }
    }

    static let headsPrefix = "refs/heads/"
    static let originHEADRef = "refs/remotes/origin/HEAD"
    static let originHEADPrefix = "refs/remotes/origin/"

    /// Tab-separated fields: ref names cannot contain ASCII control
    /// characters (git-check-ref-format), and neither the track vocabulary
    /// (`ahead 1, behind 2`, `[gone]`) nor the counts (`0 1`) contain one.
    static func forEachRefArguments(
        defaultBranch: String, includeDefaultAheadBehind: Bool
    ) -> [String] {
        var format = "%(refname)\t%(upstream)\t%(upstream:track)"
        if includeDefaultAheadBehind {
            format += "\t%(ahead-behind:\(defaultBranch))"
        }
        return ["for-each-ref", "--format=" + format, Self.headsPrefix]
    }

    /// The default branch name for A3's fallback baseline and M6's
    /// measurements: `origin/HEAD`'s symbolic target with
    /// `refs/remotes/origin/` stripped, or the literal `main` when
    /// `origin/HEAD` is missing or not a symref. Decision 27's implementation
    /// caveat — `for-each-ref` lists `refs/remotes/origin/HEAD` as if it
    /// were a commit — does not bite here: this read enumerates
    /// `refs/heads/` only, which never contains it.
    static func defaultBranchName(fromSymbolicRef out: GitProcess.Output) -> String {
        guard out.exitCode == 0, let target = out.lines.first, !target.isEmpty,
              target.hasPrefix(Self.originHEADPrefix)
        else { return "main" }
        return String(target.dropFirst(Self.originHEADPrefix.count))
    }

    /// The A3 + M1 read: one `symbolic-ref` to name the default branch, then
    /// one `for-each-ref` carrying `%(upstream:track)` and
    /// `%(ahead-behind:<default>)` together — decision 27's synchronous
    /// sidebar-load budget. Never one process per branch.
    public static func read(at path: String, git: GitProcess = GitProcess()) throws -> Report {
        let defaultBranch = try defaultBranchName(
            fromSymbolicRef: git.capture(["symbolic-ref", Self.originHEADRef], workingDirectory: path))
        let out: GitProcess.Output
        do {
            out = try git.run(
                Self.forEachRefArguments(defaultBranch: defaultBranch, includeDefaultAheadBehind: true),
                workingDirectory: path)
        } catch {
            // The default branch does not resolve and git fatals the whole
            // enumeration (measured, git 2.50.1). Retry without the atom —
            // the degraded shape described in the file comment.
            out = try git.run(
                Self.forEachRefArguments(defaultBranch: defaultBranch, includeDefaultAheadBehind: false),
                workingDirectory: path)
        }
        return Report(
            defaultBranch: defaultBranch,
            rows: try parse(out.text, defaultBranch: defaultBranch))
    }

    /// Async twin of `read(at:git:)` — the sidebar-facing path, so a
    /// cooperative-pool thread (or the main actor) is not held for the
    /// subprocess's lifetime. Same spawns, same parse, same errors.
    public static func read(at path: String, git: GitProcess = GitProcess()) async throws -> Report {
        let defaultBranch = try defaultBranchName(
            fromSymbolicRef: await git.capture(
                ["symbolic-ref", Self.originHEADRef], workingDirectory: path))
        let out: GitProcess.Output
        do {
            out = try await git.run(
                Self.forEachRefArguments(defaultBranch: defaultBranch, includeDefaultAheadBehind: true),
                workingDirectory: path)
        } catch {
            out = try await git.run(
                Self.forEachRefArguments(defaultBranch: defaultBranch, includeDefaultAheadBehind: false),
                workingDirectory: path)
        }
        return Report(
            defaultBranch: defaultBranch,
            rows: try parse(out.text, defaultBranch: defaultBranch))
    }

    // MARK: - Parse

    struct Track: Equatable {
        let ahead: Int?
        let behind: Int?
        let gone: Bool
    }

    /// `%(upstream:track)`'s vocabulary under `LC_ALL=C`: empty (in sync, or
    /// no upstream), `[gone]`, `ahead N`, `behind N`, `ahead N, behind M`.
    static func parseTrack(_ raw: String) throws -> Track {
        if raw.isEmpty { return Track(ahead: nil, behind: nil, gone: false) }
        if raw == "[gone]" { return Track(ahead: nil, behind: nil, gone: true) }
        var ahead: Int?
        var behind: Int?
        for part in raw.split(separator: ",") {
            let word = part.trimmingCharacters(in: .whitespaces)
            if word.hasPrefix("ahead "), let n = Int(word.dropFirst("ahead ".count)) {
                ahead = n
            } else if word.hasPrefix("behind "), let n = Int(word.dropFirst("behind ".count)) {
                behind = n
            } else {
                throw Error.malformedStatusLine(raw)
            }
        }
        return Track(ahead: ahead, behind: behind, gone: false)
    }

    /// `%(ahead-behind:<default>)`'s `A B`, or `nil` for the empty output of
    /// a count that could not resolve.
    static func parseAheadBehind(_ raw: String) throws -> (ahead: Int, behind: Int)? {
        guard !raw.isEmpty else { return nil }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else {
            throw Error.malformedStatusLine(raw)
        }
        return (a, b)
    }

    /// Parses `read`'s for-each-ref output. Three fields when the read ran
    /// without the ahead-behind atom (the degraded no-default-branch shape),
    /// four otherwise.
    static func parse(_ text: String, defaultBranch: String) throws -> [Row] {
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 || fields.count == 4 else {
                throw Error.malformedStatusLine(String(line))
            }
            let ref = String(fields[0])
            let upstream = fields[1].isEmpty ? nil : String(fields[1])
            let track = try parseTrack(String(fields[2]))
            let defaultNumbers = fields.count == 4 ? try parseAheadBehind(String(fields[3])) : nil

            // A3: the upstream baseline when one is set and alive, else the
            // default branch. An upstream that reads `[gone]` has no numbers
            // to show, so the row falls back to the default baseline. An
            // empty track against a live upstream is in sync (0, 0).
            let baseline: Baseline
            let ahead: Int?
            let behind: Int?
            if let upstream, !track.gone {
                baseline = .upstream(upstream)
                ahead = track.ahead ?? 0
                behind = track.behind ?? 0
            } else {
                baseline = .defaultBranch(defaultBranch)
                ahead = defaultNumbers?.ahead
                behind = defaultNumbers?.behind
            }
            rows.append(Row(
                ref: ref, upstream: upstream, upstreamGone: track.gone,
                baseline: baseline, ahead: ahead, behind: behind,
                defaultAhead: defaultNumbers?.ahead,
                defaultBehind: defaultNumbers?.behind))
        }
        return rows
    }

    // MARK: - M6, the merged composite

    /// M6 in order: ancestry (M1) from the default-relative ahead count,
    /// else upstream-gone (M4), else the content pass's answer (M3), else
    /// `unknown` — for branches the pass has not landed for, and for the
    /// conflict answers it reports. Never per-branch spawned on the load
    /// path: `content` arrives from `contentPass` after the sidebar appears.
    public static func mergedState(
        for row: Row, content: [String: MergedState] = [:]
    ) -> MergedState {
        if let ahead = row.defaultAhead, ahead == 0 { return .merged(by: .ancestry) }
        if row.upstreamGone { return .merged(by: .upstreamGone) }
        return content[row.ref] ?? .unknown
    }

    /// The M3 content pass: `git merge-tree --write-tree <default> <branch>`
    /// for every branch M6 leaves to content — ahead of the default (or
    /// unmeasurable) with a live upstream. Runs after the sidebar appears;
    /// per-branch spawns measured at 7.7 s for 309 branches, so it never
    /// belongs on the load path.
    ///
    /// Answers: the default branch's tree → `merged(by: .content)` (the
    /// squash-landing shape, measured); a different tree → `.notMerged`;
    /// exit 1 — a conflict (measured) — and any other refusal → `.unknown`.
    /// The default branch's tree is read once per pass; branches that M1 or
    /// M4 already answer spawn nothing. Throws only when git cannot read the
    /// repository at all (the default branch's tree cannot be resolved);
    /// per-branch refusals stay `.unknown` — the column never blocks.
    public static func contentPass(
        for report: Report, at path: String, git: GitProcess = GitProcess()
    ) async throws -> [String: MergedState] {
        let candidates = report.rows.filter { row in
            if let ahead = row.defaultAhead, ahead == 0 { return false }
            return !row.upstreamGone
        }
        guard !candidates.isEmpty else { return [:] }
        let defaultTree = try await git.run(
            ["rev-parse", "\(report.defaultBranch)^{tree}"], workingDirectory: path
        ).lines.first ?? ""
        guard !defaultTree.isEmpty else { return [:] }

        var results: [String: MergedState] = [:]
        for row in candidates {
            let out = try await git.capture(
                ["merge-tree", "--write-tree", report.defaultBranch, row.ref],
                workingDirectory: path)
            switch out.exitCode {
            case 0:
                if let tree = out.lines.first, !tree.isEmpty {
                    results[row.ref] = tree == defaultTree ? .merged(by: .content) : .notMerged
                } else {
                    results[row.ref] = .unknown
                }
            default:
                // 1: a conflict — "merging this branch would now need
                // conflict resolution" is a fact about the repository, not a
                // guess to hide. Anything else is git refusing; unknown too.
                results[row.ref] = .unknown
            }
        }
        return results
    }
}

// MARK: - §6 exit class

/// Unparseable plumbing output is a repository-state failure — guide §6
/// code 6, the same class as `RefSnapshot.Error`'s malformed ref line.
extension BranchStatus.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
