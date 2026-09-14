// BranchStatusTests.swift — per-branch ahead/behind and merged state (#0372)
//
// Pins the §11 decision 27 shapes against real git: the tab-separated
// for-each-ref parse and its full `%(upstream:track)` vocabulary, the A3
// baseline selection (upstream set / unset / origin-HEAD target / literal-
// main fallback), the M6 composite in order (ancestry, upstream-gone,
// merge-tree content, unknown), and the synchronous read's single-process
// shape — one `for-each-ref` for every branch, never one per branch.
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. Every fixture is
// a throwaway repository under NSTemporaryDirectory built by
// FixtureRepository, which pins commit.gpgsign=false.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

// MARK: - Parse: the for-each-ref status line

@Test func parseReadsEveryUpstreamTrackVocabulary() throws {
    let lines = [
        "refs/heads/ahead\trefs/remotes/origin/ahead\tahead 2\t0 5",
        "refs/heads/behind\trefs/remotes/origin/behind\tbehind 3\t0 9",
        "refs/heads/diverged\trefs/remotes/origin/diverged\tahead 1, behind 4\t1 7",
        "refs/heads/insync\trefs/remotes/origin/insync\t\t2 0",
        "refs/heads/localup\trefs/heads/main\tahead 1\t0 0",
        "refs/heads/plain\t\t\t3 1",
        "refs/heads/gone\trefs/remotes/origin/gone\t[gone]\t1 0",
    ]
    let rows = try BranchStatus.parse(lines.joined(separator: "\n"), defaultBranch: "main")
    #expect(rows.count == 7, "every line must parse; got \(rows.count)")
    let byRef = Dictionary(uniqueKeysWithValues: rows.map { ($0.ref, $0) })

    let ahead = try #require(byRef["refs/heads/ahead"])
    #expect(ahead.baseline == .upstream("refs/remotes/origin/ahead"))
    #expect(ahead.ahead == 2 && ahead.behind == 0, "empty behind in the track is 0, not absent")
    #expect(ahead.upstreamGone == false)
    #expect(ahead.defaultAhead == 0 && ahead.defaultBehind == 5,
            "the default-relative counts ride alongside the A3 baseline")

    let behind = try #require(byRef["refs/heads/behind"])
    #expect(behind.baseline == .upstream("refs/remotes/origin/behind"))
    #expect(behind.ahead == 0 && behind.behind == 3)

    let diverged = try #require(byRef["refs/heads/diverged"])
    #expect(diverged.baseline == .upstream("refs/remotes/origin/diverged"))
    #expect(diverged.ahead == 1 && diverged.behind == 4)

    let insync = try #require(byRef["refs/heads/insync"])
    #expect(insync.baseline == .upstream("refs/remotes/origin/insync"))
    #expect(insync.ahead == 0 && insync.behind == 0,
            "an empty track against a live upstream is in sync, not no-numbers")

    let localup = try #require(byRef["refs/heads/localup"])
    #expect(localup.baseline == .upstream("refs/heads/main"),
            "a local-branch upstream keeps its own ref name")

    let plain = try #require(byRef["refs/heads/plain"])
    #expect(plain.upstream == nil)
    #expect(plain.baseline == .defaultBranch("main"))
    #expect(plain.ahead == 3 && plain.behind == 1)

    let gone = try #require(byRef["refs/heads/gone"])
    #expect(gone.upstreamGone == true)
    #expect(gone.baseline == .defaultBranch("main"),
            "a gone upstream has no numbers to show — the row falls back to the default")
    #expect(gone.ahead == 1 && gone.behind == 0)
    #expect(gone.defaultAhead == 1 && gone.defaultBehind == 0)
}

@Test func parseThrowsOnMalformedLines() {
    // Two fields — a line git never prints.
    #expect(throws: BranchStatus.Error.self) {
        _ = try BranchStatus.parse("refs/heads/x\trefs/remotes/origin/x", defaultBranch: "main")
    }
    // Five fields — ditto.
    #expect(throws: BranchStatus.Error.self) {
        _ = try BranchStatus.parse(
            "refs/heads/x\trefs/remotes/origin/x\tahead 1\t0 1\textra", defaultBranch: "main")
    }
    // Track vocabulary outside the measured set.
    #expect(throws: BranchStatus.Error.self) {
        _ = try BranchStatus.parse(
            "refs/heads/x\trefs/remotes/origin/x\tboldly gone\t0 1", defaultBranch: "main")
    }
    // Counts that are not two integers.
    #expect(throws: BranchStatus.Error.self) {
        _ = try BranchStatus.parse("refs/heads/x\t\t\tzero one", defaultBranch: "main")
    }
}

@Test func baselineDisplayNamesStripTheRefPrefixes() {
    #expect(BranchStatus.Baseline.upstream("refs/remotes/origin/main").displayName == "origin/main")
    #expect(BranchStatus.Baseline.upstream("refs/heads/main").displayName == "main")
    #expect(BranchStatus.Baseline.defaultBranch("main").displayName == "main")
    #expect(BranchStatus.Baseline.defaultBranch("trunk").displayName == "trunk")
}

// MARK: - A3: baseline selection against real git

@Test func readFallsBackToMainWhenOriginHEADIsMissing() throws {
    // FixtureRepository.linear: main at a → b → c, no remote, so no
    // refs/remotes/origin/HEAD at all.
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let report = try BranchStatus.read(at: repo.url.path, git: git)

    #expect(report.defaultBranch == "main", "no origin/HEAD → decision 27's literal fallback")
    let main = try #require(report.row(forBranchNamed: "refs/heads/main"))
    #expect(main.baseline == .defaultBranch("main"))
    #expect(main.ahead == 0 && main.behind == 0)
    #expect(main.defaultAhead == 0 && main.defaultBehind == 0)
}

@Test func readFollowsOriginHEADTargetForTheDefaultBranch() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1")])
    try repo.addUpstream(branch: "main")
    try repo.branch("master", at: "c1")
    // Pushed WITHOUT -u: master must have no upstream config, so its A3
    // baseline is the default branch — here a non-main name.
    try git.run(["push", "-q", "origin", "master"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)
    // Push alone creates no origin/HEAD (measured, git 2.50.1): point it at
    // master by hand so the repository's default is visibly not main.
    try git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)

    let report = try BranchStatus.read(at: repo.url.path, git: git)

    #expect(report.defaultBranch == "master",
            "the default is origin/HEAD's target's branch name, not a hardcoded main")
    let master = try #require(report.row(forBranchNamed: "refs/heads/master"))
    #expect(master.baseline == .defaultBranch("master"))
    #expect(master.ahead == 0 && master.behind == 0, "master vs master is 0 0")
}

@Test func readSelectsTheUpstreamBaselineWhenOneIsSet() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1"), .init("c2")])
    try repo.addUpstream(branch: "main")
    try repo.branch("topic", at: "c1")

    let report = try BranchStatus.read(at: repo.url.path, git: git)

    #expect(report.defaultBranch == "main",
            "push -u creates no origin/HEAD (measured) — the literal fallback names the default")
    let main = try #require(report.row(forBranchNamed: "refs/heads/main"))
    #expect(main.baseline == .upstream("refs/remotes/origin/main"),
            "main has an upstream — A3 shows it, named")
    #expect(main.ahead == 0 && main.behind == 0)
    #expect(main.defaultAhead == 0 && main.defaultBehind == 0)

    let topic = try #require(report.row(forBranchNamed: "refs/heads/topic"))
    #expect(topic.upstream == nil)
    #expect(topic.baseline == .defaultBranch("main"), "no upstream set — A3 falls back")
    #expect(topic.ahead == 0 && topic.behind == 1, "topic sits one behind main")
    #expect(topic.defaultAhead == 0 && topic.defaultBehind == 1)
}

@Test func readDegradesToUpstreamTrackOnlyWhenTheDefaultBranchIsMissing() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1")])
    // No remote, and the only branch is not main: `%(ahead-behind:main)`
    // fatals the whole for-each-ref (measured, git 2.50.1, exit 128), so
    // read retries without the atom.
    try git.run(["branch", "-m", "main", "master"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)

    let report = try BranchStatus.read(at: repo.url.path, git: git)

    #expect(report.defaultBranch == "main")
    let master = try #require(report.row(forBranchNamed: "refs/heads/master"))
    #expect(master.ahead == nil && master.behind == nil,
            "nothing to measure against — the numbers stay absent rather than wrong")
    #expect(master.defaultAhead == nil)
    #expect(master.upstreamGone == false)
    #expect(BranchStatus.mergedState(for: master) == .unknown,
            "no ancestry signal, no upstream, no content yet")
}

// MARK: - M6: the merged composite against real git

/// One repository carrying every M6 shape as branches over `main`:
/// `behind-main` (ancestry), `squash-landed` (content-merged by tree
/// equality), `unlanded` (content answers not merged), `conflicting`
/// (merge-tree reports a conflict), and `gone-branch` (committed ahead,
/// pushed, then its tracking ref deleted).
private func m6Fixture() throws -> (repo: FixtureRepository, bare: URL) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "base\n"]),
        .init("c2", files: ["f.txt": "main\n"]),
    ])

    // behind-main: an ancestor of main — ahead 0 against the default.
    try repo.branch("behind-main", at: "c1")

    // squash-landed: g.txt added off c1, then squash-landed on main — the
    // branch tip is NOT an ancestor, but merging it yields main's tree.
    try repo.branch("squash-landed", at: "c1")
    try repo.checkout("squash-landed")
    try repo.writeUntracked(["g.txt": "feature\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "F"], workingDirectory: repo.url.path)
    try repo.checkout("main")
    try git.run(["merge", "--squash", "squash-landed"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "land"], workingDirectory: repo.url.path)

    // unlanded: a unique file off c2, never landed.
    try repo.branch("unlanded", at: "c2")
    try repo.checkout("unlanded")
    try repo.writeUntracked(["unique.txt": "u\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "U"], workingDirectory: repo.url.path)
    try repo.checkout("main")

    // conflicting: f.txt edited on both sides since c1.
    try repo.branch("conflicting", at: "c1")
    try repo.checkout("conflicting")
    try repo.writeUntracked(["f.txt": "theirs\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "B"], workingDirectory: repo.url.path)
    try repo.checkout("main")

    // gone-branch: ahead of main, pushed, tracking ref deleted after.
    try repo.branch("gone-branch", at: "c2")
    try repo.checkout("gone-branch")
    try repo.writeUntracked(["h.txt": "h\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "G"], workingDirectory: repo.url.path)
    try repo.checkout("main")

    let bare = try repo.addUpstream(branch: "main")
    try git.run(["push", "-q", "-u", "origin", "gone-branch"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)
    try git.run(["update-ref", "-d", "refs/remotes/origin/gone-branch"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)
    return (repo, bare)
}

@Test func mergedStateResolvesAncestryAndGoneWithoutTheContentPass() throws {
    let (repo, bare) = try m6Fixture()
    defer {
        repo.destroy()
        try? FileManager.default.removeItem(at: bare)
    }

    let report = try BranchStatus.read(at: repo.url.path, git: git)

    let behind = try #require(report.row(forBranchNamed: "refs/heads/behind-main"))
    #expect(behind.defaultAhead == 0, "an ancestor of main is 0 ahead of it")
    #expect(BranchStatus.mergedState(for: behind) == .merged(by: .ancestry))

    let gone = try #require(report.row(forBranchNamed: "refs/heads/gone-branch"))
    #expect(gone.upstreamGone, "the tracking ref was deleted — upstream:track must read [gone]")
    #expect(gone.defaultAhead == 1, "M1 must not answer: the branch is ahead of main")
    #expect(BranchStatus.mergedState(for: gone) == .merged(by: .upstreamGone))

    // Content-dependent branches answer unknown until the pass lands.
    for name in ["squash-landed", "unlanded", "conflicting"] {
        let row = try #require(report.row(forBranchNamed: "refs/heads/\(name)"))
        #expect(row.defaultAhead == 1, "\(name) is ahead of main — M1 keeps looking")
        #expect(BranchStatus.mergedState(for: row) == .unknown,
                "\(name) needs the content pass — unknown until it lands, never a guess")
    }

    // main itself: the default branch is trivially merged by ancestry.
    let main = try #require(report.row(forBranchNamed: "refs/heads/main"))
    #expect(BranchStatus.mergedState(for: main) == .merged(by: .ancestry))
}

@Test func contentPassResolvesMergeTreeStatesAndSkipsAnsweredBranches() async throws {
    let (repo, bare) = try m6Fixture()
    defer {
        repo.destroy()
        try? FileManager.default.removeItem(at: bare)
    }

    let report = try await BranchStatus.read(at: repo.url.path, git: git)
    let content = try await BranchStatus.contentPass(for: report, at: repo.url.path, git: git)

    #expect(
        Set(content.keys)
            == Set(["refs/heads/squash-landed", "refs/heads/unlanded", "refs/heads/conflicting"]),
        "branches M1 or M4 already answer spawn no merge-tree; got \(content.keys.sorted())")
    #expect(content["refs/heads/squash-landed"] == .merged(by: .content),
            "the squash landing's merge-tree result equals main's tree")
    #expect(content["refs/heads/unlanded"] == .notMerged,
            "a genuinely unlanded branch merges to a different tree")
    #expect(content["refs/heads/conflicting"] == .unknown,
            "a conflict answer is unknown, not a guess")

    // The composite now answers every branch, in order.
    let behind = try #require(report.row(forBranchNamed: "refs/heads/behind-main"))
    #expect(BranchStatus.mergedState(for: behind, content: content) == .merged(by: .ancestry))
    let gone = try #require(report.row(forBranchNamed: "refs/heads/gone-branch"))
    #expect(BranchStatus.mergedState(for: gone, content: content) == .merged(by: .upstreamGone))
    let main = try #require(report.row(forBranchNamed: "refs/heads/main"))
    #expect(BranchStatus.mergedState(for: main, content: content) == .merged(by: .ancestry))
}

// MARK: - M6 ordering, as a unit over constructed rows

@Test func mergedStateAppliesM6InOrder() {
    func row(defaultAhead: Int?, gone: Bool) -> BranchStatus.Row {
        BranchStatus.Row(
            ref: "refs/heads/x",
            upstream: gone ? "refs/remotes/origin/x" : nil,
            upstreamGone: gone,
            baseline: .defaultBranch("main"),
            ahead: defaultAhead, behind: nil,
            defaultAhead: defaultAhead, defaultBehind: nil)
    }
    // M1 first: ancestry wins over a gone upstream and over any content answer.
    #expect(BranchStatus.mergedState(
        for: row(defaultAhead: 0, gone: true),
        content: ["refs/heads/x": .notMerged]) == .merged(by: .ancestry))
    // M4 second: gone wins over content.
    #expect(BranchStatus.mergedState(
        for: row(defaultAhead: 2, gone: true),
        content: ["refs/heads/x": .merged(by: .content)]) == .merged(by: .upstreamGone))
    // M3 last: content answers only when ancestry and gone both came up short.
    #expect(BranchStatus.mergedState(
        for: row(defaultAhead: 2, gone: false),
        content: ["refs/heads/x": .notMerged]) == .notMerged)
    #expect(BranchStatus.mergedState(
        for: row(defaultAhead: 2, gone: false),
        content: ["refs/heads/x": .merged(by: .content)]) == .merged(by: .content))
    // No content answer yet → unknown.
    #expect(BranchStatus.mergedState(for: row(defaultAhead: 2, gone: false)) == .unknown)
    // A nil default-relative ahead cannot claim ancestry.
    #expect(BranchStatus.mergedState(for: row(defaultAhead: nil, gone: false)) == .unknown)
}

// MARK: - Decision 27's budget, as the spawn shape

/// A logging git shim: appends each invocation's argv to `logPath`, then
/// execs the real git. The log path is baked into the script so the engine
/// API needs no environment plumbing.
private func writeLoggingShim(logPath: String, in dir: String) throws -> String {
    let shimPath = dir + "/git-log-shim.sh"
    let script = """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(logPath)
    exec /usr/bin/git "$@"
    """
    try script.write(toFile: shimPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: shimPath)
    return shimPath
}

private func spawnCount(
    _ needle: String, in logText: String
) -> Int {
    logText.split(separator: "\n").filter { $0.contains(needle) }.count
}

@Test func readSpawnsOneForEachRefForAllBranches() throws {
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    for index in 1...6 { try repo.branch("b\(index)", at: "c") }

    let dir = NSTemporaryDirectory() + "yard-branchstatus-shim-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let logPath = dir + "/invocations.log"
    let shim = try writeLoggingShim(logPath: logPath, in: dir)

    _ = try BranchStatus.read(at: repo.url.path, git: GitProcess(executablePath: shim))

    let log = try String(contentsOfFile: logPath, encoding: .utf8)
    #expect(!log.isEmpty, "the shim must have logged every git spawn")
    #expect(spawnCount("for-each-ref", in: log) == 1,
            "one for-each-ref for all 7 branches — never one per branch")
    #expect(spawnCount("symbolic-ref", in: log) == 1,
            "exactly one symbolic-ref names the default branch")
    #expect(log.split(separator: "\n").count == 2,
            "the whole read is those two processes and nothing else")
}

@Test func asyncReadSpawnsOneForEachRefForAllBranches() async throws {
    // The sidebar's actual path is the async read — same shape pinned there.
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    for index in 1...6 { try repo.branch("b\(index)", at: "c") }

    let dir = NSTemporaryDirectory() + "yard-branchstatus-shim-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let logPath = dir + "/invocations.log"
    let shim = try writeLoggingShim(logPath: logPath, in: dir)

    _ = try await BranchStatus.read(at: repo.url.path, git: GitProcess(executablePath: shim))

    let log = try String(contentsOfFile: logPath, encoding: .utf8)
    #expect(!log.isEmpty, "the shim must have logged every git spawn")
    #expect(spawnCount("for-each-ref", in: log) == 1,
            "one for-each-ref for all 7 branches — never one per branch")
    #expect(spawnCount("symbolic-ref", in: log) == 1)
    #expect(log.split(separator: "\n").count == 2)
}
