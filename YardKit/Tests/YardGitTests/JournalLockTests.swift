// JournalLockTests.swift — #0032
//
// Deliberately NOT @testable: the lock is called by the journal write path as
// a public caller, so a member silently dropping to internal must fail here at
// compile time (the #0116 failure class).
//
// Determinism: no test here waits for a race to happen. Contention is created
// by *holding* the lock across the whole competing attempt — the competing
// acquire cannot ever succeed, so its timeout is certain, not probabilistic.
// The cross-process test uses a read barrier: the child prints `LOCKED` only
// after its flock succeeds, and the test does not proceed until it has read
// that line, so the ordering is fixed by the pipe, not by sleeps.

import Foundation
import Testing
import YardGit

struct JournalLockTests {

    private struct Boom: Error {}

    /// A lock (and its fixture) for a fresh repository's main worktree.
    private func makeLock(in repo: FixtureRepository) throws -> JournalLock {
        let context = try WorktreeContext.resolve(path: repo.url.path)
        return JournalLock(context: context)
    }

    // MARK: - Path resolution

    @Test func lockFileLivesInTheCommonDirSwitchyardDirectory() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let lock = JournalLock(context: context)
        #expect(lock.lockFilePath == context.commonDir + "/switchyard/journal.lock")
    }

    @Test func linkedWorktreeResolvesTheSameLockFileAsTheMainWorktree() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let worktree = try repo.addWorktree(named: "side", branch: "side")
        let mainContext = try WorktreeContext.resolve(path: repo.url.path)
        let sideContext = try WorktreeContext.resolve(path: worktree.path)
        // Guard against vacuity: the two contexts are genuinely different
        // worktrees with different $GIT_DIRs.
        #expect(mainContext.gitDir != sideContext.gitDir)
        let mainLock = JournalLock(context: mainContext)
        let sideLock = JournalLock(context: sideContext)
        // The journal is shared, so the lock must be per-repository: both
        // worktrees serialise on one file.
        #expect(mainLock.lockFilePath == sideLock.lockFilePath)
    }

    // MARK: - Contention and timeout

    @Test func heldLockTimesOutASecondAcquirerWithATypedError() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let lock = try makeLock(in: repo)
        try lock.withLock {
            // flock is per open-file-description, so a second acquire in the
            // same process contends exactly as another process would. The
            // holder spans this whole attempt: the timeout is certain.
            let error = try #require(throws: JournalLockError.self) {
                try lock.withLock(timeout: .milliseconds(120)) {}
            }
            #expect(error == .timedOut(
                path: lock.lockFilePath, timeout: .milliseconds(120)))
        }
    }

    // MARK: - Release

    @Test func lockIsReleasedWhenTheBodyReturns() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let lock = try makeLock(in: repo)
        let first = try lock.withLock { 41 }
        #expect(first == 41)
        // If the first hold leaked, this second acquire would time out.
        let second = try lock.withLock(timeout: .milliseconds(300)) { 42 }
        #expect(second == 42)
    }

    @Test func lockIsReleasedWhenTheBodyThrows() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let lock = try makeLock(in: repo)
        #expect(throws: Boom.self) {
            try lock.withLock { throw Boom() }
        }
        // A throwing body must release too, or the journal deadlocks on the
        // first failed write.
        try lock.withLock(timeout: .milliseconds(300)) {}
    }

    @Test func theLockFileIsNeverUnlinked() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let lock = try makeLock(in: repo)
        try lock.withLock {}
        // Unlink-and-recreate would let a late waiter lock the old unlinked
        // inode while a newcomer locks the new file — two holders at once. The
        // file staying behind is the contract, not an oversight.
        #expect(FileManager.default.fileExists(atPath: lock.lockFilePath))
    }

    // MARK: - Cross-process, and crashed holders

    @Test func aKilledHolderReleasesTheLockImmediately() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let lock = try makeLock(in: repo)
        // Creates <commonDir>/switchyard/ and the lock file.
        try lock.withLock {}

        // A real second process takes the same flock our API takes, tells us
        // once it holds it, and then sits until killed. The child's flock is
        // NON-blocking (LOCK_EX | LOCK_NB = 6) and dies if it cannot acquire:
        // nothing holds the lock at spawn time, so in a healthy tree it always
        // succeeds — but if a release regression leaks the lock, the child
        // dies, the barrier read below sees EOF instead of "LOCKED\n", and
        // this test goes red instead of hanging the suite on a blocked child.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            #"open(my $f, ">>", $ARGV[0]) or die "open: $!"; "#
                + #"flock($f, 6) or die "flock: $!"; "#
                + #"$| = 1; print "LOCKED\n"; sleep 30;"#,
            lock.lockFilePath,
        ]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer {
            if holder.isRunning {
                kill(holder.processIdentifier, SIGKILL)
                holder.waitUntilExit()
            }
        }

        // Barrier: proceed only once the child holds the lock.
        let banner = readExactly(7, from: out.fileHandleForReading)
        try #require(String(decoding: banner, as: UTF8.self) == "LOCKED\n")

        // Held by another process: our acquire must time out, not hang and
        // not succeed.
        let error = try #require(throws: JournalLockError.self) {
            try lock.withLock(timeout: .milliseconds(150)) {}
        }
        #expect(error == .timedOut(
            path: lock.lockFilePath, timeout: .milliseconds(150)))

        // SIGKILL the holder: no atexit handler, no cleanup code runs. The
        // kernel drops the flock when the process dies, so the lock is free
        // immediately — the stale-lock recovery path is that there is nothing
        // to recover.
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        try lock.withLock(timeout: .milliseconds(500)) {}
    }

    /// Reads exactly `count` bytes, looping over short pipe reads.
    private func readExactly(_ count: Int, from handle: FileHandle) -> Data {
        var data = Data()
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    // MARK: - Exit class

    @Test func bothErrorCasesMapToRepositoryError() {
        let timedOut = JournalLockError.timedOut(path: "/r/.git", timeout: .seconds(1))
        let io = JournalLockError.ioFailure(path: "/r/.git", operation: "open", errno: 13)
        #expect(timedOut.exitClass == .repositoryError)
        #expect(io.exitClass == .repositoryError)
    }
}
