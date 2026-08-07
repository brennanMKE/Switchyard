// FixtureRepository.swift

import Foundation

/// Builds throwaway git repositories for tests.
///
/// This ships in `YardGit` rather than in the test target so the CLI's own
/// tests, future app-side tests, and any diagnostic tooling can all build the
/// same fixtures. It is deliberately small: a compact DAG description in,
/// a real repository on disk out.
///
/// Two rules it never breaks:
///
/// - **It never touches the user's environment.** Every repository gets its own
///   `user.name`, `user.email`, and committer dates, and nothing reads or
///   writes `~/.gitconfig` or `~/.ssh`.
/// - **Every fixture can be built in both ref formats.** libgit2 cannot read
///   reftable (#0004) and reftable becomes git's default in 3.0, so a suite
///   that only ran against `files` would not be testing what ships.
public struct FixtureRepository {

    public enum RefFormat: String, CaseIterable, Sendable {
        case files
        case reftable

        /// Every format the local git can actually create. Reftable support
        /// arrived in git 2.45; on an older git the reftable cases are skipped
        /// loudly rather than silently passing.
        public static func supported(git: GitProcess = GitProcess()) -> [RefFormat] {
            var found: [RefFormat] = [.files]
            let probe = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("yard-refformat-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: probe) }
            if let result = try? git.capture(["init", "-q", "--ref-format=reftable", probe.path]),
               result.exitCode == 0 {
                found.append(.reftable)
            }
            return found
        }
    }

    /// A commit to create, named so later commits can refer to it.
    public struct Commit: Sendable {
        public let name: String
        public let parents: [String]
        public let files: [String: String]
        public let message: String

        public init(_ name: String,
                    parents: [String] = [],
                    files: [String: String] = [:],
                    message: String? = nil) {
            self.name = name
            self.parents = parents
            self.files = files.isEmpty ? ["\(name).txt": "\(name)\n"] : files
            self.message = message ?? name
        }
    }

    public let url: URL
    public let refFormat: RefFormat
    private let git: GitProcess

    /// Object ids of the named commits, so tests can assert against them.
    public private(set) var oids: [String: String] = [:]

    // MARK: - Lifecycle

    /// Creates an initialized repository in a unique temporary directory.
    public init(refFormat: RefFormat = .files,
                bare: Bool = false,
                git: GitProcess = GitProcess()) throws {
        self.git = git
        self.refFormat = refFormat
        self.url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-fixture-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var args = ["init", "-q", "--ref-format=\(refFormat.rawValue)", "--initial-branch=main"]
        if bare { args.append("--bare") }
        args.append(url.path)
        try git.run(args)

        guard !bare else { return }
        // Identity and signing config are set per-repository so nothing reads
        // the user's global config or attempts to sign with a real key.
        for (key, value) in [
            "user.name": "Fixture",
            "user.email": "fixture@example.invalid",
            "commit.gpgsign": "false",
            "tag.gpgsign": "false",
            "gc.auto": "0",
        ] {
            try git.run(["config", key, value], workingDirectory: url.path)
        }
    }

    /// Removes the repository. Tests call this from a `defer` so it runs even
    /// when an expectation fails partway through.
    public func destroy() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Building

    /// Creates commits in order, wiring parents by name.
    ///
    /// A commit with no named parents starts from the current `HEAD`, so a
    /// simple linear history needs no parent bookkeeping at all.
    public mutating func build(_ commits: [Commit]) throws {
        for commit in commits {
            if !commit.parents.isEmpty {
                let parentOids = try commit.parents.map { name -> String in
                    guard let oid = oids[name] else {
                        throw Error.unknownParent(commit: commit.name, parent: name)
                    }
                    return oid
                }
                try checkoutDetached(parentOids[0])
                if parentOids.count > 1 {
                    try merge(parentOids.dropFirst().map { $0 }, message: commit.message)
                }
            }
            for (path, contents) in commit.files.sorted(by: { $0.key < $1.key }) {
                let file = url.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
            try git.run(["add", "-A"], workingDirectory: url.path)
            try git.run(["commit", "-q", "--allow-empty", "-m", commit.message],
                        workingDirectory: url.path)
            oids[commit.name] = try revParse("HEAD")
        }
    }

    /// Merges the given commits into `HEAD` without committing, so the caller's
    /// `build` step makes the merge commit with the right message.
    private func merge(_ parents: [String], message: String) throws {
        var args = ["merge", "--no-commit", "--no-ff", "-q"]
        args.append(contentsOf: parents)
        // A conflicting merge exits non-zero and leaves the conflict in the
        // index, which is exactly what the conflict fixture wants.
        _ = try git.capture(args, workingDirectory: url.path)
    }

    // MARK: - Operations tests need

    public mutating func branch(_ name: String, at commit: String? = nil) throws {
        var args = ["branch", "-f", name]
        if let commit, let oid = oids[commit] { args.append(oid) }
        try git.run(args, workingDirectory: url.path)
    }

    public func checkout(_ ref: String) throws {
        try git.run(["checkout", "-q", ref], workingDirectory: url.path)
    }

    public func checkoutDetached(_ oid: String) throws {
        try git.run(["checkout", "-q", "--detach", oid], workingDirectory: url.path)
    }

    /// Adds a linked worktree and returns its path.
    @discardableResult
    public func addWorktree(named name: String, branch: String) throws -> URL {
        let path = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-wt-\(name)")
        try git.run(["worktree", "add", "-q", "-b", branch, path.path],
                    workingDirectory: url.path)
        return path
    }

    /// Writes files without staging them.
    public func writeUntracked(_ files: [String: String]) throws {
        for (path, contents) in files {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Starts an interactive rebase and stops at the first commit, leaving the
    /// sequencer state a journal snapshot has to capture (#0035).
    public func beginInterruptedRebase(onto ref: String) throws {
        _ = try git.capture(["rebase", "--exec", "false", ref], workingDirectory: url.path)
    }

    // MARK: - Reading

    public func revParse(_ rev: String) throws -> String {
        try git.run(["rev-parse", rev], workingDirectory: url.path).lines[0]
    }

    public func refNames() throws -> [String] {
        try git.run(["for-each-ref", "--format=%(refname)"], workingDirectory: url.path).lines
    }

    /// Whether a rebase is in progress.
    ///
    /// Asks git where the sequencer directories live rather than assuming
    /// `.git/` — in a linked worktree they are under `$GIT_DIR`, not
    /// `$GIT_COMMON_DIR`, and the fixture harness has to obey the same rule as
    /// the engine it tests.
    public var isMidRebase: Bool {
        let fm = FileManager.default
        for name in ["rebase-merge", "rebase-apply"] {
            guard let out = try? git.run(["rev-parse", "--path-format=absolute", "--git-path", name],
                                         workingDirectory: url.path),
                  let path = out.lines.first, !path.isEmpty else { continue }
            if fm.fileExists(atPath: path) { return true }
        }
        return false
    }

    public var hasConflicts: Bool {
        guard let out = try? git.capture(["ls-files", "--unmerged"], workingDirectory: url.path)
        else { return false }
        return !out.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Errors

    public enum Error: Swift.Error, CustomStringConvertible {
        case unknownParent(commit: String, parent: String)

        public var description: String {
            switch self {
            case let .unknownParent(commit, parent):
                return "commit \"\(commit)\" names parent \"\(parent)\", which has not been built"
            }
        }
    }
}

// MARK: - Ready-made shapes

public extension FixtureRepository {

    /// `a → b → c` on `main`.
    static func linear(refFormat: RefFormat = .files) throws -> FixtureRepository {
        var repo = try FixtureRepository(refFormat: refFormat)
        try repo.build([Commit("a"), Commit("b"), Commit("c")])
        return repo
    }

    /// A branch off `a`, merged back — the smallest non-trivial DAG.
    static func merged(refFormat: RefFormat = .files) throws -> FixtureRepository {
        var repo = try FixtureRepository(refFormat: refFormat)
        try repo.build([Commit("a"), Commit("b", parents: ["a"])])
        try repo.build([Commit("side", parents: ["a"])])
        try repo.build([Commit("merge", parents: ["b", "side"])])
        try repo.branch("main", at: "merge")
        try repo.checkout("main")
        return repo
    }

    /// Three parents, for lane-assignment cases that a two-parent merge misses.
    static func octopus(refFormat: RefFormat = .files) throws -> FixtureRepository {
        var repo = try FixtureRepository(refFormat: refFormat)
        try repo.build([Commit("base")])
        try repo.build([Commit("x", parents: ["base"])])
        try repo.build([Commit("y", parents: ["base"])])
        try repo.build([Commit("z", parents: ["base"])])
        try repo.build([Commit("octo", parents: ["x", "y", "z"])])
        return repo
    }

    /// Both sides edit the same line, so a merge leaves an unmerged index —
    /// the state `git write-tree` refuses (#0027).
    static func conflicted(refFormat: RefFormat = .files) throws -> FixtureRepository {
        var repo = try FixtureRepository(refFormat: refFormat)
        try repo.build([Commit("base", files: ["f.txt": "original\n"])])
        try repo.build([Commit("ours", parents: ["base"], files: ["f.txt": "ours\n"])])
        try repo.build([Commit("theirs", parents: ["base"], files: ["f.txt": "theirs\n"])])
        try repo.checkoutDetached(repo.oids["ours"]!)
        _ = try? GitProcess().run(["merge", "--no-commit", repo.oids["theirs"]!],
                                  workingDirectory: repo.url.path)
        return repo
    }
}
