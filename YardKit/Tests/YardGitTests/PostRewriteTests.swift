// PostRewriteTests.swift — tests for the post-rewrite decision core (#0043)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

private let zeros40 = String(repeating: "0", count: 40)
private let oidA = "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"
private let oidB = "1db38f7e412aaa4357e0e76acdd212ba8e646517"
private let oidC = "5091a0b36200bb1ace0d1ccc310fe128f7e001bf"
private let oidS = "7bd3b079a7b626bd45a901299c675312b0b2f6de"

/// Installs a `post-rewrite` hook that logs each invocation as a `=I= <arg>`
/// separator line followed by the invocation's stdin, verbatim. The hooks
/// path comes from `git rev-parse --git-path hooks` via `WorktreeContext` —
/// never from string concatenation onto `.git/`.
private func installPostRewriteHook(
    in repo: FixtureRepository, loggingTo log: URL
) throws {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(
        atPath: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir + "/post-rewrite"
    let script = """
    #!/bin/sh
    printf '=I= %s\\n' "$1" >> "\(log.path)"
    cat >> "\(log.path)"
    exit 0
    """
    try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

/// Splits the hook log back into invocations. Stdin lines are hex object
/// names and never start with `=I= `, so the separator is unambiguous.
private func invocations(in log: URL) -> [(source: String, stdin: Data)] {
    guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
    var result: [(source: String, stdin: Data)] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix("=I= ") {
            result.append((source: String(line.dropFirst(4)), stdin: Data()))
        } else if !result.isEmpty {
            result[result.count - 1].stdin.append(Data((line + "\n").utf8))
        }
    }
    return result
}

// MARK: - Parsing the measured stdin format

@Test func parseClassifiesTwoFieldLines() throws {
    // Measured bytes of a real `git commit --amend`: one line,
    // `<old> SP <new> LF`, single 0x20, no third field.
    let result = PostRewrite.parse(Data("\(oidA) \(oidB)\n".utf8))
    #expect(result.malformedLineCount == 0)
    let rewrite = try #require(result.rewrites.first)
    #expect(result.rewrites.count == 1)
    #expect(rewrite.oldOid == oidA)
    #expect(rewrite.newOid == oidB)
    #expect(rewrite.extraInfo == nil)
}

@Test func parseToleratesExtraInfoThirdField() throws {
    // githooks(5): `<old> SP <new> [ SP <extra-info> ] LF`, extra-info
    // command-dependent and currently never emitted. It may contain spaces;
    // maxSplits keeps it whole.
    let result = PostRewrite.parse(Data("\(oidA) \(oidB) some extra info\n".utf8))
    let rewrite = try #require(result.rewrites.first)
    #expect(rewrite.oldOid == oidA)
    #expect(rewrite.newOid == oidB)
    #expect(rewrite.extraInfo == "some extra info")
    #expect(result.malformedLineCount == 0)
}

@Test func parseHandlesSixtyFourCharOids() throws {
    // Measured in an --object-format=sha256 repository.
    let old64 = "fa80643dfd9c1d8931f80479dafd6b289a13dbbae22eb8296af6db3d6152b1d1"
    let new64 = "6c9a8a7899bec5a956de7786ba059a21df46f0742112a2e1e067238577d028b7"
    let result = PostRewrite.parse(Data("\(old64) \(new64)\n".utf8))
    let rewrite = try #require(result.rewrites.first)
    #expect(rewrite.oldOid == old64)
    #expect(rewrite.newOid == new64)
}

@Test func postRewriteParseDropsMalformedLinesAndCounts() {
    let input = Data("""
    garbage-no-spaces
    \(oidA) \(oidB)
     \(oidB)
    """.utf8)
    let result = PostRewrite.parse(input)
    #expect(result.rewrites.count == 1)
    #expect(result.rewrites.first?.oldOid == oidA)
    #expect(result.malformedLineCount == 2)

    let empty = PostRewrite.parse(Data())
    #expect(empty.rewrites.isEmpty)
    #expect(empty.malformedLineCount == 0)
}

// MARK: - The many-to-one view

@Test func replacementsGroupManyToOnePreservingOrder() {
    // The measured squash shape: A and B both rewritten to S (two lines, one
    // new oid), C rewritten to itself-like T — grouped without losing either
    // the order new oids first appear or the processing order inside a group.
    let rewrites = [
        PostRewrite.Rewrite(oldOid: oidA, newOid: oidS),
        PostRewrite.Rewrite(oldOid: oidB, newOid: oidS),
        PostRewrite.Rewrite(oldOid: oidC, newOid: oidB),
    ]
    let groups = PostRewrite.replacements(of: rewrites)
    #expect(groups == [
        PostRewrite.Replacement(newOid: oidS, oldOids: [oidA, oidB]),
        PostRewrite.Replacement(newOid: oidB, oldOids: [oidC]),
    ])
}

// MARK: - The decision policy

@Test func decideAlwaysExitsZero() {
    // The hook runs after the rewrite; nothing a handler does can undo it,
    // and under #0041's chaining a non-zero from any link surfaces in the
    // aggregate. No input, including garbage stdin, produces a non-zero.
    for source in ["amend", "rebase", "junk", ""] {
        for env in [[:], [GitProcess.markerVariable: "1"]] {
            let decision = PostRewrite.decide(
                sourceArgument: source,
                environment: env,
                readStandardInput: { Data("total garbage\nmore\n".utf8) })
            #expect(decision.exitCode == 0,
                    "source \(source), env \(env) must still exit 0")
        }
    }
}

@Test func decideClassifiesSourceAndMarker() {
    let stdin = Data("\(oidA) \(oidB)\n".utf8)

    // Foreign amend: no marker at all.
    let foreign = PostRewrite.decide(
        sourceArgument: "amend",
        environment: ["PATH": "/usr/bin"],
        readStandardInput: { stdin })
    #expect(foreign.source == .amend)
    #expect(!foreign.isOwnInvocation)
    #expect(foreign.rewrites.count == 1)

    // Own rebase: the marker GitProcess sets on every invocation. The
    // mapping is STILL parsed — routing, not a skip: for switchyard's own
    // rebases this hook is the only source of the mapping (#0042 differs
    // here, deliberately).
    let own = PostRewrite.decide(
        sourceArgument: "rebase",
        environment: [GitProcess.markerVariable: "1"],
        readStandardInput: { stdin })
    #expect(own.source == .rebase)
    #expect(own.isOwnInvocation)
    #expect(own.rewrites.count == 1, "own invocations keep their mapping")

    // Present but EMPTY is foreign — the escape hatch tests use through
    // GitProcess.extraEnvironment, since the base environment always
    // carries the marker as "1".
    let emptied = PostRewrite.decide(
        sourceArgument: "amend",
        environment: [GitProcess.markerVariable: ""],
        readStandardInput: { stdin })
    #expect(!emptied.isOwnInvocation)

    // A future source argument is unrecognized, not dropped.
    let future = PostRewrite.decide(
        sourceArgument: "filter-repo",
        environment: [:],
        readStandardInput: { stdin })
    #expect(future.source == .unrecognized("filter-repo"))
    #expect(future.rewrites.count == 1)
}

@Test func decideReadsStdinExactlyOnce() {
    // Every invocation carries a mapping worth keeping, so stdin is read
    // exactly once whatever the source and whoever invoked it.
    for (source, env) in [
        ("amend", [String: String]()),
        ("rebase", [GitProcess.markerVariable: "1"]),
        ("future-source", [:]),
    ] {
        var reads = 0
        _ = PostRewrite.decide(
            sourceArgument: source,
            environment: env,
            readStandardInput: {
                reads += 1
                return Data()
            })
        #expect(reads == 1, "source \(source) must read stdin exactly once")
    }
}

// MARK: - The real contract, against a real repository, both ref formats

@Test(arguments: FixtureRepository.RefFormat.supported())
func amendFiresOnceWithTheRealMapping(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let before = try #require(repo.oids["a"])

    let log = repo.url.appendingPathComponent("post-rewrite.log")
    try installPostRewriteHook(in: repo, loggingTo: log)

    try GitProcess().run(["commit", "--amend", "-q", "-m", "a-amended"],
                         workingDirectory: repo.url.path)
    let after = try repo.revParse("HEAD")

    let calls = invocations(in: log)
    try #require(calls.count == 1)
    #expect(calls[0].source == "amend")

    let result = PostRewrite.parse(calls[0].stdin)
    #expect(result.malformedLineCount == 0)
    let rewrite = try #require(result.rewrites.first)
    #expect(result.rewrites.count == 1)
    #expect(rewrite.oldOid == before)
    #expect(rewrite.newOid == after)
    #expect(rewrite.extraInfo == nil)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func rebaseSquashMapsManyToOneAndDropIsAbsent(
    _ format: FixtureRepository.RefFormat
) throws {
    // feature carries a → b → c on top of base; main moved on. An
    // interactive rebase squashes b into a and drops c.
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.build([.init("a", parents: ["base"])])
    try repo.build([.init("b", parents: ["a"])])
    try repo.build([.init("c", parents: ["b"])])
    try repo.branch("feature", at: "c")
    try repo.build([.init("m", parents: ["base"])])
    try repo.branch("main", at: "m")
    try repo.checkout("feature")

    let oldA = try #require(repo.oids["a"])
    let oldB = try #require(repo.oids["b"])
    let oldC = try #require(repo.oids["c"])

    let log = repo.url.appendingPathComponent("post-rewrite.log")
    try installPostRewriteHook(in: repo, loggingTo: log)

    // GitProcess's base environment forbids editors (GIT_SEQUENCE_EDITOR
    // and GIT_EDITOR are both "false"); the overrides below are what makes
    // this rebase runnable non-interactively. BSD sed needs -i ''.
    try GitProcess().run(
        ["rebase", "-q", "-i", "main"],
        workingDirectory: repo.url.path,
        extraEnvironment: [
            "GIT_SEQUENCE_EDITOR":
                "sed -i '' -e '2s/^pick/squash/' -e '3s/^pick/drop/'",
            "GIT_EDITOR": "true",
        ])
    let squashed = try repo.revParse("HEAD")

    // Measured double-fire on git 2.50.1: the squash step itself raises an
    // `amend` invocation carrying an INTERMEDIATE old oid, then the rebase
    // completes with the composed, authoritative mapping. Consumers use the
    // LAST invocation, whose source is `rebase`. This pins the shape; if a
    // future git changes it, this fails and the contract is re-measured.
    let calls = invocations(in: log)
    try #require(calls.count == 2)
    #expect(calls[0].source == "amend")
    let final = try #require(calls.last)
    #expect(final.source == "rebase")

    let result = PostRewrite.parse(final.stdin)
    #expect(result.malformedLineCount == 0)
    #expect(result.rewrites.map(\.oldOid) == [oldA, oldB],
            "processing order, and the dropped commit is absent")
    #expect(!result.rewrites.map(\.oldOid).contains(oldC),
            "a dropped commit maps to nothing — absence is the representation")

    let groups = PostRewrite.replacements(of: result.rewrites)
    #expect(groups == [
        PostRewrite.Replacement(newOid: squashed, oldOids: [oldA, oldB]),
    ], "a squash is many old oids against one new commit")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func postRewriteGitProcessInvocationsCarryTheMarkerIntoTheHook(
    _ format: FixtureRepository.RefFormat
) throws {
    // The routing signal `decide` reads must be live end to end: a rewrite
    // run through GitProcess reaches the hook with the marker set to "1".
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])

    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(
        atPath: hooksDir, withIntermediateDirectories: true)
    let markerLog = repo.url.appendingPathComponent("marker.log")
    let script = """
    #!/bin/sh
    printf '%s\\n' "${\(GitProcess.markerVariable)-UNSET}" >> "\(markerLog.path)"
    cat > /dev/null
    exit 0
    """
    let hookPath = hooksDir + "/post-rewrite"
    try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: hookPath)

    try GitProcess().run(["commit", "--amend", "-q", "-m", "amended"],
                         workingDirectory: repo.url.path)

    let seen = (try? String(contentsOf: markerLog, encoding: .utf8)) ?? ""
    let values = seen.split(separator: "\n").map(String.init)
    #expect(!values.isEmpty, "the hook must have fired")
    #expect(values.allSatisfy { $0 == "1" },
            "every GitProcess invocation must carry \(GitProcess.markerVariable)=1; saw \(values)")
}

/// Completeness, at the unit level. Every existing `parse` test feeds input
/// yielding exactly one rewrite, so a parser truncated to `prefix(1)` or
/// `suffix(1)` satisfies all of them — #0043's review measured that both
/// truncations are caught, but ONLY by the two end-to-end rebase tests. A
/// mapping that silently loses commits is worse than none: the journal and
/// the UI both trust it to follow a commit across a rewrite.
@Test func parseReturnsEveryRewriteNotJustTheFirstOrLast() throws {
    let stdin = "\(oidA) \(oidB)\n\(oidB) \(oidC)\n\(oidC) \(oidS)\n"
    let result = PostRewrite.parse(Data(stdin.utf8))

    #expect(result.malformedLineCount == 0)
    #expect(result.rewrites.count == 3)
    #expect(result.rewrites == [
        PostRewrite.Rewrite(oldOid: oidA, newOid: oidB),
        PostRewrite.Rewrite(oldOid: oidB, newOid: oidC),
        PostRewrite.Rewrite(oldOid: oidC, newOid: oidS),
    ])
}
