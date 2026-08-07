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

    // MARK: - Test 6: renamed file regression (defect A)

    /// A `2` record carries two NUL-terminated paths: original, then new. We
    // MARK: - Rename records
    //
    // These bytes are copied from a real `git status --porcelain=v2 -z` run, via
    // `od -c`, after `git mv orig.txt renamed.txt`:
    //
    //   2 R. N... 100644 100644 100644 <h1> <h2> R100 renamed.txt\0orig.txt\0
    //
    // Ten space-separated tokens before the first NUL, the tenth being the NEW
    // path, and the original path in a second NUL-terminated field after it.
    // **New first, original second** — and the `R100` similarity score is the
    // token that makes the count ten rather than nine.

    private static let renameHash = "35fbd83349cf5962cbef75d9f6340f48be890382"

    /// Builds a `2` record in git's real layout: `<fixed> R100 <new>\0<orig>\0`.
    private static func renameRecord(new: String, original: String) -> Data {
        var bytes: [UInt8] = Array(
            "2 R. N... 100644 100644 100644 \(renameHash) \(renameHash) R100 \(new)".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: Array(original.utf8))
        bytes.append(0x00)
        return Data(bytes)
    }

    @Test("a `2` record carries both the original and the new path of a rename")
    func parsesRenameWithBothPaths() throws {
        let status = try WorktreeStatusParser()
            .parse(Self.renameRecord(new: "b-file.txt", original: "a-file.txt"))

        #expect(status.entries.count == 1, "one rename record is one entry")
        let renamed = try #require(status.entries.first)

        #expect(renamed.path == "b-file.txt", "path is the new name")
        #expect(renamed.originalPath == "a-file.txt", "originalPath is the old name")
        #expect(renamed.pathBytes == Array("b-file.txt".utf8))
        #expect(renamed.originalPathBytes == Array("a-file.txt".utf8))

        // `R` in the XY field is a rename on the staged side. Before this was
        // added to `State(char:)` it fell through to `.unmodified`, so a renamed
        // file reported as unchanged on both sides.
        #expect(renamed.staged == .modified)
        #expect(renamed.worktree == .unmodified)
    }

    @Test("a space in the original path survives, because only the NUL ends it")
    func parsesRenameWithSpaceInOriginalName() throws {
        let status = try WorktreeStatusParser()
            .parse(Self.renameRecord(new: "new-name.txt", original: "old name.txt"))

        #expect(status.entries.count == 1)
        let entry = try #require(status.entries.first)
        #expect(entry.path == "new-name.txt")
        #expect(entry.originalPath == "old name.txt")
        #expect(entry.originalPathBytes == Array("old name.txt".utf8))
    }

    @Test("the original path is consumed by its own record, not emitted as a second one")
    func renameOriginalPathDoesNotLeakAsItsOwnRecord() throws {
        // The original path is chosen to look exactly like an untracked record.
        // Before `splitRecords` consumed the second field, this produced a
        // phantom third entry -- and the framing of everything after it was off
        // by one record.
        var data = Self.renameRecord(new: "renamed.txt", original: "? phantom.txt")
        data.append(contentsOf: Array("1 .M N... 100644 100644 100644 aaa bbb after.txt".utf8))
        data.append(0x00)

        let status = try WorktreeStatusParser().parse(data)

        #expect(status.entries.count == 2, "the rename and the record after it, and nothing else")
        #expect(status.entries.map(\.path) == ["renamed.txt", "after.txt"],
                "the record following a rename must still be framed correctly")
        #expect(status.entries.first?.originalPath == "? phantom.txt")
    }

    @Test("submodule state is read from the <sub> token, not flattened")
    func parsesSubmoduleState() throws {
        var data = Data()
        for record in ["1 .M SCMU 160000 160000 160000 aaa bbb sub",
                       "1 .M N... 100644 100644 100644 aaa bbb plain.txt"] {
            data.append(contentsOf: Array(record.utf8))
            data.append(0x00)
        }
        let status = try WorktreeStatusParser().parse(data)

        #expect(status.entries.count == 2)
        let sub = try #require(status.entries.first?.submodule,
                               "an S<c><m><u> token must produce a SubmoduleState")
        #expect(sub.commitChanged)
        #expect(sub.hasModifications)
        #expect(sub.hasUntracked)
        #expect(status.entries.last?.submodule == nil, "N... is an ordinary path, not a submodule")
    }

    @Test("one non-UTF-8 path does not erase every other entry")
    func nonUTF8PathSurvivesAlongsideItsNeighbours() throws {
        // Git permits arbitrary bytes in a path. The parser used to decode the
        // whole input with String(data:encoding:.utf8) and return an EMPTY status
        // when that failed -- reported as success, and indistinguishable from a
        // clean worktree. One bad byte anywhere hid every other change.
        var data = Data()
        data.append(contentsOf: Array("1 .M N... 100644 100644 100644 aaa bbb before.txt".utf8))
        data.append(0x00)
        data.append(contentsOf: Array("1 .M N... 100644 100644 100644 aaa bbb ".utf8))
        data.append(contentsOf: [0xFF, 0xFE])          // not valid UTF-8
        data.append(0x00)
        data.append(contentsOf: Array("? after.txt".utf8))
        data.append(0x00)

        let status = try WorktreeStatusParser().parse(data)

        #expect(status.entries.count == 3, "the undecodable path must not take its neighbours with it")
        #expect(status.entries.map(\.path).first == "before.txt")
        #expect(status.entries.map(\.path).last == "after.txt")

        // The raw bytes are preserved even though the String form is lossy.
        let bad = try #require(status.entries.dropFirst().first)
        #expect(bad.pathBytes == [0xFF, 0xFE], "pathBytes must be lossless")
    }
}
