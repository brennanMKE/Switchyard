// RewriteDiffTests.swift — range-diff over a stored rewrite mapping (#0064)
//
// Every mapping-bearing fixture here is real: the own-entry fixture stores
// its mapping the way #0221 attaches one, the observed-entry fixture records
// a mapping a real foreign `git commit --amend` raised through a real
// `post-rewrite` hook, and every parse assertion runs against output git
// actually printed in the fixture — never against a transcription of what
// the parser wishes git had said.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

/// Runs `git` through a raw `Foundation.Process` with every `SWITCHYARD_*`
/// marker variable stripped — genuinely foreign, the way a human running
/// `git commit --amend` directly is foreign to switchyard (the same helper
/// `PostRewriteAttachTests` uses; see its doc comment for why `GitProcess`
/// cannot reproduce this). stdout/stderr drain to EOF on a *subprocess's*
/// pipe, which is safe — the child exits and closes the write end.
@discardableResult
private func runForeignGit(_ arguments: [String], at path: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: git.executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: GitProcess.markerVariable)
    environment.removeValue(forKey: GitProcess.entryVariable)
    for (key, value) in hermetic { environment[key] = value }
    environment["GIT_EDITOR"] = "true"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    _ = pipe.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus
}

/// Installs a `post-rewrite` hook that logs the hook's argument and then
/// stdin verbatim, so the test can replay the real invocation into
/// `PostRewrite.decide` — the same role the #0217 hook glue plays.
private func installLoggingPostRewriteHook(in repo: FixtureRepository, loggingTo log: URL) throws {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir + "/post-rewrite"
    let script = """
    #!/bin/sh
    printf '=I= %s\\n' "$1" >> "\(log.path)"
    cat >> "\(log.path)"
    exit 0
    """
    try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

private struct LoggedInvocation {
    let source: String
    let stdin: Data
}

private func loggedInvocations(in log: URL) throws -> [LoggedInvocation] {
    let text = try String(contentsOf: log, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    var result: [LoggedInvocation] = []
    var index = 0
    while index < lines.count {
        guard lines[index].hasPrefix("=I= ") else {
            Issue.record("expected =I= at line \(index): \(lines[index])")
            break
        }
        let source = String(lines[index].dropFirst(4))
        index += 1
        var stdinLines: [String] = []
        while index < lines.count, !lines[index].hasPrefix("=I= ") {
            stdinLines.append(lines[index])
            index += 1
        }
        result.append(LoggedInvocation(
            source: source,
            stdin: Data((stdinLines.map { $0 + "\n" }.joined()).utf8)))
    }
    return result
}

/// `c1 → c2 → c3` on `main`, then a detached squash commit on top of `c1`
/// carrying both `c2` and `c3`'s changes — the many-to-one shape a fixup
/// squash produces, whose real `post-rewrite` mapping is `c2 → squash`
/// followed by `c3 → squash` in git's processing order.
private func squashFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, c3: String, squash: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\n"]),
        .init("c2", files: ["f.txt": "a1\na2\na3\n", "g.txt": "g1\n"]),
        .init("c3", files: ["f.txt": "a1\nA2\na3\n", "g.txt": "g1\n"]),
    ])
    let c1 = try #require(repo.oids["c1"])
    let c2 = try #require(repo.oids["c2"])
    let c3 = try #require(repo.oids["c3"])
    try repo.checkoutDetached(c1)
    try repo.writeUntracked(["f.txt": "a1\nA2\na3\n", "g.txt": "g1\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "squashed"], workingDirectory: repo.url.path)
    return (repo, c1, c2, c3, try repo.revParse("HEAD"))
}

/// Writes a journal entry carrying `mapping` as its own (#0221) attached
/// rewrite, the shape `JournalCheckpoint.attachRewrite` persists — the
/// entry's `metadata.json` holds the mapping, composed per #0234.
@discardableResult
private func writeOwnEntry(
    id: JournalEntryID, rewrite: JournalEntryMetadata.RewriteMapping?, in repo: FixtureRepository
) throws -> JournalEntryID {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let base = context.topLevel ?? context.gitDir
    let metadata = JournalEntryMetadata(
        id: id, operation: "fixup",
        timestamp: Date(timeIntervalSince1970: 1_757_000_000),
        worktree: .init(name: nil, path: base),
        captured: .refsOnly,
        rewrite: rewrite)
    _ = try JournalAnchor.write(
        JournalAnchor.Contents(metadataJSON: try metadata.serialized()),
        id: id, in: context)
    return id
}

// MARK: - Own-entry mapping: the many-to-one squash

@Test func aManyToOneSquashMappingRendersOneModifiedPairAndOneDroppedRow() throws {
    let (repo, c1, c2, c3, squash) = try squashFixture()
    defer { repo.destroy() }
    let entryID = JournalEntryID.generate()
    try writeOwnEntry(
        id: entryID,
        rewrite: JournalEntryMetadata.RewriteMapping(
            source: "rebase",
            rewrites: [
                PostRewrite.Rewrite(oldOid: c2, newOid: squash),
                PostRewrite.Rewrite(oldOid: c3, newOid: squash),
            ]),
        in: repo)

    let result = try RewriteDiff.run(
        entryID: entryID, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.entryID == entryID)
    #expect(result.source == .own)
    #expect(result.rewriteSource == "rebase")
    // The ranges the many-to-one view computed: base is the squash base
    // (c1, parent of the oldest old oid c2), old tip is the newest old oid
    // (c3), new tip is the single squash commit.
    #expect(result.ranges.base == c1)
    #expect(result.ranges.oldTip == c3)
    #expect(result.ranges.newTip == squash)
    // Measured shape (git 2.50.1): the squash renders as exactly two rows —
    // one modified pair (one old commit against the squash) and one
    // old-only row (the other old commit, dropped) — a sensible comparison,
    // not a broken range. Which old commit pairs is git's cost metric to
    // decide, so the assertion is structural: the two old sides are the two
    // squashed commits, one paired, one dropped.
    #expect(result.rows.count == 2)
    let paired = try #require(result.rows.first { $0.status == .modified },
                              "one row pairs an old commit with the squash")
    let dropped = try #require(result.rows.first { $0.status == .oldOnly },
                               "the other old commit renders as dropped")
    let pairedOld = try #require(paired.old)
    let droppedOld = try #require(dropped.old)
    #expect([pairedOld.oid, droppedOld.oid].sorted()
        == [String(c2.prefix(7)), String(c3.prefix(7))].sorted(),
        "the two rows' old sides are the two squashed commits")
    #expect(Set([pairedOld.number, droppedOld.number]) == [1, 2],
            "the rows number the old range's two commits, whichever pairs")
    #expect(try #require(paired.new).oid == String(squash.prefix(7)),
            "the pair's new side is the squash commit")
    #expect(dropped.new == nil, "a dropped commit has no new side")
    #expect(paired.subject == "c2" || paired.subject == "c3",
            "the pair row carries its old side's subject")
    #expect(dropped.subject == (pairedOld.oid == String(c2.prefix(7)) ? "c3" : "c2"),
            "each row's subject matches its old side")
}

// MARK: - Observed-entry mapping: a rewrite git performed directly

@Test func anObservedEntryFromAForeignAmendDiffsThroughGitOwnMapping() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let log = repo.url.appendingPathComponent("post-rewrite.log")
    try installLoggingPostRewriteHook(in: repo, loggingTo: log)
    let before = try repo.revParse("HEAD")

    // A genuinely foreign amend — no marker in the child's environment, the
    // way a human running git in a terminal is foreign.
    try runForeignGit(["commit", "--amend", "-q", "-m", "amended"],
                      at: repo.url.path)
    let after = try repo.revParse("HEAD")
    #expect(after != before, "the amend rewrote the tip")

    let invocation = try #require(try loggedInvocations(in: log).first)
    #expect(invocation.source == "amend")
    let decision = PostRewrite.decide(
        sourceArgument: invocation.source,
        environment: [:],
        readStandardInput: { invocation.stdin })
    #expect(!decision.isOwnInvocation)
    let recorded = try #require(
        try JournalObserved.record(decision, in: context),
        "a foreign rewrite's mapping must land in the observed namespace")
    let entryID = recorded.id

    let result = try RewriteDiff.run(
        entryID: entryID, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.source == .observed, "the mapping was served from the observed entry")
    #expect(result.rewriteSource == "amend")
    let parent = try repo.revParse(before + "^")
    #expect(result.ranges.base == parent, "the amended tip's parent is the base")
    #expect(result.ranges.oldTip == before)
    #expect(result.ranges.newTip == after)
    #expect(result.rows.count == 1, "one old commit, one new commit — one pair")
    let row = try #require(result.rows.first)
    #expect(row.status == .modified, "the message changed, so the pair is modified")
    #expect(try #require(row.old).oid == String(before.prefix(7)))
    #expect(try #require(row.new).oid == String(after.prefix(7)))
}

// MARK: - Refusals

@Test func anEntryWithoutAMappingRefusesWithNoRewriteMapping() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let entryID = JournalEntryID.generate()
    try writeOwnEntry(id: entryID, rewrite: nil, in: repo)

    let thrown = #expect(throws: RewriteDiffError.self) {
        try RewriteDiff.run(entryID: entryID, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .noRewriteMapping(id: entryID),
            "an entry that exists but stores no mapping is refused, never an empty diff")
}

@Test func anObservedRefUpdatesEntryRefusesWithNoRewriteMapping() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let context = try WorktreeContext.resolve(path: repo.url.path)
    // A real observed entry of the other kind — a foreign reference
    // transaction (#0153). It exists, so the refusal must be "no mapping",
    // not "unknown entry".
    let recorded = try #require(try JournalObserved.record(
        [ReferenceTransaction.RefUpdate(oldValue: repo.revParse("HEAD"), newValue: repo.revParse("HEAD"),
                                        refName: "refs/heads/main")],
        in: context))
    let thrown = #expect(throws: RewriteDiffError.self) {
        try RewriteDiff.run(entryID: recorded.id, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .noRewriteMapping(id: recorded.id))
}

@Test func anUnknownEntryRefusesWithUnknownEntry() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let entryID = JournalEntryID.generate()
    let context = try WorktreeContext.resolve(path: repo.url.path)
    #expect(try JournalAnchor.list(in: context).isEmpty, "precondition: an empty journal")
    #expect(try JournalObserved.list(in: context).isEmpty)

    let thrown = #expect(throws: RewriteDiffError.self) {
        try RewriteDiff.run(entryID: entryID, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .unknownEntry(id: entryID))
}

// MARK: - The parser, pinned against measured output

@Test func rowParsingIsPinnedAgainstMeasuredRangeDiffOutput() throws {
    let (repo, c1, c2, c3, squash) = try squashFixture()
    defer { repo.destroy() }
    let oldTip = try repo.revParse("main")

    // The same invocation the engine runs, over the same ranges the
    // many-to-one view computed — the assertion below pins the parser to
    // what this git actually prints, not to a transcription.
    let output = try git.run(
        ["range-diff", "--no-color", c1, oldTip, squash],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    let text = output.text
    #expect(!text.isEmpty, "the fixture must produce real range-diff output to pin against")
    // Measured: each pair row sits at column 0 as `<n>: <oid> <marker>
    // <n>: <oid> <subject>`, with the `-:`/`-------` sentinels on the
    // absent side and the diff body indented beneath.
    #expect(text.contains("!"), "a squash renders a modified pair in this fixture")

    let rows = try RewriteDiff.parseRows(text)
    #expect(rows.count == 2, "measured: one modified pair, one dropped old commit")
    let paired = try #require(rows.first { $0.status == .modified })
    let dropped = try #require(rows.first { $0.status == .oldOnly })
    // Which old commit pairs is git's cost metric to decide; that one of
    // the two squashed commits pairs and the other drops is the measured
    // structure.
    let pairedOld = try #require(paired.old)
    let droppedOld = try #require(dropped.old)
    #expect([pairedOld.oid, droppedOld.oid].sorted()
        == [String(c2.prefix(7)), String(c3.prefix(7))].sorted())
    #expect(paired.subject == "c2" || paired.subject == "c3")
    #expect(dropped.subject == (paired.subject == "c2" ? "c3" : "c2"),
            "each row's subject matches its old side")
    #expect(try #require(paired.new).oid == String(squash.prefix(7)))
    #expect(dropped.new == nil)
}

@Test func rowParsingRefusesADriftedFormatInsteadOfMisParsingIt() throws {
    // A line that starts like a row (column 0, counter field) but whose
    // sides do not satisfy the row contract must fail typed, not decode as
    // silently wrong rows.
    let thrown = #expect(throws: RewriteDiffError.self) {
        try RewriteDiff.parseRows("1:  bfc8637 ! -:\n")
    }
    guard case let .unparseableOutput(detail) = try #require(thrown) else {
        Issue.record("expected .unparseableOutput, got \(String(describing: thrown))")
        return
    }
    #expect(detail.contains("1:  bfc8637"), "the refusal names the offending line")

    // The absent sentinel is only absent as the measured *pair*: a lone
    // `-:` with a real oid is malformed, not a missing side.
    #expect(throws: RewriteDiffError.self) {
        try RewriteDiff.parseRows("-:  bfc8637 > 1:  1350d9c subject\n")
    }

    // The measured new-only shape (git 2.50.1, root-commit rewrite probe):
    // `-:  ------- > 1:  <oid> <subject>` — the absent-side sentinel is
    // the row's *first* field, so the counter gate must accept it.
    let newOnly = try RewriteDiff.parseRows("-:  ------- > 1:  9fbc3d2 c1 amended\n")
    #expect(newOnly.count == 1)
    let added = try #require(newOnly.first)
    #expect(added.status == .newOnly)
    #expect(added.old == nil)
    #expect(try #require(added.new).oid == "9fbc3d2")
    #expect(added.subject == "c1 amended", "a subject with spaces survives the parse")
}

// MARK: - replacements(of:) is the grouping in use

@Test func rowsCarryExactlyTheOldOidsReplacementsGroups() throws {
    let (repo, _, c2, c3, squash) = try squashFixture()
    defer { repo.destroy() }
    let rewrites = [
        PostRewrite.Rewrite(oldOid: c2, newOid: squash),
        PostRewrite.Rewrite(oldOid: c3, newOid: squash),
    ]
    // The fixture IS many-to-one: one replacement group holding both old
    // oids, in git's processing order. Asserted from the helper itself so
    // the rows' correspondence below is meaningful.
    let replacements = PostRewrite.replacements(of: rewrites)
    #expect(replacements.count == 1)
    #expect(try #require(replacements.first).newOid == squash)
    #expect(try #require(replacements.first).oldOids == [c2, c3])

    let entryID = JournalEntryID.generate()
    try writeOwnEntry(
        id: entryID,
        rewrite: JournalEntryMetadata.RewriteMapping(source: "rebase", rewrites: rewrites),
        in: repo)
    let result = try RewriteDiff.run(
        entryID: entryID, at: repo.url.path, extraEnvironment: hermetic)

    // Every old oid the grouping holds appears on exactly one row's old
    // side, and no row invents an old side the grouping does not hold —
    // the parse is downstream of `replacements(of:)`, never of a second
    // grouping.
    let oldOIDsFromRows = result.rows.compactMap(\.old).map(\.oid).sorted()
    let oldOIDsFromReplacements = Set(replacements.flatMap(\.oldOids))
        .map { String($0.prefix(7)) }.sorted()
    #expect(oldOIDsFromRows == oldOIDsFromReplacements,
            "rows' old sides are exactly the grouping's old oids, as short forms")
}

// MARK: - Wire shape

@Test func rewriteDiffResultEncodesExactlyItsWireKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let id = try #require(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
    let result = RewriteDiff.Result(
        entryID: id, source: .own, rewriteSource: "rebase",
        ranges: RewriteDiff.Ranges(
            base: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            oldTip: "cccccccccccccccccccccccccccccccccccccccc",
            newTip: "dddddddddddddddddddddddddddddddddddddddd"),
        rows: [
            RewriteDiff.Row(
                status: .modified,
                old: RewriteDiff.Side(number: 1, oid: "bfc8637"),
                new: RewriteDiff.Side(number: 1, oid: "1350d9c"),
                subject: "c2"),
            RewriteDiff.Row(status: .oldOnly, old: RewriteDiff.Side(number: 2, oid: "e4953bc"),
                            new: nil, subject: "c3"),
        ])
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["entryID", "source", "rewriteSource", "ranges", "rows"],
            "RewriteDiff.Result encodes exactly its five wire keys; got \(object.keys.sorted())")
    let rowObjects = try #require(object["rows"] as? [[String: Any]])
    #expect(rowObjects.count == 2)
    let dropped = try #require(rowObjects.last)
    // An absent side is omitted from the wire — synthesized Codable's
    // encodeIfPresent convention, the same optional-field shape every
    // engine result carries. The status is its case name verbatim.
    #expect(Set(dropped.keys) == ["status", "old", "subject"])
    #expect(dropped["status"] as? String == "oldOnly")
    #expect(object["source"] as? String == "own")
    #expect(object["entryID"] as? String == id.string)
}
