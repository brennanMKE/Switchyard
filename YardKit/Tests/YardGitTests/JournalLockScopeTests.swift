// JournalLockScopeTests.swift — the journal lock wraps the whole checkpoint flow (#0176)
//
// Deliberately NOT @testable: the checkpoint flow is exercised exactly as its
// public callers (#0168, #0169) call it — the #0116 failure class.
//
// Determinism: neither test waits for a race to happen. The contending holder
// is a real second process that takes the journal flock and confirms it over a
// pipe barrier before the competing checkpoint starts, so the hold spans the
// whole attempt — the interleaving is fixed by the barrier and by the lock
// itself, never by timing. A future-timestamped seed entry makes every id the
// flow can mint the exact increment of the newest, so the assertions compare
// exact ids, not shapes.

import Foundation
import Testing
import YardGit

struct JournalLockScopeTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    private func exists(_ oid: String, in repo: FixtureRepository) throws -> Bool {
        try git.capture(["cat-file", "-e", oid], workingDirectory: repo.url.path).exitCode == 0
    }

    /// The id `generate(after:)` mints when the newest entry outsorts the
    /// clock: exactly the increment of `id` (#0028's monotonic rule). `now` is
    /// pinned to the epoch so the candidate always sorts below a
    /// future-timestamped `id` — deterministic, and public API only
    /// (`incremented()` itself is internal, and this file is not @testable).
    private func next(after id: JournalEntryID) -> JournalEntryID {
        JournalEntryID.generate(now: Date(timeIntervalSince1970: 0), after: id)
    }

    /// The blob oid `checkpoint` will write for the repository's current ref
    /// state — computed WITHOUT writing (`hash-object` without `-w`), so its
    /// later presence in the object database is the checkpoint's doing alone.
    /// Journal anchor refs live in the namespace `RefSnapshot` excludes, so
    /// seeding entries does not perturb this oid.
    private func expectedRefsBlob(in repo: FixtureRepository, ctx: WorktreeContext) throws -> String {
        try #require(try git.run(
            ["hash-object", "--stdin"],
            workingDirectory: repo.url.path,
            standardInput: RefSnapshot.capture(in: ctx).serialized()).lines.first)
    }

    /// Spawns a second process that takes the journal flock exactly as
    /// `JournalLock` takes it, returning only once the child confirms it holds
    /// the lock — it prints `LOCKED` after its flock succeeds, and this does
    /// not return until that line is read, so the ordering is fixed by the
    /// pipe, not by sleeps. Mirrors `JournalLockTests` (private there). The
    /// child's flock is non-blocking and dies on failure, so a leaked hold
    /// elsewhere turns the barrier read into EOF and a red test, never a hang.
    private func spawnHolder(of lock: JournalLock) throws -> Process {
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
        var banner = Data()
        while banner.count < 7 {
            let chunk = out.fileHandleForReading.readData(ofLength: 7 - banner.count)
            if chunk.isEmpty { break }
            banner.append(chunk)
        }
        try #require(String(decoding: banner, as: UTF8.self) == "LOCKED\n")
        return holder
    }

    // MARK: - The write side: nothing touches the repository outside the lock

    /// The headline witness for #0167 decision 7. Narrow the lock to the final
    /// anchor write — capture, blob write, and id generation hoisted outside —
    /// and every prior test stays green: contention still throws
    /// `JournalLockError` and still anchors nothing. What that scoping cannot
    /// avoid is writing the refs blob *while another process holds the lock*,
    /// and that is what this asserts on: the blob's oid is computed up front
    /// without writing it, and it must not exist while the hold spans the
    /// whole attempt.
    @Test func aCheckpointBlockedByAnotherProcessWritesNothingBeforeItHoldsTheLock() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let lock = JournalLock(context: ctx)
        // Creates <commonDir>/switchyard/ and the lock file for the holder.
        try lock.withLock {}

        // Future-timestamped newest entry: every id generate(after:) can mint
        // from here on is exactly its increment (#0028's monotonic rule).
        let future = JournalEntryID.generate(now: Date(timeIntervalSince1970: 4_000_000_000))
        let seeded = try JournalAnchor.write(
            .init(metadataJSON: Data("stub".utf8)), id: future, in: ctx)

        let refsBlob = try expectedRefsBlob(in: repo, ctx: ctx)
        try #require(try !exists(refsBlob, in: repo))  // vacuity guard on the oid

        let holder = try spawnHolder(of: lock)
        defer {
            if holder.isRunning {
                kill(holder.processIdentifier, SIGKILL)
                holder.waitUntilExit()
            }
        }

        // The hold spans the whole competing attempt: the timeout is certain.
        #expect(throws: JournalLockError.self) {
            try JournalCheckpoint.checkpoint(
                operation: "checkpoint", lockTimeout: .milliseconds(200), in: ctx)
        }

        // The teeth: a checkpoint that never held the lock has not touched
        // the repository at all — no refs blob, no entry.
        #expect(try !exists(refsBlob, in: repo))
        #expect(try JournalAnchor.list(in: ctx) == [seeded])

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        // Positive control, and proof the expected oid is the one the real
        // flow writes: with the lock free, the same call writes exactly that
        // blob and continues the id chain from the seed. Without this, the
        // two emptiness assertions above would also pass for a wrongly
        // computed oid or a checkpoint that writes nothing ever.
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        #expect(entry.id == next(after: future))
        #expect(try exists(refsBlob, in: repo))
        #expect(try JournalAnchor.list(in: ctx) == [seeded, entry])
    }

    // MARK: - The read side: the newest-id read happens under the lock

    /// The property decision 7 exists for: no other process can slip a write
    /// between the checkpoint's newest-id read and its anchor write. A live
    /// checkpoint runs on a second thread against a lock held by a second
    /// process; while it is blocked, a competing entry lands at exactly the id
    /// a stale read would mint. Reading under the lock, the checkpoint sees it
    /// and mints the next id; reading before the lock, it collides and the
    /// create refuses. The surviving entry list says which happened — the
    /// assertion is on the list, not on any thrown error.
    @Test func aCompetingEntryWrittenDuringTheLockWaitIsSeenByTheCheckpointsIdRead() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let lock = JournalLock(context: ctx)
        try lock.withLock {}

        let future = JournalEntryID.generate(now: Date(timeIntervalSince1970: 4_000_000_000))
        try JournalAnchor.write(.init(metadataJSON: Data("stub".utf8)), id: future, in: ctx)

        let holder = try spawnHolder(of: lock)
        defer {
            if holder.isRunning {
                kill(holder.processIdentifier, SIGKILL)
                holder.waitUntilExit()
            }
        }

        // A real checkpoint, live on its own thread, generous timeout. Its
        // outcome is read from the entry list below, so a thrown error here
        // must not crash the thread — `try?` is deliberate.
        let done = DispatchSemaphore(value: 0)
        let racer = Thread {
            _ = try? JournalCheckpoint.checkpoint(
                operation: "racer", lockTimeout: .seconds(10), in: ctx)
            done.signal()
        }
        racer.start()

        // Not a synchronisation point: the correct flow does nothing until it
        // holds the lock, so this margin cannot affect a green run whatever
        // its value. It exists to catch the mutant deterministically — a
        // newest-id read hoisted outside the lock completes in well under
        // half a second, so by the time the competing entry lands the mutant
        // has certainly already read the stale newest.
        Thread.sleep(forTimeInterval: 0.5)

        // The competing write the checkpoint's read must observe.
        try JournalAnchor.write(
            .init(metadataJSON: Data("stub2".utf8)), id: next(after: future), in: ctx)

        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        try #require(done.wait(timeout: .now() + 30) == .success)

        // Read under the lock: the racer saw future+1 and minted future+2.
        // Read outside it: the racer minted future+1, collided, and the
        // list would hold two entries instead of three.
        #expect(try JournalAnchor.list(in: ctx).map(\.id)
            == [future, next(after: future), next(after: next(after: future))])
    }
}
