// RerereTests.swift — the read-only rerere surface (#0065)
//
// Every assertion here runs against a real fixture repository and real git,
// against the shapes the #0065 probe measured (git 2.50.1): a first conflict
// records `preimage` and a MERGE_RR path→id record; resolve+commit records
// the `postimage` and clears MERGE_RR; re-raising the same conflict replays
// the recorded resolution into the working file while the index STILL holds
// the unmerged stages, and every `git rerere` text surface prints nothing —
// which is why the engine reads the rr-cache instead.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

/// Builds `base → (ours edit of f.txt) + (side edit of f.txt)` with rerere
/// enabled, merges, resolves `f.txt` to `a/R/c`, and commits — the recorded
/// resolution's fixture. The resolution content is a literal the replay
/// test asserts byte-for-byte.
private func recordedFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("base", files: ["f.txt": "a\nb\nc\n"]),
        .init("side", parents: ["base"], files: ["f.txt": "a\nB\nc\n"]),
        .init("ours", parents: ["base"], files: ["f.txt": "a\nX\nc\n"]),
    ])
    try git.run(["config", "rerere.enabled", "true"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    // The conflicting merge exits 1 by design; capture, never run.
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
    try "a\nR\nc\n".write(
        to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try git.run(["add", "f.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "resolved"], workingDirectory: repo.url.path)
    return repo
}

/// Resets the fixture back to the pre-merge commit and re-merges `side`,
/// re-raising the identical conflict — the merge machinery replays the
/// recorded resolution into the working file (measured: `Resolved 'f.txt'
/// using previous resolution.`).
private func reraise(in repo: FixtureRepository) throws {
    try git.run(["reset", "--hard", "HEAD~1"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
}

// MARK: - enabled: the config is the truth

@Test func enabledReadsTrueFalseAndUnsetAsThreeDistinctFacts() throws {
    let enabledRepo = try FixtureRepository()
    defer { enabledRepo.destroy() }
    try git.run(
        ["config", "rerere.enabled", "true"], workingDirectory: enabledRepo.url.path)
    let enabled = try Rerere.enabled(at: enabledRepo.url.path, git: git, extraEnvironment: hermetic)
    #expect(enabled, "rerere.enabled true must read as enabled")

    let disabledRepo = try FixtureRepository()
    defer { disabledRepo.destroy() }
    try git.run(
        ["config", "rerere.enabled", "false"], workingDirectory: disabledRepo.url.path)
    let disabled = try Rerere.enabled(at: disabledRepo.url.path, git: git, extraEnvironment: hermetic)
    #expect(!disabled, "rerere.enabled false must read as disabled")

    let unsetRepo = try FixtureRepository()
    defer { unsetRepo.destroy() }
    let unset = try Rerere.enabled(at: unsetRepo.url.path, git: git, extraEnvironment: hermetic)
    #expect(!unset, "unset rerere.enabled is git's default: disabled")
}

// MARK: - status: recorded, merely known, and the disabled shape

@Test func aRecordedResolutionAppearsInStatusAfterResolveAndCommit() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    let status = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    #expect(status.enabled)
    #expect(status.entries.count == 1, "one resolved conflict, one rr-cache entry; got \(status.entries.count)")
    let entry = try #require(status.entries.first, "the recorded resolution must appear in status")
    #expect(entry.conflictID.count >= 40, "the conflict id is a full object id; got \(entry.conflictID)")
    #expect(entry.conflictID.allSatisfy { $0.isHexDigit })
    #expect(entry.state == .recorded, "a committed resolution is recorded, not merely known")
    #expect(entry.paths.isEmpty, "no conflict is live, so no path is attributed; got \(entry.paths)")
    #expect(entry.replayedPaths.isEmpty)
}

@Test func aFirstTimeConflictIsMerelyKnownWithItsPathAttributed() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    // A SECOND, different conflict: a fresh side branching from the same
    // base with a different change to the same line, merged into the
    // recorded state — rerere has never seen this pair, so it is
    // known-with-a-path (MERGE_RR) but recorded-nowhere. (`side` itself is
    // an ancestor of the recorded merge commit, so merging it again would
    // be "Already up to date." and raise nothing — measured.)
    let resolvedHead = try git.run(
        ["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first ?? ""
    let base = try #require(repo.oids["base"])
    try git.run(
        ["checkout", "-q", "-b", "secondside", base], workingDirectory: repo.url.path)
    try "a\nQ\nc\n".write(
        to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try git.run(["add", "f.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "second side"], workingDirectory: repo.url.path)
    let secondSide = try git.run(
        ["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines.first ?? ""
    try git.run(
        ["checkout", "-q", "--detach", resolvedHead], workingDirectory: repo.url.path)
    #expect(resolvedHead != secondSide)
    _ = try git.capture(
        ["merge", "--no-commit", secondSide], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)

    let status = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    // The recorded resolution from the first conflict is still recorded.
    let recorded = status.entries.filter { $0.state == .recorded }
    #expect(recorded.count == 1, "the first conflict's postimage persists; got \(status.entries)")
    // The live conflict is merely known: preimage only, no postimage yet.
    let known = try #require(
        status.entries.first { $0.state == .known },
        "a live first-time conflict must appear as known")
    #expect(known.paths == ["f.txt"], "MERGE_RR attributes the live path; got \(known.paths)")
    #expect(known.replayedPaths.isEmpty, "nothing was replayed for a first-time conflict")
    // Its id differs from the recorded one: different conflicts, different ids.
    #expect(known.conflictID != recorded.first?.conflictID)
}

@Test func statusWithRerereDisabledAndNoCacheIsEmptyAndDisabled() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["f.txt": "a\n"])])

    let status = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    #expect(!status.enabled)
    #expect(status.entries.isEmpty)
}

// MARK: - The replay is reported, never silent

@Test func afterReraiseTheConflictsSurfaceReportsTheReplayedPath() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    // Re-raise the identical conflict. The merge machinery applies the
    // recorded resolution to the working file (measured), while the index
    // still holds the unmerged stages — so the file IS in the conflict list
    // AND carries the replay.
    try git.run(["reset", "-q", "--hard", "HEAD~1"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)

    let surface = try conflictsSurface(at: repo.url.path, git: git)
    #expect(surface.files.count == 1, "the replayed path is still unmerged in the index; got \(surface.files.count)")
    #expect(surface.files.first?.path == "f.txt")
    #expect(surface.files.first?.kind == .bothModified)
    #expect(surface.rerereReplayed == ["f.txt"],
            "the replay must be reported on the conflicts surface, never silent; got \(surface.rerereReplayed)")

    // The working file carries the recorded resolution, not conflict markers
    // — the fact the replayed field explains.
    let workingText = try String(contentsOf: repo.url.appendingPathComponent("f.txt"), encoding: .utf8)
    #expect(workingText == "a\nR\nc\n")

    // And the status payload reports the same entry as recorded-and-replayed.
    let status = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    let entry = try #require(status.entries.first)
    #expect(entry.state == .recorded)
    #expect(entry.replayedPaths == ["f.txt"])
    #expect(entry.paths == ["f.txt"])
}

@Test func twoReplayedPathsAreBothReportedSorted() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("base", files: ["f.txt": "a\nb\nc\n", "g.txt": "x\ny\nz\n"]),
        .init("side", parents: ["base"], files: [
            "f.txt": "a\nB\nc\n", "g.txt": "x\nY\nz\n",
        ]),
        .init("ours", parents: ["base"], files: [
            "f.txt": "a\nX\nc\n", "g.txt": "x\nW\nz\n",
        ]),
    ])
    try git.run(["config", "rerere.enabled", "true"], workingDirectory: repo.url.path)
    let side = try #require(repo.oids["side"])
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
    try "a\nR\nc\n".write(to: repo.url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    try "x\nS\nz\n".write(to: repo.url.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "resolved"], workingDirectory: repo.url.path)

    try git.run(["reset", "-q", "--hard", "HEAD~1"], workingDirectory: repo.url.path)
    _ = try git.capture(
        ["merge", "--no-commit", side], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)

    let surface = try conflictsSurface(at: repo.url.path, git: git)
    #expect(surface.files.count == 2)
    #expect(surface.rerereReplayed == ["f.txt", "g.txt"],
            "both replays must be reported, sorted; got \(surface.rerereReplayed)")
}

@Test func rerereReplayedStaysEmptyWhileRerereIsDisabled() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }

    let surface = try conflictsSurface(at: repo.url.path, git: git)
    #expect(surface.files.count == 1, "the fixture conflicts exactly one path; got \(surface.files.count)")
    #expect(surface.rerereReplayed.isEmpty,
            "rerere never recorded anything, so nothing can be replayed")
}

@Test func rerereReplayedStaysEmptyWhenNoConflictIsLive() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }

    let surface = try conflictsSurface(at: repo.url.path, git: git)
    #expect(surface.files.isEmpty)
    #expect(surface.rerereReplayed.isEmpty,
            "a recorded resolution without a live conflict is not a replay")
}

// MARK: - The MERGE_RR parser, pinned against the probed bytes

@Test func parseMergeRRReadsTheProbedRecordShape() throws {
    // Verbatim from the #0065 probe (stage 1, xxd of .git/MERGE_RR):
    // `650b3bb115602e8f349398d8d6c560baaef932e3\tf.txt\0`.
    let probed = Data("650b3bb115602e8f349398d8d6c560baaef932e3\tf.txt".utf8) + [0x00]
    let parsed = try Rerere.parseMergeRR(probed)
    #expect(parsed.count == 1)
    let record = try #require(parsed.first)
    #expect(record.conflictID == "650b3bb115602e8f349398d8d6c560baaef932e3")
    #expect(record.path == "f.txt")
}

@Test func parseMergeRRReadsTwoRecordsAndAZeroByteFile() throws {
    let two = Data("650b3bb115602e8f349398d8d6c560baaef932e3\tf.txt".utf8) + [0x00]
        + Data("0123456789abcdef0123456789abcdef01234567\tg/h.txt".utf8) + [0x00]
    let parsed = try Rerere.parseMergeRR(two)
    #expect(parsed.count == 2, "one record per conflicted path; got \(parsed.count)")
    #expect(parsed[0].path == "f.txt")
    #expect(parsed[1].conflictID == "0123456789abcdef0123456789abcdef01234567")
    #expect(parsed[1].path == "g/h.txt")

    // The measured zero-byte MERGE_RR: a replay consumed the record. Empty
    // is the truthful read, not an error.
    #expect(try Rerere.parseMergeRR(Data()).isEmpty)
}

@Test func parseMergeRRRefusesRecordsWithoutAConflictIDOrPath() throws {
    // No tab: the id and the path cannot be separated.
    #expect {
        _ = try Rerere.parseMergeRR(Data("650b3bb115602e8f349398d8d6c560baaef932e3f.txt".utf8) + [0x00])
    } throws: { error in
        if case RerereError.malformedMergeRR = error { return true }
        return false
    }
    // A short, non-hex id: not git's layout.
    #expect {
        _ = try Rerere.parseMergeRR(Data("not-an-id\tf.txt".utf8) + [0x00])
    } throws: { error in
        if case RerereError.malformedMergeRR = error { return true }
        return false
    }
    // An id with no path at all.
    #expect {
        _ = try Rerere.parseMergeRR(Data("650b3bb115602e8f349398d8d6c560baaef932e3\t".utf8) + [0x00])
    } throws: { error in
        if case RerereError.malformedMergeRR = error { return true }
        return false
    }
    // A path containing a tab survives: only the FIRST tab separates.
    let tabbed = Data("650b3bb115602e8f349398d8d6c560baaef932e3\ta\tb.txt".utf8) + [0x00]
    let parsed = try Rerere.parseMergeRR(tabbed)
    let record = try #require(parsed.first)
    #expect(record.path == "a\tb.txt")
}

// MARK: - Typed refusals on damaged state

@Test func aForeignDirectoryInRRCacheIsATypedRefusal() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    let rrCache = repo.url.appendingPathComponent(".git/rr-cache")
    try FileManager.default.createDirectory(
        at: rrCache.appendingPathComponent("not-a-conflict-id"), withIntermediateDirectories: true)

    #expect {
        _ = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    } throws: { error in
        if case RerereError.unexpectedCacheEntry = error { return true }
        return false
    }
}

@Test func garbageMergeRRIsATypedRefusal() throws {
    let repo = try recordedFixture()
    defer { repo.destroy() }
    try "not rerere state at all".write(
        to: repo.url.appendingPathComponent(".git/MERGE_RR"), atomically: true, encoding: .utf8)

    #expect {
        _ = try Rerere.status(at: repo.url.path, git: git, extraEnvironment: hermetic)
    } throws: { error in
        if case RerereError.malformedMergeRR = error { return true }
        return false
    }
}
