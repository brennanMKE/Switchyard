// GitProcessAsyncTests.swift

import Foundation
import Testing
@testable import YardGit

/// Thread-safe counters for the starvation-property test.
private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var completedCount = 0

    var started: Int { lock.withLock { startedCount } }
    var completed: Int { lock.withLock { completedCount } }

    func markStarted() { lock.withLock { startedCount += 1 } }
    func markCompleted() { lock.withLock { completedCount += 1 } }
}

/// The non-blocking async `GitProcess` path added by #0344.
///
/// The starvation property is asserted by **construction, not by time**
/// (Rule 7c forbids wall-clock assertions, and this issue is about timing):
/// `2 × activeProcessorCount` concurrent captures of a two-second subprocess
/// must all be *in flight simultaneously* — observed as "every child has
/// started, and not one has completed". That is only possible if a suspended
/// capture holds no cooperative-pool thread. If the async path blocked (the
/// mutation that makes it call the synchronous `capture` internally), the
/// pool saturates at ~core-count blocked children, the rest stay queued, and
/// completions necessarily precede the last start — the assertion goes red
/// deterministically, because the only way a queued child can start is for a
/// blocking child to finish and free its thread.
struct GitProcessAsyncTests {

    private let git = GitProcess()

    /// Builds a throwaway repository in a temp directory. Never touches the
    /// user's global config or `~/.ssh`.
    private func makeRepo(refFormat: String = "files") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-gitprocess-async-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git.run(["init", "-q", "--ref-format=\(refFormat)", dir.path])
        try git.run(["config", "user.name", "Test"], workingDirectory: dir.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: dir.path)
        return dir
    }

    // Sync-reference helpers: called from *synchronous* functions, these
    // resolve to the synchronous overloads — which is the comparison the
    // tests below need. A call written directly in an `async` test body
    // would silently pick the async twin, making an "async matches sync"
    // assertion compare the async path against itself.
    private func syncVersionOutput() throws -> GitProcess.Output {
        try git.run(["--version"])
    }

    private func syncWhereAmI(path: String) throws -> WhereAmI {
        try whereAmI(path: path)
    }

    private func syncResolve(path: String) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: path)
    }

    private func syncWorktreeList(path: String) throws -> [WorktreeEntry] {
        try worktreeList(path: path)
    }

    private func syncRefs(in context: WorktreeContext) throws -> RefSnapshot {
        try RefSnapshot.capture(in: context)
    }

    private func syncStatus(at path: String) throws -> WorktreeStatus {
        try gitStatus(at: path)
    }

    private func syncLog(path: String) throws -> [CommitLogEntry] {
        try CommitLog.run(path: path, rangeArguments: ["-100", "HEAD"])
    }

    private func syncGraph(at path: String) throws -> [GraphRow] {
        try graphRows(at: path, limit: 100)
    }

    private func syncDiff(at path: String, revision: String) throws -> [FileDiff] {
        try commitDiff(at: path, revision: revision)
    }

    // MARK: - Output parity with the synchronous path

    @Test func asyncCaptureMatchesSyncOutput() async throws {
        let syncOut = try syncVersionOutput()
        let asyncOut = try await git.run(["--version"])
        #expect(asyncOut.exitCode == 0)
        #expect(asyncOut.standardError.isEmpty)
        #expect(asyncOut.standardOutput == syncOut.standardOutput)
        #expect(asyncOut.text.hasPrefix("git version"))
    }

    @Test func asyncRunThrowsExitedWithStderr() async throws {
        var thrown: GitProcess.Failure?
        do {
            _ = try await git.run(
                ["rev-parse", "--verify", "refs/heads/definitely-not-a-ref"],
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
    }

    /// stdin through the async path must reach the child: a large payload can
    /// fill the pipe buffer, which is why the async path writes it from a
    /// dedicated thread rather than the calling task's.
    @Test func asyncCaptureWithStdinAppliesTheRefBatch() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: repo.path)

        let head = try await git.run(["rev-parse", "HEAD"], workingDirectory: repo.path).lines[0]
        let batch = "create refs/test/stdin-batch \(head)\n"
        _ = try await git.run(
            ["update-ref", "--stdin"],
            workingDirectory: repo.path,
            standardInput: Data(batch.utf8))

        let check = try await git.run(
            ["rev-parse", "--verify", "refs/test/stdin-batch"], workingDirectory: repo.path)
        #expect(check.lines[0] == head)
    }

    /// Output larger than the pipe buffer must drain completely: the async
    /// path completes only when *both* stdout EOF and process exit have been
    /// observed, so the buffer is final before the result is built.
    @Test func asyncCaptureHandlesOutputLargerThanThePipeBuffer() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let big = String(repeating: "abcdefghij", count: 60_000)   // ~600 KB
        try big.write(to: repo.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], workingDirectory: repo.path)
        try await git.run(["commit", "-q", "-m", "big"], workingDirectory: repo.path)

        let out = try await git.run(["show", "HEAD:big.txt"], workingDirectory: repo.path)
        #expect(out.standardOutput.count >= 600_000,
                "expected ~600 KB, got \(out.standardOutput.count) bytes")
        #expect(out.text.hasSuffix("abcdefghij"))
    }

    // MARK: - Timeout and cancellation keep #0239's semantics

    @Test func asyncCaptureWithTimeoutThrowsTimedOut() async throws {
        let sleeper = GitProcess(executablePath: "/bin/sleep")
        var thrown: GitProcess.Failure?
        do {
            _ = try await sleeper.capture(["5"], timeout: .milliseconds(200))
        } catch let error as GitProcess.Failure {
            thrown = error
        }
        let failure = try #require(thrown, "expected a Failure")
        guard case let .timedOut(after, arguments, terminationStatus) = failure else {
            Issue.record("expected .timedOut, got \(failure)")
            return
        }
        #expect(after == .milliseconds(200))
        #expect(arguments == ["5"])
        // The escalation is SIGTERM first; /bin/sleep does not trap signals,
        // so the ordinary case (#0239, measured) reports SIGTERM, and only a
        // child that ignored SIGTERM would report SIGKILL.
        #expect(terminationStatus == SIGTERM)
    }

    @Test func cancellingAsyncCaptureTerminatesTheChildAndThrows() async throws {
        let sleeper = GitProcess(executablePath: "/bin/sleep")
        let task = Task {
            try await sleeper.capture(["30"])
        }
        // Long enough that the child is launched; not an assertion.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        var thrown: (any Error)?
        do {
            _ = try await task.value
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "expected the cancelled capture to throw")
        #expect(error is CancellationError, "got \(error)")
    }

    // MARK: - Concurrency

    @Test func eightConcurrentAsyncCapturesAllSucceedWithIdenticalOutput() async throws {
        let outs = try await withThrowingTaskGroup(of: GitProcess.Output.self) { group in
            for _ in 0..<8 {
                group.addTask { try await self.git.run(["--version"]) }
            }
            var collected: [GitProcess.Output] = []
            for try await out in group {
                collected.append(out)
            }
            return collected
        }
        #expect(outs.count == 8)
        let first = try #require(outs.first)
        #expect(first.exitCode == 0)
        #expect(first.text.hasPrefix("git version"))
        for out in outs {
            #expect(out.standardOutput == first.standardOutput)
            #expect(out.exitCode == 0)
        }
    }

    /// The starvation property, asserted by construction — see the suite
    /// comment for why "all started, none completed" demonstrates the fix.
    @Test func concurrentAsyncCapturesDoNotHoldCooperativePoolThreads() async throws {
        let sleeper = GitProcess(executablePath: "/bin/sleep")
        // Twice the pool width: enough concurrent subprocesses that a
        // blocking implementation must saturate the pool and queue the rest.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let counter = CounterBox()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    counter.markStarted()
                    _ = try await sleeper.capture(["2"])
                    counter.markCompleted()
                }
            }
            // Bounded wait for every capture to have started (Rule 7c: a
            // bounded loop, never a wall-clock assertion). 500 polls × 10ms.
            var polls = 0
            while counter.started < count, polls < 500 {
                try await Task.sleep(for: .milliseconds(10))
                polls += 1
            }

            #expect(counter.started == count,
                    "only \(counter.started) of \(count) captures started; pool threads are being held")
            #expect(counter.completed == 0,
                    "\(counter.completed) captures completed while others were still queued to start; a suspended capture is holding a cooperative-pool thread")

            try await group.waitForAll()
        }

        #expect(counter.completed == count, "every capture must eventually complete")
    }

    // MARK: - The engine twins match their synchronous originals

    @Test func whereAmIAsyncMatchesSync() async throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([
            FixtureRepository.Commit("base"),
            FixtureRepository.Commit("second", files: ["second.txt": "two\n"]),
        ])
        let remote = try fixture.addUpstream()
        defer { try? FileManager.default.removeItem(at: remote) }

        let path = fixture.url.path
        // A stashed change first (stash push reverts the worktree), then a
        // fresh unstaged change, a staged file and an untracked file, so the
        // fixture exercises those counts deterministically.
        try "modified\n".write(
            to: fixture.url.appendingPathComponent("base.txt"),
            atomically: true, encoding: .utf8)
        try await git.run(["stash", "push", "-m", "wip"], workingDirectory: path)
        try "modified-again\n".write(
            to: fixture.url.appendingPathComponent("base.txt"),
            atomically: true, encoding: .utf8)
        try "staged\n".write(
            to: fixture.url.appendingPathComponent("staged.txt"),
            atomically: true, encoding: .utf8)
        try await git.run(["add", "staged.txt"], workingDirectory: path)
        try fixture.writeUntracked(["untracked.txt": "u\n"])

        let sync = try syncWhereAmI(path: path)
        let asyncValue = try await whereAmI(path: path)
        #expect(asyncValue == sync)

        // The equivalence must not be two empty defaults agreeing: assert
        // the fixture actually produced live values for the interesting
        // fields before trusting the comparison above.
        #expect(sync.branch == "main")
        #expect(sync.upstream == "origin/main")
        #expect(sync.ahead == 0)
        #expect(sync.behind == 0)
        #expect(sync.stashCount == 1)
        #expect(sync.untrackedCount == 1)
        #expect(sync.stagedCount == 1)
        #expect(sync.unstagedCount == 1)
        #expect(!sync.headOID.isEmpty)
        #expect(!sync.rawHead.isEmpty)
    }

    @Test func loaderEngineTwinsAsyncMatchSync() async throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([
            FixtureRepository.Commit("base"),
            FixtureRepository.Commit("second", files: ["second.txt": "two\n"]),
            FixtureRepository.Commit("third", files: ["third.txt": "three\n"]),
        ])
        let path = fixture.url.path
        let revision = try fixture.revParse("HEAD")

        // WorktreeContext.resolve — the Sidebar loader's first call.
        let syncContext = try syncResolve(path: path)
        let asyncContext = try await WorktreeContext.resolve(path: path)
        #expect(asyncContext == syncContext)
        #expect(syncContext.topLevel == path)

        // worktreeList — the Sidebar loader's last call.
        let syncWorktrees = try syncWorktreeList(path: path)
        let asyncWorktrees = try await worktreeList(path: path)
        #expect(asyncWorktrees == syncWorktrees)
        #expect(syncWorktrees.count == 1)

        // RefSnapshot.capture — the Sidebar loader's middle call.
        let syncRefs = try syncRefs(in: syncContext)
        let asyncRefs = try await RefSnapshot.capture(in: asyncContext)
        #expect(asyncRefs == syncRefs)
        #expect(syncRefs.refs.contains { $0.name == "refs/heads/main" })

        // gitStatus — the summary loader's second call.
        try fixture.writeUntracked(["untracked.txt": "u\n"])
        let syncStatus = try syncStatus(at: path)
        let asyncStatus = try await gitStatus(at: path)
        #expect(asyncStatus.entries.count == syncStatus.entries.count)
        #expect(asyncStatus.entries.map(\.path) == syncStatus.entries.map(\.path))
        #expect(syncStatus.entries.map(\.path) == ["untracked.txt"])

        // CommitLog.run — the History loader.
        let syncLog = try syncLog(path: path)
        let asyncLog = try await CommitLog.run(path: path, rangeArguments: ["-100", "HEAD"])
        #expect(asyncLog == syncLog)
        #expect(syncLog.count == 3)

        // graphRows — the graph loader.
        let syncGraph = try syncGraph(at: path)
        let asyncGraph = try await graphRows(at: path, limit: 100)
        #expect(asyncGraph == syncGraph)
        #expect(syncGraph.count == 3)

        // commitDiff — the Detail loader.
        let syncDiff = try syncDiff(at: path, revision: revision)
        let asyncDiff = try await commitDiff(at: path, revision: revision)
        #expect(asyncDiff == syncDiff)
        #expect(!syncDiff.isEmpty, "the third commit's diff should parse hunks")
        #expect(syncDiff.first?.path == "third.txt")
    }
}
