// GitProcessTests.swift

import Foundation
import Testing
@testable import YardGit

struct GitProcessTests {

    private let git = GitProcess()

    /// Builds a throwaway repository in a temp directory. Never touches the
    /// user's global config or `~/.ssh`.
    private func makeRepo(refFormat: String = "files") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-gitprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git.run(["init", "-q", "--ref-format=\(refFormat)", dir.path])
        try git.run(["config", "user.name", "Test"], workingDirectory: dir.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: dir.path)
        return dir
    }

    // MARK: - Basics

    @Test func runsAndCapturesStdout() throws {
        let out = try git.run(["--version"])
        #expect(out.text.hasPrefix("git version"))
        #expect(out.exitCode == 0)
    }

    @Test func workingDirectoryIsPassedThroughDashC() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let out = try git.run(["rev-parse", "--is-inside-work-tree"], workingDirectory: repo.path)
        #expect(out.lines.first == "true")
    }

    // MARK: - Failure carries stderr

    @Test func failingCommandThrowsWithStderr() throws {
        var thrown: GitProcess.Failure?
        do {
            _ = try git.run(["rev-parse", "--verify", "refs/heads/definitely-not-a-ref"],
                            workingDirectory: NSTemporaryDirectory())
        } catch let error as GitProcess.Failure {
            thrown = error
        }
        let failure = try #require(thrown, "expected a Failure")
        guard case let .exited(code, stderr, arguments) = failure else {
            Issue.record("expected .exited, got \(failure)")
            return
        }
        #expect(code != 0)
        #expect(!stderr.isEmpty, "stderr must be captured, not discarded")
        #expect(arguments.contains("rev-parse"))
        // The description is what a caller actually sees.
        #expect(failure.description.contains("exited"))
    }

    @Test func captureReturnsNonZeroWithoutThrowing() throws {
        let result = try git.capture(["rev-parse", "--verify", "nope"],
                                     workingDirectory: NSTemporaryDirectory())
        #expect(result.exitCode != 0)
    }

    // MARK: - Large output

    /// Reading one pipe to completion before the other deadlocks once the
    /// second fills its buffer. That only shows up on large output, so this
    /// generates enough to exceed the pipe buffer several times over.
    @Test func handlesOutputLargerThanThePipeBuffer() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let big = String(repeating: "abcdefghij", count: 60_000)   // ~600 KB
        try big.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.path)
        try git.run(["commit", "-q", "-m", "big"], workingDirectory: repo.path)

        let out = try git.run(["show", "HEAD:big.txt"], workingDirectory: repo.path)
        #expect(out.standardOutput.count >= 600_000,
                "expected ~600 KB, got \(out.standardOutput.count) bytes")
    }

    // MARK: - stdin

    @Test func writesStandardInput() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)

        let head = try git.run(["rev-parse", "HEAD"], workingDirectory: repo.path).lines[0]
        // update-ref --stdin is how journal restore applies a whole ref batch
        // transactionally (#0027), so stdin support is not incidental.
        let batch = "create refs/test/stdin-batch \(head)\n"
        try git.run(["update-ref", "--stdin"],
                    workingDirectory: repo.path,
                    standardInput: Data(batch.utf8))

        let check = try git.run(["rev-parse", "--verify", "refs/test/stdin-batch"],
                                workingDirectory: repo.path)
        #expect(check.lines[0] == head)
    }

    // MARK: - Environment

    @Test func environmentDisablesEditorsAndPagers() {
        let env = GitProcess.environment()
        #expect(env["GIT_EDITOR"] == "false")
        #expect(env["GIT_SEQUENCE_EDITOR"] == "false")
        #expect(env["GIT_PAGER"] == "cat")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["LC_ALL"] == "C")
    }

    @Test func environmentSetsTheHookMarker() {
        #expect(GitProcess.environment()[GitProcess.markerVariable] == "1")
    }

    @Test func extraEnvironmentOverridesTheBase() {
        let env = GitProcess.environment(adding: ["GIT_PAGER": "less"])
        #expect(env["GIT_PAGER"] == "less")
    }

    /// The editor settings are only worth anything if git actually honors
    /// them. This asks git itself rather than trusting the variable.
    @Test func gitReportsTheDisabledEditor() throws {
        let out = try git.run(["var", "GIT_EDITOR"])
        #expect(out.lines.first == "false")
    }

    // MARK: - Reftable, per #0004

    /// libgit2 cannot open a reftable repository, which is why refs go through
    /// this type. So this type must work on one.
    @Test func worksAgainstAReftableRepository() throws {
        let repo = try makeRepo(refFormat: "reftable")
        defer { try? FileManager.default.removeItem(at: repo) }
        try git.run(["commit", "-q", "--allow-empty", "-m", "one"], workingDirectory: repo.path)

        let refs = try git.run(["for-each-ref", "--format=%(refname)"], workingDirectory: repo.path)
        #expect(refs.lines.contains { $0.hasPrefix("refs/heads/") })

        let head = try git.run(["symbolic-ref", "HEAD"], workingDirectory: repo.path)
        #expect(head.lines[0].hasPrefix("refs/heads/"))

        let format = try git.run(["rev-parse", "--show-ref-format"], workingDirectory: repo.path)
        #expect(format.lines[0] == "reftable")
    }

    // MARK: - The boundary stays visible

    /// No other type in `YardGit` may construct a `Process`. If the boundary
    /// leaks, it stops being reviewable in one place.
    @Test func noOtherEngineSourceConstructsAProcess() throws {
        let engine = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardGitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit (package root)
            .appendingPathComponent("Sources/YardGit")

        let files = try FileManager.default
            .contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "GitProcess.swift" }

        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("Process(") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Process constructed outside GitProcess: \(offenders)")
    }
}
