import Foundation
import Testing
@testable import YardGit

struct WorktreeStatusTests {
    let git = GitProcess()
    
    // MARK: - Test 1: Files matching repo.oids for basic staged/unstaged
    
    @Test func statusOfFilesMatchingOids() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        let repoGit = GitProcess()

        // modified.txt must be TRACKED before an edit reads as `.M`. Commit it
        // first — an uncommitted new file is `?`, not a modification, and the
        // original version of this test staged everything with `add -A` and then
        // asserted the file was unstaged.
        let modifiedPath = repo.url.appendingPathComponent("modified.txt")
        try "original".write(to: modifiedPath, atomically: true, encoding: .utf8)
        try repoGit.run(["add", "modified.txt"], workingDirectory: repo.url.path)
        try repoGit.run(["commit", "-m", "track modified.txt"], workingDirectory: repo.url.path)

        // Now edit it WITHOUT staging — this is the `.M` case.
        try "new content".write(to: modifiedPath, atomically: true, encoding: .utf8)

        // And stage a genuinely new file — the `A.` case.
        let addedPath = repo.url.appendingPathComponent("added.txt")
        try "newly added".write(to: addedPath, atomically: true, encoding: .utf8)
        try repoGit.run(["add", "added.txt"], workingDirectory: repo.url.path)
        
        // Run git status in the repo's main worktree
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(output.standardOutput)
        
        // Find entries by path  
        let modifiedEntry = status.entries.first { $0.path == "modified.txt" }
        #expect(modifiedEntry != nil, "should find modified file")
        
        let modified = try #require(modifiedEntry)
        #expect(modified.staged == .unmodified, "worktree modification should show staged as unmodified")
        #expect(modified.worktree == .modified, "file modified in worktree should show staged as modified")
        
        let addedEntry = status.entries.first { $0.path == "added.txt" }
        #expect(addedEntry != nil, "should find added file")
        
        let added = try #require(addedEntry)
        #expect(added.staged == .added, "new file in index should show staged as added")
        #expect(added.worktree == .unmodified, "staged file shouldn't show worktree modification")
    }
    
    // MARK: - Test 2: Staged modifications (modify THEN stage, not just path write)
    
    @Test func stagedModificationAfterModifyAndStage() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        let repoGit = GitProcess()

        // FixtureRepository.linear() does NOT create base.txt. Reading it threw
        // NSCocoaErrorDomain 260 and aborted the test rather than failing an
        // assertion — create and commit the file this test needs.
        let basePath = repo.url.appendingPathComponent("base.txt")
        try "original\n".write(to: basePath, atomically: true, encoding: .utf8)
        try repoGit.run(["add", "base.txt"], workingDirectory: repo.url.path)
        try repoGit.run(["commit", "-m", "add base.txt"], workingDirectory: repo.url.path)

        // Modify it, then stage the modification — this is the `M.` case.
        var content = try String(contentsOf: basePath, encoding: .utf8)
        content += "modified line\n"
        try content.write(to: basePath, atomically: true, encoding: .utf8)
        try repoGit.run(["add", "base.txt"], workingDirectory: repo.url.path)
        
        // Capture status after staging
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(output.standardOutput)
        
        // Find base.txt entry - it should be staged as modified, worktree clean
        let baseEntry = status.entries.first { $0.path == "base.txt" }
        #expect(baseEntry != nil, "should find base file")
        
        let base = try #require(baseEntry)
        #expect(base.staged == WorktreeStatusEntry.State.modified, "file should be staged as modified after staging")
        #expect(base.worktree == WorktreeStatusEntry.State.unmodified, "worktree should be clean after staging")
    }
    
    // MARK: - Test 3: Untracked files detection
    
    @Test func untrackedFilesDetected() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        // Create a truly untracked file (not added to index)  
        let untrackedPath = repo.url.appendingPathComponent("untracked.txt")
        try "I'm not in the index".write(to: untrackedPath, atomically: true, encoding: .utf8)
        
        // Capture status  
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(output.standardOutput)
        
        // Find untracked entry  
        let untrackedEntry = status.entries.first { $0.path == "untracked.txt" }
        #expect(untrackedEntry != nil, "should find untracked file")
        
        let entry = try #require(untrackedEntry)
        // Untracked is a worktree-side fact: the file is absent from the index,
        // so `.untracked` belongs on `worktree` and `staged` stays `.unmodified`.
        // Reporting `.untracked` on the staged side would describe the index as
        // holding something it does not have.
        #expect(entry.worktree == WorktreeStatusEntry.State.untracked, "untracked belongs to the worktree side")
        #expect(entry.staged == .unmodified, "an untracked file is not in the index at all")
    }
    
    // MARK: - The five real record types

    /// Captured verbatim from `git status --porcelain=v2 -z --ignored` against a
    /// repository holding all five states at once. Each element is one complete
    /// NUL-terminated record — the path is part of the record, not a separate one.
    /// Two earlier rounds wrote a parser against an invented two-chunk shape and
    /// passed their own tests while failing on anything git actually emits.
    private static let realRecords: [String] = [
        "1 .M N... 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 df967b96a579e45a18b8251732d16804b2e56a55 base.txt",
        "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 19d9cc8584ac2c7dcf57d2680375e80f099dc481 staged.txt",
        "u AA N... 000000 100644 100644 100644 0000000000000000000000000000000000000000 ba2906d0666cf726c7eaadd2cd3db615dedfdf3a 2299c37978265a95cbe835a4b0f0bbf15aad5549 conflict.txt",
        "? untracked.txt",
        "! ignored.txt",
    ]

    private static func realBuffer() -> Data {
        var bytes: [UInt8] = []
        for record in realRecords {
            bytes.append(contentsOf: Array(record.utf8))
            bytes.append(0x00)
        }
        return Data(bytes)
    }

    @Test("all five porcelain v2 record types are parsed with exact paths")
    func parsesEveryRealRecordType() throws {
        let status = try WorktreeStatusParser().parse(Self.realBuffer())

        #expect(status.entries.count == 5,
                "expected one entry per record, got \(status.entries.map(\.path))")

        func entry(_ path: String) throws -> WorktreeStatusEntry {
            try #require(status.entries.first { $0.path == path },
                         "no entry for \(path); paths were \(status.entries.map(\.path))")
        }

        // Paths must be exactly the filename — no `N...`, no mode fields. An
        // earlier round returned "N... 100644 100644 100644 df967b... staged.txt".
        let unstaged = try entry("base.txt")
        #expect(unstaged.staged == .unmodified)
        #expect(unstaged.worktree == .modified)

        let staged = try entry("staged.txt")
        #expect(staged.staged == .added)
        #expect(staged.worktree == .unmodified)

        let conflicted = try entry("conflict.txt")
        #expect(conflicted.staged == .conflicted,
                "a `u` record is conflicted; the leading token carries that, not the XY field")

        let untracked = try entry("untracked.txt")
        #expect(untracked.worktree == .untracked)

        let ignored = try entry("ignored.txt")
        #expect(ignored.worktree == .ignored)
    }

    @Test("a record type dropped by the parser is caught, not silently ignored")
    func everyRecordTypeIsAccountedFor() throws {
        let status = try WorktreeStatusParser().parse(Self.realBuffer())
        let paths = Set(status.entries.map(\.path))
        for expected in ["base.txt", "staged.txt", "conflict.txt", "untracked.txt", "ignored.txt"] {
            #expect(paths.contains(expected), "\(expected) was dropped by the parser")
        }
    }
}
