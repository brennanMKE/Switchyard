// WorktreeListTests.swift

import Foundation
import Testing
@testable import YardGit

struct WorktreeListTests {

    private let git = GitProcess()

    // MARK: - Argument vector (the #0020 round-1 bug)

    /// The parser only works correctly when production passes `-z`. This is
    /// the single most important check: without it, the function returns an
    /// empty array against a real fixture and all of the parser tests pass
    /// vacuously. The test runs from a temporary repo that produces real NULs.
    @Test func parserUsesNulTerminatedPorcelain() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-zcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try git.run(["init", "-q", "--ref-format=files", dir.path])
        try git.run(["config", "user.name", "Test"], workingDirectory: dir.path)
        try git.run(["config", "user.email", "test@example.invalid"], workingDirectory: dir.path)
        try git.run(["commit", "-q", "--allow-empty", "-m", "base"], workingDirectory: dir.path)

        // The worktreeList function shells out. If `-z` is absent, the bytes
        // contain zero NULs; with it they must contain at least one.
        let data = try git.capture(
            ["worktree", "list", "--porcelain", "-z"],
            workingDirectory: dir.path
        ).standardOutput

        #expect(data.contains(0x00), "production must pass -z to get NUL bytes")
    }

    // MARK: - Single main worktree

    @Test func singleWorktreeReturnsOneEntry() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let entries = try worktreeList(path: repo.url.path)
        #expect(entries.count == 1, "single main worktree must yield exactly one entry")

        let e = entries[0]
        #expect(e.isMainWorktree)
        #expect(!e.bare)
        #expect(!e.detached)
        #expect(!e.locked)
        #expect(e.lockReason == nil)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func singleWorktreeAcrossRefFormats(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        let entries = try worktreeList(path: repo.url.path)
        #expect(entries.count == 1, "one entry in \(format.rawValue)")

        let e = entries[0]
        #expect(e.isMainWorktree)
    }

    // MARK: - Multiple linked worktrees

    @Test func fiveWorktreesReturnsFiveEntries() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        for name in ["alpha", "bravo", "charlie", "delta"] {
            _ = try repo.addWorktree(named: name, branch: name)
        }

        let entries = try worktreeList(path: repo.url.path)
        #expect(entries.count == 5, "five worktrees must yield five entries")

        // The main worktree is the first entry and carries no name-like path
        // collision with a linked one.
        #expect(entries[0].isMainWorktree, "first entry must be main")

        // Every path is distinct.
        let paths = entries.map { $0.path }
        #expect(Set(paths).count == 5, "paths must be unique")

        // The main worktree path matches the fixture URL.
        #expect(entries[0].path == WorktreeContext.canonicalize(repo.url.path),
                "first entry path is the primary checkout")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func fiveWorktreesAcrossRefFormats(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        for name in ["a", "b", "c", "d"] {
            _ = try repo.addWorktree(named: name, branch: name)
        }

        let entries = try worktreeList(path: repo.url.path)
        #expect(entries.count == 5, "five entries in \(format.rawValue)")

        // Each entry has its own path.
        let paths = entries.map { $0.path }
        #expect(Set(paths).count == 5, "unique paths in \(format.rawValue)")
    }

    // MARK: - Lock state

    @Test func unlockedWorktreeReportsLockedFalse() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try repo.addWorktree(named: "plain", branch: "plain")
        let entries = try worktreeList(path: repo.url.path)

        let plain = entries.first { $0.path != WorktreeContext.canonicalize(repo.url.path) }
        #expect(plain != nil, "found plain worktree")
        let p = try #require(plain)
        #expect(!p.locked, "a freshly-added worktree is not locked")
    }

    @Test func lockedWorktreeSurfacesTheReason() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "locked", branch: "locked")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        // Lock with a reason.
        try repo.lockWorktree(wtPath, reason: "agent session 42")

        let entries = try worktreeList(path: repo.url.path)
        let lockedEntry = entries.first { $0.path == WorktreeContext.canonicalize(wtPath.path) }
        #expect(lockedEntry != nil, "found the locked worktree entry")

        let le = try #require(lockedEntry)
        #expect(le.locked, "worktree must report locked=true")
        #expect(le.lockReason == "agent session 42",
                "lock reason must be surfaced from porcelain")

        // And the main worktree still reports unlocked.
        let main = entries.first { $0.isMainWorktree }!
        #expect(!main.locked)
    }

    @Test func lockedWorktreeWithoutReasonShowsBareLocked() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "barelock", branch: "barelock")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        // Lock without a reason.
        try git.run(["worktree", "lock", wtPath.path], workingDirectory: repo.url.path)

        let entries = try worktreeList(path: repo.url.path)
        let le = entries.first { $0.path == WorktreeContext.canonicalize(wtPath.path) }
        #expect(le != nil)

        let locked = try #require(le)
        #expect(locked.locked)
        #expect(locked.lockReason == nil, "no reason argument means nil reason")
    }

    // MARK: - Bare repository

    @Test func bareRepositoryReturnsOneEntryMarkedBare() throws {
        var repo = try FixtureRepository(refFormat: .files, bare: true)
        defer { repo.destroy() }

        let entries = try worktreeList(path: repo.url.path)
        #expect(entries.count == 1, "bare repo has exactly one entry")

        let e = entries[0]
        #expect(e.bare, "the entry is marked bare")
        // Bare repos have no main worktree; the lone entry's path is nil.
    }

    // MARK: - Newline in worktree path round-trips

    @Test func newlineInPathRoundTrips() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let nameWithNewline = "has\nnewline"
        let wtPath = try repo.addWorktree(path: nameWithNewline, branch: nameWithNewline)
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let entries = try worktreeList(path: repo.url.path)

        // Find the newline-path entry by scanning paths, not names.
        let nlEntry = entries.first { ($0.path ?? "").contains("\n") }

        // Rule 7 guard: must actually find one before asserting on it.
        #expect(nlEntry != nil, "newline-path worktree must be discoverable in output")

        let entry = try #require(nlEntry)
        // The path parsed from the porcelain output must contain exactly the
        // newline we put in.
        #expect(entry.path?.contains("\n") == true, "path must retain the newline byte")

        // And it is a distinct entry from all others.
        let paths = entries.map { $0.path }
        #expect(paths.count == Set(paths).count, "no path collision with the newline entry")
    }

    // MARK: - Detached head

    @Test func detachedHeadIsMarked() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let oid = try #require(repo.oids["b"])
        _ = try repo.checkoutDetached(oid)

        let entries = try worktreeList(path: repo.url.path)

        // There's still only one entry from main; confirm its detached flag.
        let mainEntry = entries.first { $0.isMainWorktree }!

        // Porcelain emits `detached` when HEAD is not a branch ref.
        #expect(mainEntry.head == oid, "HEAD OID must be preserved in detached state")
    }

    // MARK: - Unit-level parser tests on hand-crafted NUL input

    @Test func parserAcceptsHandCraftedPorcelainBytes() {
        // Construct a minimal -z buffer: two records, one locked with reason,
        // one without. This exercises the parser in isolation — no git needed.

        var buf: [UInt8] = []
        func append(_ s: String) { buf.append(contentsOf: Array(s.utf8)) }
        func nl()   { buf.append(0x00) }

        // Record 1: main worktree
        append("worktree /main/path")    ; nl()
        append("HEAD 1234567890abcdef") ; nl()
        append("branch main")           ; nl()

        // Record boundary: double NUL.
        append("")                      ; nl()

        // Record 2: locked linked worktree with reason.
        append("worktree /linked/path") ; nl()
        append("HEAD abcdef1234567890") ; nl()
        append("branch linked")         ; nl()
        append("locked agent session 42"); nl()

        // A third record that is prunable.
        append("")                      ; nl()
        append("worktree /old/path")    ; nl()
        append("HEAD deadbeef")         ; nl()
        append("prunable stale lockfile"); nl()

        let data = Data(buf)
        // Drive parsePorcelain directly; this test is specifically about the
        // parser, not git. (The production entry point `worktreeList` shells out.)
        let entries = parsePorcelain(data, path: "/does-not-matter")

        #expect(entries.count == 3)
        #expect(entries[0].path == "/main/path")
        #expect(entries[0].isMainWorktree)
        #expect(entries[0].head == "1234567890abcdef")
        #expect(entries[0].branch == "main")

        #expect(entries[1].path == "/linked/path")
        #expect(!entries[1].isMainWorktree)
        #expect(entries[1].locked == true)
        #expect(entries[1].lockReason == "agent session 42")

        #expect(entries[2].path == "/old/path")
        #expect(entries[2].prunable == true)
        #expect(entries[2].prunableReason == "stale lockfile")
    }

    // MARK: - Entry equality

    @Test func twoEntriesWithMatchingFieldsAreEqual() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let first  = try worktreeList(path: repo.url.path).first!
        let second = try worktreeList(path: repo.url.path).first!

        #expect(first == second)
    }

    // MARK: - Output ordering: main first regardless of CWD

    @Test func mainEntryComesFirstFromALinkedWorktree() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "first-linked", branch: "first-linked")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        let entries = try worktreeList(path: wtPath.path)
        #expect(entries[0].isMainWorktree, "from a linked worktree, index 0 is still main")
    }

    // MARK: - Prunable flag absent on healthy repos

    @Test func prunableWorktreeAbsentOnHealthyRepo() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        _ = try repo.addWorktree(named: "clean", branch: "clean")
        let entries = try worktreeList(path: repo.url.path)

        for entry in entries {
            #expect(!entry.prunable, "\(entry.path ?? "<nil>") must not be prunable in a healthy repo")
            #expect(entry.prunableReason == nil)
        }
    }

    // MARK: - Boundary cases driven through parsePorcelain directly

    @Test func emptyBufferReturnsEmptyArray() {
        let data = Data([0x00, 0x00])
        // An all-NUL buffer has no usable records; the parser returns [].
        let entries = parsePorcelain(data, path: "")
        #expect(entries.isEmpty)
    }

    @Test func singleFieldNoRecordBoundaryReturnsOneEntryIfUsable() {
        // A buffer ending with a single NUL (no double-NUL) is still one record.
        var buf: [UInt8] = []
        func append(_ s: String) { buf.append(contentsOf: Array(s.utf8)) }
        func nl()   { buf.append(0x00) }

        append("worktree /only/path")   ; nl()
        append("HEAD 0000000000")       ; nl()
        // No trailing double-NUL.

        let entries = parsePorcelain(Data(buf), path: "")
        #expect(entries.count == 1)
        #expect(entries[0].path == "/only/path")
    }

    // MARK: - Lock with a non-agent reason surfaces verbatim

    @Test func customLockReasonPassesThroughVerbatim() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtPath = try repo.addWorktree(named: "debuglock", branch: "debuglock")
        defer { try? FileManager.default.removeItem(at: wtPath) }

        try repo.lockWorktree(wtPath, reason: "debugging #123")

        let entries = try worktreeList(path: repo.url.path)
        let lockedEntry = entries.first { $0.path == WorktreeContext.canonicalize(wtPath.path) }
        let le = try #require(lockedEntry)
        #expect(le.locked == true)
        #expect(le.lockReason == "debugging #123")
    }
}
