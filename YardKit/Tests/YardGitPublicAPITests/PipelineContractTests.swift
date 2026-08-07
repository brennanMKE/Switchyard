// PipelineContractTests.swift
//
// This target imports YardGit WITHOUT `@testable`, so it sees exactly what an
// out-of-module caller sees. That is the whole point: `@testable` grants internal
// access, so a test using it cannot notice a `public` type whose members are not.
//
// **Any new public API in YardGit gets a line here**, the same way a new command
// gets its skill regenerated. See #0116.
// PipelineContractTests.swift — exercises the public surface of `YardGit`
// imported WITHOUT @testable, so any member that drops back to internal shows
// up as a compile error in this file. If it compiles, the public API contract
// holds.

import Foundation
import Testing
import YardGit

/// Sets up an isolated temp git repo, initialises it with `git init`, and
/// stages one file so the status is non-empty. The caller is responsible for
/// deleting the temp dir at the end of its test if they need to avoid stray
/// directories. Throws on any git failure so a broken setup doesn't mask as a
/// false-positive public-API pass.
private func makeTempRepo() throws -> String {
    // A per-run temporary directory. An absolute path baked in here would make
    // the merged suite write into whichever worktree happened to produce it,
    // and would not exist on any other machine.
    let buildDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("yard-pubapi-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

    let repo = buildDir.appendingPathComponent("repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    // `init` creates .git inside the working dir itself. Use buildDir so
    // we start in a clean, empty directory.
    try gitRun(["init", "-q"], in: repo.path)

    // Make sure there's a file to make visible once the test starts consuming the path.
    let marker = repo.appendingPathComponent("marker.txt")
    try "hello\n".write(to: marker, atomically: true, encoding: .utf8)
    try gitRun(["add", "marker.txt"], in: repo.path)

    // Stash the working dir, commit so we get stable porcelain output.
    try gitRun(["commit", "-q", "--allow-empty", "-m", "initial"], in: repo.path)

    // Drop an untracked file so status() actually returns entries to inspect.
    let scratch = repo.appendingPathComponent("scratch.txt")
    try "untracked\n".write(to: scratch, atomically: true, encoding: .utf8)

    return repo.path
}

/// Runs `git` with the given arguments in a directory and throws if it exits
/// non-zero. This helper is private to the test target — it has no YardGit
/// dependency, so exposing it wouldn't change what's publicly reachable.
private func gitRun(_ args: [String], in dir: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: dir)

    let errPipe = Pipe()
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()
    let exitCode = process.terminationStatus
    _ = errPipe.fileHandleForReading.readDataToEndOfFile()

    guard exitCode == 0 else {
        throw NSError(domain: "pubapi", code: Int(exitCode))
    }
}

// MARK: - WorktreeStatusEntry

@Test("WorktreeStatusEntry fields are public — path, staged, worktree")
func entryFieldsPublic() throws {
    let e = WorktreeStatusEntry(path: "foo.swift")

    #expect(e.path == "foo.swift")
    #expect(!e.pathBytes.isEmpty)
    #expect(e.staged == .unmodified)
    #expect(e.worktree == .unmodified)
}

@Test("WorktreeStatusEntry init is public — populated fields reachable")
func entryInitPublic() throws {
    let orig = "original.txt"
    let origBytes: [UInt8] = [0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x61, 0x6C, 0x2E, 0x74, 0x78, 0x74]
    let e = WorktreeStatusEntry(
        path: "renamed.txt",
        pathBytes: [0x72, 0x65],
        originalPath: orig,
        originalPathBytes: origBytes
    )

    #expect(e.path == "renamed.txt")
    #expect(e.originalPath == orig)
    #expect(e.originalPathBytes == origBytes)
}

@Test("WorktreeStatusEntry.State cases are public and enumerable")
func stateAllCasesPublic() {
    let cases = WorktreeStatusEntry.State.allCases
    #expect(cases.count == 7)

    for c in cases {
        _ = c // reaches — every member is on the public enum.
    }
}

@Test("WorktreeStatusEntry.State initialisers are public")
func stateInitializersPublic() throws {
    let m = WorktreeStatusEntry.State(rawValue: "M")
    #expect(m == .modified)

    let q = WorktreeStatusEntry.State(rawValue: "?")
    #expect(q == .untracked)

    let i = WorktreeStatusEntry.State.special(char: "!")
    #expect(i == .ignored)

    let u = WorktreeStatusEntry.State.special(char: "u")
    #expect(u == .conflicted)

    let d = WorktreeStatusEntry.State(rawValue: "D") ?? .unmodified
    #expect(d == .deleted)

    let a = WorktreeStatusEntry.State(rawValue: "A") ?? .unmodified
    #expect(a == .added)

    #expect(WorktreeStatusEntry.State.allCases.count == 7)
}

@Test("WorktreeStatusEntry.SubmoduleState is public and equatable")
func submoduleStatePublic() throws {
    let clean = WorktreeStatusEntry.SubmoduleState.clean
    #expect(clean.commitChanged == false)
    #expect(clean.hasModifications == false)
    #expect(clean.hasUntracked == false)

    let dirty = WorktreeStatusEntry.SubmoduleState(subToken: "SCMU")
    #expect(dirty != nil)

    let bad = WorktreeStatusEntry.SubmoduleState(subToken: "NAKED")
    #expect(bad == nil)

    // Equatable comparison only compiles when the Synthesised `==` is public.
    #expect(clean == WorktreeStatusEntry.SubmoduleState.clean)
}

// MARK: - WorktreeStatus

@Test("WorktreeStatus entries and init are public")
func worktreeStatusPublic() throws {
    // Two ways in, and both must be public. The array-literal conformance was
    // already public while the real initialiser was not -- exactly the asymmetry
    // this issue exists to remove, and a test that only used the literal could
    // not notice.
    let viaLiteral: WorktreeStatus = [WorktreeStatusEntry(path: "x"), WorktreeStatusEntry(path: "y")]
    #expect(viaLiteral.entries.count == 2)

    let viaInit = WorktreeStatus(entries: [WorktreeStatusEntry(path: "x")])
    #expect(viaInit.entries.map(\.path) == ["x"])
}

// MARK: - WorktreeStatusParser

@Test("WorktreeStatusParser is public and .parse can be called")
func parserIsPublic() throws {
    let parser = WorktreeStatusParser()

    // A `WorktreeStatus(entries: [])` is a valid parse result for empty data.
    let parsed = try parser.parse(Data())

    #expect(parsed.entries.isEmpty)
}

// MARK: - Git-level public functions

@Test("gitStatus returns accessible entries (no @testable access)")
func gitStatusReturnsAccessibleEntries() throws {
    let repoPath = try makeTempRepo()

    // `gitStatus` is the top-level free function exported from YardGit. It
    // must compile against an out-of-module caller, and reaching `.entries`
    // on the returned value proves that property is public.
    let status = try gitStatus(at: repoPath)

    let entries = status.entries
    #expect(!entries.isEmpty, "repo should contain at least one tracked file")

    for e in entries {
        #expect(!e.path.isEmpty, "each status entry must have a path")
    }
}

@Test("gitStatus(includeIgnored:true) returns at least as many entries")
func gitStatusIncludeIgnored() throws {
    let repoPath = try makeTempRepo()

    // Add a hidden file so the --ignored form has something to report.
    let hidden = URL(fileURLWithPath: repoPath).appendingPathComponent(".hidden")
    try "x\n".write(to: hidden, atomically: true, encoding: .utf8)

    // Don't commit it - leave as uncommitted work so status() returns entries.
    let status = try gitStatus(at: repoPath, includeIgnored: false)
    #expect(status.entries.count > 0, "non-empty repo should report at least one entry")

    let statusIgnored = try gitStatus(at: repoPath, includeIgnored: true)
    #expect(statusIgnored.entries.count >= status.entries.count,
            "adding --ignored must never return fewer entries")

    try FileManager.default.removeItem(at: hidden)
}

@Test("whereAmI is public and its fields are reachable")
func whereAmIPublic() throws {
    let repoPath = try makeTempRepo()

    // `whereAmI(path:)` is the out-of-module entry point for repository-level
    // discovery. It must compile without @testable access, and the returned
    // value's fields are public by construction.
    let info = try whereAmI(path: repoPath)

    // The fixture makes exactly one commit on the default branch, so all three
    // of these have a knowable value. A wrong implementation gets each wrong:
    // a broken symbolic-ref read loses the branch, a broken rev-parse gives a
    // short or empty oid, and rawHead is the unresolved form of the same thing.
    #expect(info.branch != nil, "a fixture with one commit is on a branch, not detached")
    // `headOID` is the SHORT form -- whereAmI fills it from `rev-parse --short=7`.
    // Asserting 40 here failed, which is the point of asserting a value at all.
    #expect(info.headOID.count == 7, "headOID is the 7-character short object id")
    #expect(!info.rawHead.isEmpty, "rawHead should be non-empty")
}

@Test("worktreeList is public and returns [WorktreeEntry]")
func worktreeListPublic() throws {
    let repoPath = try makeTempRepo()

    // `worktreeList(path:)` is a public function exported from YardGit.
    let list = try worktreeList(path: repoPath)

    // A bare repo has a single main worktree.
    #expect(list.count >= 1, "there is at least the main worktree")

    // Each entry's `.path` must be reachable. Without @testable this line
    // would not compile if `.path` dropped out of the public surface.
    for entry in list {
        // `|| true` here would assert nothing. Every worktree in this fixture has
        // a commit, so head is a full oid and path is set.
        let head = try #require(entry.head, "a worktree with a commit reports a head")
        #expect(head.count == 40, "head is a full object id")
        #expect(entry.path != nil, "a non-bare worktree reports its path")
    }
}

@Test("worktreeList element .path is public")
func worktreeEntryPathPublic() throws {
    let repoPath = try makeTempRepo()
    let list = try worktreeList(path: repoPath)

    // Reaching .path on a WorktreeEntry confirms it's public (not internal).
    for entry in list {
        let path = entry.path ?? ""
        #expect(path.contains("repo-"), "path should reference the temp dir")
    }
}

@Test("yardWhere is public and its fields are reachable")
func yardWherePublic() throws {
    let repoPath = try makeTempRepo()

    // `yardWhere(path:)` is a public function. It must compile against an
    // out-of-module caller without @testable access.
    let whereInfo = try yardWhere(path: repoPath)

    // Reachability is proved by compiling; these assert the values as well.
    #expect(!whereInfo.gitDir.isEmpty, "gitDir is always resolved")
    #expect(!whereInfo.commonDir.isEmpty, "commonDir is always resolved")
    #expect(whereInfo.mainWorktreePath != nil, "a non-bare repo has a main worktree")
    let p = try #require(whereInfo.path, "a non-bare repo reports a working tree path")
    #expect(p.contains("repo-"), "worktree path should reference the temp dir")
}

@Test("WorktreeRemoveResult is public and its fields are reachable")
func worktreeRemovePublic() throws {
    let repoPath = try makeTempRepo()

    // `worktreeRemove(at:_:,force:)` is the public entry point for removal.
    // The worktree doesn't need to exist — it will return a success result
    // describing an unknown path. Reaching `.success` and friends on the
    // returned value proves those fields are public.
    let result = try worktreeRemove(at: repoPath, "does-not-exist")


    // Reaching `.description` via the error optional proves CustomStringDesc
    // is public when an error exists; we don't expect an error here.
    #expect(!result.success, "removing a non-existent worktree fails")

    if let error = result.error {
        #expect(error.description.count > 0)
    }

    #expect(result.worktreePath == "does-not-exist")
}
