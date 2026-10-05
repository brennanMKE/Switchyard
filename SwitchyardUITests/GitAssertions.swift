// GitAssertions.swift
//
// #0591 (umbrella #0590): reads a fixture repository's real git state from
// the XCUITest runner, so a history-operation spike asserts what git holds
// — refs, parents, trees, file contents — and not only what the window
// draws. The runner is unsandboxed in the guest (built unsigned, no
// entitlements), and `/usr/bin/git` runs from it via `Process`: measured in
// the VM by Spike0591GitAssertionsUITests.
//
// Read-only on purpose. Every call passes `--no-optional-locks`, so a
// `status` never takes `index.lock` and races the app's own refresh.

import Foundation
import XCTest

/// One fixture repository, read through `/usr/bin/git -C <path>`.
struct GitRepo {
    let path: String

    /// Runs git and returns its stdout with trailing whitespace trimmed.
    /// Fails the test (and returns "") on a non-zero exit.
    @discardableResult
    func git(_ arguments: String..., file: StaticString = #filePath, line: UInt = #line) -> String {
        let result = run(arguments)
        XCTAssertEqual(
            result.status, 0,
            "git \(arguments.joined(separator: " ")) exited \(result.status): \(result.stderr)",
            file: file, line: line)
        return result.stdout
    }

    /// Runs git and returns (status, trimmed stdout, trimmed stderr) without
    /// asserting — for probes whose non-zero exit is an answer.
    func run(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "", "could not launch /usr/bin/git: \(error)")
        }
        // Read before waiting: a full pipe would otherwise block the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let trim = { (data: Data) in
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (process.terminationStatus, trim(stdout), trim(stderr))
    }

    /// `rev-parse --verify <rev>`; "" when it does not resolve.
    func oid(_ rev: String) -> String {
        let result = run(["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"])
        return result.status == 0 ? result.stdout : ""
    }

    /// `rev-parse --verify <ref>` without peeling — for a tag ref.
    func refOid(_ ref: String) -> String {
        let result = run(["rev-parse", "--verify", "--quiet", ref])
        return result.status == 0 ? result.stdout : ""
    }

    /// The branch HEAD names (`symbolic-ref --short`), "" when detached.
    func headBranch() -> String {
        let result = run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        return result.status == 0 ? result.stdout : ""
    }

    /// The parents of `rev`, in order.
    func parents(of rev: String = "HEAD", file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let output = git("rev-list", "--parents", "-n", "1", rev, file: file, line: line)
        return Array(output.split(separator: " ").dropFirst().map(String.init))
    }

    /// The full message of `rev` (`%B`), trimmed.
    func message(of rev: String = "HEAD", file: StaticString = #filePath, line: UInt = #line) -> String {
        git("log", "-1", "--format=%B", rev, file: file, line: line)
    }

    /// First-parent subjects from `rev`, newest first.
    func subjects(_ rev: String = "HEAD", file: StaticString = #filePath, line: UInt = #line) -> [String] {
        git("log", "--first-parent", "--format=%s", rev, file: file, line: line)
            .split(separator: "\n").map(String.init)
    }

    /// The paths in `rev`'s tree, sorted.
    func lsTree(_ rev: String = "HEAD", file: StaticString = #filePath, line: UInt = #line) -> [String] {
        git("ls-tree", "-r", "--name-only", rev, file: file, line: line)
            .split(separator: "\n").map(String.init).sorted()
    }

    /// `rev`'s tree oid.
    func treeOid(_ rev: String = "HEAD", file: StaticString = #filePath, line: UInt = #line) -> String {
        git("rev-parse", "\(rev)^{tree}", file: file, line: line)
    }

    /// The blob at `path` in `rev`, trimmed; nil when absent.
    func fileContents(at path: String, rev: String = "HEAD") -> String? {
        let result = run(["show", "\(rev):\(path)"])
        return result.status == 0 ? result.stdout : nil
    }

    /// The working-tree file at `path`, trimmed; nil when absent.
    func worktreeFile(_ path: String) -> String? {
        (try? String(contentsOfFile: self.path + "/" + path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `status --porcelain`, untracked included; "" means clean.
    func porcelain(file: StaticString = #filePath, line: UInt = #line) -> String {
        git("status", "--porcelain", "--untracked-files=all", file: file, line: line)
    }

    func isClean() -> Bool { porcelain().isEmpty }

    /// Paths with unmerged index entries.
    func conflictedPaths() -> [String] {
        run(["diff", "--name-only", "--diff-filter=U"]).stdout
            .split(separator: "\n").map(String.init)
    }

    /// Whether a merge / cherry-pick is in progress (the pseudo-ref resolves).
    func isMidMerge() -> Bool { !refOid("MERGE_HEAD").isEmpty }
    func isMidCherryPick() -> Bool { !refOid("CHERRY_PICK_HEAD").isEmpty }

    /// Every branch and tag with its oid, plus HEAD's symbolic target — the
    /// state an Undo must give back. The journal's own `refs/switchyard/`
    /// namespace is excluded: it moves on every checkpoint by design.
    func refSnapshot(file: StaticString = #filePath, line: UInt = #line) -> String {
        let refs = git("for-each-ref", "--format=%(refname) %(objectname)",
                       "refs/heads", "refs/tags", file: file, line: line)
        let head = headBranch()
        return "HEAD -> \(head.isEmpty ? oid("HEAD") : head)\n\(refs)"
    }

    /// Bounded poll until `condition` holds — the app runs git
    /// asynchronously, so a spike waits for the state rather than sleeping.
    /// A wait bound, never an elapsed-time assertion.
    @discardableResult
    func wait(timeout: TimeInterval = 60, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(250_000)
        }
        return condition()
    }
}

/// The pre-state a spike captures before acting and asserts after Undo:
/// every branch and tag, HEAD, HEAD's tree, and the porcelain status.
struct GitStateSnapshot: Equatable, CustomStringConvertible {
    let refs: String
    let headTree: String
    let status: String

    init(_ repo: GitRepo) {
        refs = repo.refSnapshot()
        headTree = repo.treeOid()
        status = repo.porcelain()
    }

    private init(refs: String, headTree: String, status: String) {
        self.refs = refs
        self.headTree = headTree
        self.status = status
    }

    /// This snapshot without one ref's line — for an Undo that by design
    /// (guide §11 decision 20) leaves a ref the undone operation created.
    func removingRef(_ name: String) -> GitStateSnapshot {
        GitStateSnapshot(
            refs: refs.split(separator: "\n").filter { !$0.hasPrefix(name + " ") }
                .joined(separator: "\n"),
            headTree: headTree, status: status)
    }

    var description: String { "\(refs)\ntree \(headTree)\nstatus [\(status)]" }
}

extension GitRepo {
    /// Bounded wait until the repository is back at `expected`; on timeout
    /// the failure prints both snapshots, so a red run names the ref that
    /// did not come back.
    func assertRestored(
        to expected: GitStateSnapshot, timeout: TimeInterval = 60, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !wait(timeout: timeout, until: { GitStateSnapshot(self) == expected }) else { return }
        XCTFail("\(message)\n--- expected\n\(expected)\n--- actual\n\(GitStateSnapshot(self))",
                file: file, line: line)
    }

    /// `log --format='%h %p %s' -n <count> <rev>` — a failure message's
    /// picture of the branch.
    func graph(_ rev: String, count: Int = 6) -> String {
        run(["log", "--format=%h %p %s", "-n", "\(count)", rev]).stdout
    }
}
