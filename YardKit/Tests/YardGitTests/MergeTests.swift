// MergeTests.swift — merge a branch into the current branch (#0361)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `RewriteTests.swift`, `SplitTests.swift`, and `AbsorbTests.swift` do. A
// script is not a key; no keychain, ~/.gnupg, or ~/.ssh entry is touched.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try git.run(["config", key, value], workingDirectory: repo.url.path)
}

private func subjects(in repo: FixtureRepository) throws -> [String] {
    try git.run(
        ["log", "--format=%s"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
}

private func fileAt(_ revision: String, path: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["show", "\(revision):\(path)"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

/// The commit's parents, first-parent first — `rev-list --parents -n 1`
/// prints the commit followed by every parent on one line.
private func parents(of oid: String, in repo: FixtureRepository) throws -> [String] {
    let line = try git.run(
        ["rev-list", "--parents", "-n", "1", oid],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines[0]
    return line.split(separator: " ").dropFirst().map(String.init)
}

private func isAncestor(_ ancestor: String, of descendant: String, in repo: FixtureRepository) -> Bool {
    guard let probe = try? git.capture(
        ["merge-base", "--is-ancestor", ancestor, descendant],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ) else { return false }
    return probe.exitCode == 0
}

/// Whether a merge is in progress — the resumable state a conflicted merge
/// leaves behind. Asks git where `MERGE_HEAD` lives rather than assuming
/// `.git/`.
private func mergeInProgress(in repo: FixtureRepository) -> Bool {
    guard let out = try? git.run(
        ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"],
        workingDirectory: repo.url.path),
        let path = out.lines.first, !path.isEmpty
    else { return false }
    return FileManager.default.fileExists(atPath: path)
}

private func statusLines(in repo: FixtureRepository) throws -> [String] {
    // `--untracked-files=no`: the fake-gpg signing tests drop an untracked
    // script into the worktree, which is not a merge artifact and must not
    // read as one.
    try git.run(
        ["status", "--porcelain", "--untracked-files=no"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
}

/// Whether `oid`'s commit object carries a `gpgsig` header. Reads with
/// `git cat-file commit <oid>`, not `%G?` — measured, `%G?` prints `N` for a
/// perfectly present signature when `gpg.ssh.allowedSignersFile` is unset.
private func hasSignatureHeader(_ oid: String, in repo: FixtureRepository) throws -> Bool {
    try git.run(
        ["cat-file", "commit", oid], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text.contains("gpgsig")
}

private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

private let failingGpgScript = """
#!/bin/sh
cat > /dev/null
echo "gpg: signing failed: No secret key" >&2
exit 2
"""

private let succeedingGpgScript = """
#!/bin/sh
cat > /dev/null
printf '[GNUPG:] SIG_CREATED D\\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
exit 0
"""

/// `c1 → c2` on `main` plus `f1` built on c2, branched `feature` — feature
/// is a strict descendant of main's tip, so a fast-forward reaches it. The
/// changes are disjoint (c2 adds g.txt; f1 adds h.txt), so a --no-ff merge
/// commits cleanly.
private func fastForwardableFixture() throws -> (repo: FixtureRepository, c2: String, f1: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\n"]),
        .init("c2", files: ["f.txt": "a1\na2\na3\n", "g.txt": "g1\ng2\n"]),
        .init("f1", parents: ["c2"], files: ["f.txt": "a1\na2\na3\n", "g.txt": "g1\ng2\n", "h.txt": "h1\n"]),
    ])
    try repo.branch("feature", at: "f1")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["c2"]), try #require(repo.oids["f1"]))
}

/// `c1 → c2` on `main` plus `f1` off c1, branched `feature` — the two lines
/// diverge, but disjointly (c2 adds g.txt; f1 adds h.txt). No fast-forward
/// from main reaches feature, yet a --no-ff merge would auto-resolve.
private func divergedFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, f1: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\n"]),
        .init("c2", files: ["f.txt": "a1\na2\na3\n", "g.txt": "g1\ng2\n"]),
        .init("f1", parents: ["c1"], files: ["f.txt": "a1\na2\na3\n", "h.txt": "h1\n"]),
    ])
    try repo.branch("feature", at: "f1")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["f1"]))
}

/// `c1 → c2` on `main` plus `f1` off c1 — both sides rewrite line 3 of
/// f.txt, so merging feature into main conflicts.
private func conflictingFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, f1: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("f1", parents: ["c1"], files: ["f.txt": "l1\nl2\nB3\nl4\nl5\n"]),
    ])
    try repo.branch("feature", at: "f1")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["f1"]))
}

/// Main history plus one orphan-rooted branch `island` — the two histories
/// share no common ancestor, the shape the unrelated-histories refusal
/// exists for.
private func unrelatedFixture() throws -> (repo: FixtureRepository, island: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\n"]),
        .init("c2", files: ["f.txt": "a1\na2\n"]),
    ])
    try git.run(
        ["checkout", "-q", "--orphan", "island-tmp"], workingDirectory: repo.url.path)
    try repo.writeUntracked(["i.txt": "island\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "island-root"], workingDirectory: repo.url.path)
    try repo.branch("island")
    try repo.checkout("main")
    let island = try repo.revParse("refs/heads/island")
    return (repo, island)
}

/// A snapshot of everything a refusal must not touch: HEAD, its tree, the
/// branch tip, every ref (journal anchors included — a checkpoint would
/// write one), and the index file's own bytes.
private func fullSnapshot(_ repo: FixtureRepository) throws -> String {
    var lines: [String] = []
    lines.append(try repo.revParse("HEAD"))
    lines.append(try repo.revParse("HEAD^{tree}"))
    lines.append(try repo.revParse("refs/heads/main"))
    lines.append(try git.run(
        ["for-each-ref", "--format=%(refname) %(objectname)"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text)
    let indexBytes = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))
    let indexHash = String(try! git.run(
        ["hash-object", "--stdin"], workingDirectory: "", standardInput: indexBytes
    ).lines.first ?? "")
    lines.append("\(indexBytes.count):\(indexHash)")
    return lines.joined(separator: "\n")
}

/// The branch refs a refused merge must leave byte-identical. Journal
/// anchors are excluded on purpose: the not-a-fast-forward refusal is git's
/// own, raised after this operation's journal checkpoint was already
/// written, so the branch refs — not every ref — are the pre-existing state
/// this test compares.
private func branchRefs(_ repo: FixtureRepository) throws -> String {
    try git.run(
        ["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

// MARK: - The two intents

@Test func fastForwardMovesTheBranchToTheTargetWithoutCreatingACommit() throws {
    let (repo, _, f1) = try fastForwardableFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    let result = try Merge.run(
        branch: "feature", intent: .fastForwardOnly, at: repo.url.path,
        extraEnvironment: hermetic)

    #expect(result.head == f1, "the branch lands exactly on the target commit")
    #expect(result.fastForwarded, "a fast-forward creates no commit")
    #expect(try repo.revParse("refs/heads/main") == f1)
    #expect(try repo.revParse("HEAD") == f1, "an attached HEAD follows the branch")
    #expect(try parents(of: f1, in: repo).count == 1,
            "the target's own parentage is unchanged — no commit was created")
    #expect(try repo.revParse("refs/heads/main") != mainBefore, "the branch actually moved")
    #expect(try fileAt("main", path: "h.txt", in: repo) == "h1\n",
            "the target's change is on the branch")
}

@Test func noFastForwardCreatesAMergeCommitWithTwoParentsEvenWhenAFastForwardIsPossible() throws {
    let (repo, c2, f1) = try fastForwardableFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    // No -m: git's own default wording under --no-edit — the measured,
    // non-interactive default this call must reach without any editor.
    let result = try Merge.run(
        branch: "feature", intent: .noFastForward, at: repo.url.path,
        extraEnvironment: hermetic)

    #expect(result.head != f1, "a merge commit is a fresh object, not the target")
    #expect(!result.fastForwarded, "the merge did not fast-forward")
    #expect(try parents(of: result.head, in: repo) == [c2, f1],
            "the merge commit's parents are the old main tip and the target, in order")
    #expect(try subjects(in: repo).first == "Merge branch 'feature'",
            "the default message is git's own wording, reached without an editor")
    #expect(try repo.revParse("refs/heads/main") == result.head)
    #expect(try repo.revParse("HEAD") == result.head)
    #expect(try repo.revParse("refs/heads/main") != mainBefore, "the branch actually moved")
    #expect(try fileAt("main", path: "h.txt", in: repo) == "h1\n",
            "the merge carries the target's change")
    #expect(try fileAt("main", path: "g.txt", in: repo) == "g1\ng2\n",
            "the merge keeps the branch's own change")
}

@Test func theMergeCommitMessageIsSettableNonInteractively() throws {
    let (repo, _, _) = try fastForwardableFixture()
    defer { repo.destroy() }

    let result = try Merge.run(
        branch: "feature", intent: .noFastForward, message: "custom merge message",
        at: repo.url.path, extraEnvironment: hermetic)

    // Completing at all is the non-interactivity proof — GIT_EDITOR is
    // pinned `false` by GitProcess, so an editor invocation would fail the
    // merge. The message is asserted verbatim below.
    #expect(try subjects(in: repo).first == "custom merge message")
    #expect(try parents(of: result.head, in: repo).count == 2,
            "the message rode a real merge commit")
}

// MARK: - The ff-only contract: never the default guess

@Test func fastForwardOnlyRefusesADivergedTargetWithoutCreatingAMergeCommit() throws {
    let (repo, _, c2, f1) = try divergedFixture()
    defer { repo.destroy() }
    let before = try branchRefs(repo)

    let thrown = #expect(throws: (any Error).self) {
        _ = try Merge.run(
            branch: "feature", intent: .fastForwardOnly, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    let error = try #require(thrown, "--ff-only must refuse a target it cannot reach")
    #expect(error is GitProcess.Failure,
            "git's own not-a-fast-forward refusal is not a typed merge refusal; got \(String(describing: error))")
    #expect(try branchRefs(repo) == before, "no branch ref moved")
    #expect(try repo.revParse("refs/heads/main") == c2, "main never moved")
    #expect(try repo.revParse("HEAD") == c2)
    #expect(!mergeInProgress(in: repo), "no merge was started, let alone left resumable")
    #expect(try statusLines(in: repo).isEmpty, "the worktree and index are untouched")
    _ = f1
}

// MARK: - Conflicts: the resumable MERGE_HEAD state, exit class 8

@Test func conflictingMergeIsTypedExitClassEightAndLeavesTheMergeResumable() throws {
    let (repo, _, c2, _) = try conflictingFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "feature", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(try #require(thrown).exitClass == .blockedOnConflicts, "the exit class is 8")
    #expect(mergeInProgress(in: repo),
            "MERGE_HEAD must be present — the resumable state the resolve UI completes")
    #expect(repo.hasConflicts, "the conflicted merge leaves unmerged entries to resolve")
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch has not moved until the merge is concluded")
    #expect(try repo.revParse("HEAD") == c2)

    _ = try? git.run(
        ["merge", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Undo: restores exactly, including dropping the merge commit

@Test func undoRestoresThePreMergeStateExactlyIncludingDroppingTheMergeCommit() throws {
    let (repo, _, f1) = try fastForwardableFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")
    let beforeSubjects = try subjects(in: repo)

    let result = try Merge.run(
        branch: "feature", intent: .noFastForward, at: repo.url.path,
        extraEnvironment: hermetic)

    // Verify the merge happened before undoing — never assume it.
    let mergeOid = result.head
    #expect(try repo.revParse("refs/heads/main") == mergeOid)
    #expect(try parents(of: mergeOid, in: repo).count == 2,
            "a merge commit with two parents actually exists")
    #expect(isAncestor(f1, of: mergeOid, in: repo), "the target is reachable from the new tip")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(!isAncestor(mergeOid, of: try repo.revParse("refs/heads/main"), in: repo),
            "the merge commit is dropped from the branch — reachable from no ref it moved")
    #expect(try subjects(in: repo) == beforeSubjects, "history reads exactly as before")
    #expect(try statusLines(in: repo).isEmpty,
            "the worktree and index come back exactly — no stray merge artifacts")
}

@Test func undoRestoresAFastForwardExactly() throws {
    let (repo, _, f1) = try fastForwardableFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

    _ = try Merge.run(
        branch: "feature", intent: .fastForwardOnly, at: repo.url.path,
        extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") == f1, "the fast-forward actually moved the branch")
    #expect(try fileAt("main", path: "h.txt", in: repo) == "h1\n", "the target's file is on disk")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try statusLines(in: repo).isEmpty,
            "the fast-forwarded file is gone from the worktree and the index")
    let gone = try git.capture(
        ["rev-parse", "--verify", "--quiet", "main:h.txt"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    #expect(gone.exitCode != 0, "the target's file is gone from the branch")
}

// MARK: - Refusals typed before mutation

@Test func unknownBranchRefusesWithoutTouchingAnything() throws {
    let (repo, _, _) = try fastForwardableFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "no-such-branch", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .unknownBranch(branch) = try #require(thrown) else {
        Issue.record("expected .unknownBranch, got \(String(describing: thrown))")
        return
    }
    #expect(branch == "no-such-branch", "the refusal names the branch it refused")
    #expect(try fullSnapshot(repo) == before,
            "the refusal leaves HEAD, the branch, the index bytes, and every ref byte-identical")
    #expect(!mergeInProgress(in: repo), "the refusal precedes any merge")
}

@Test func anAlreadyUpToDateTargetRefusesWithoutTouchingAnything() throws {
    var (repo, _, _) = try fastForwardableFixture()
    defer { repo.destroy() }
    // feature's parent c2 is main's tip, so `old` is already reachable —
    // no merge of any intent would create anything.
    try repo.branch("old", at: "c2")
    let before = try fullSnapshot(repo)
    let c2 = try repo.revParse("old")

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "old", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .alreadyUpToDate(branch) = try #require(thrown) else {
        Issue.record("expected .alreadyUpToDate, got \(String(describing: thrown))")
        return
    }
    #expect(branch == "old")
    #expect(try fullSnapshot(repo) == before, "the refusal touched nothing")
    #expect(try repo.revParse("old") == c2, "the target branch never moved either")
}

@Test func unrelatedHistoriesRefuseUnlessTheIntentIsStated() throws {
    let (repo, island) = try unrelatedFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let refused = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "island", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .unrelatedHistories(branch) = try #require(refused) else {
        Issue.record("expected .unrelatedHistories, got \(String(describing: refused))")
        return
    }
    #expect(branch == "island")
    #expect(try fullSnapshot(repo) == before,
            "the refusal leaves HEAD, the branch, the index bytes, and every ref byte-identical")
    #expect(!mergeInProgress(in: repo), "the refusal precedes any merge")

    // Stated, the same merge runs: a merge commit joining two roots.
    let result = try Merge.run(
        branch: "island", intent: .noFastForward, allowUnrelated: true,
        at: repo.url.path, extraEnvironment: hermetic)

    let oldMain = try #require(try? repo.revParse("main~1"))
    let oldIsland = try #require(island)
    #expect(try parents(of: result.head, in: repo).contains(oldMain),
            "one parent is main's old tip")
    #expect(try parents(of: result.head, in: repo).contains(oldIsland),
            "the other parent is the orphan root")
    #expect(!result.fastForwarded)
    #expect(try subjects(in: repo).first == "Merge branch 'island'")
}

@Test func anUnmergedIndexRefusesBeforeAnyMergeTouchesAnything() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "main", intent: .noFastForward, at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(!files.isEmpty, "the refusal names the unmerged paths")
    #expect(try repo.revParse("HEAD") == before, "nothing was created or moved")
}

// MARK: - Signing pinned on this path

@Test func noSignNeverSignsEvenWhenConfigDemandsIt() throws {
    let (repo, _, _) = try fastForwardableFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if the merge commit tried to sign, the run
    // would fail — success under .noSign is the proof the intent reached
    // the porcelain merge.
    try installFakeGpg(failingGpgScript, in: repo)

    let result = try Merge.run(
        branch: "feature", intent: .noFastForward, signing: .noSign,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(try parents(of: result.head, in: repo).count == 2, "a merge commit was created")
    #expect(!(try hasSignatureHeader(result.head, in: repo)),
            "the merge commit must be unsigned")
}

@Test func signSignsTheMergeCommitEvenWhenConfigRefuses() throws {
    let (repo, _, _) = try fastForwardableFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "false", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Merge.run(
        branch: "feature", intent: .noFastForward, signing: .sign,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(try hasSignatureHeader(result.head, in: repo),
            "the merge commit must be signed when --gpg-sign is forwarded")
}

@Test func aSigningFailureAbortsTheMergeAndIsTyped() throws {
    let (repo, _, c2, _) = try divergedFixture()
    defer { repo.destroy() }
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)

    let thrown = #expect(throws: MergeError.self) {
        _ = try Merge.run(
            branch: "feature", intent: .noFastForward, signing: .sign,
            at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .signingFailed(reason) = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!reason.isEmpty, "the refusal carries git's own wording")
    // A signing failure is never resumable: the merge is aborted first, so
    // the repository reads exactly as it did before the attempt.
    #expect(try repo.revParse("refs/heads/main") == c2, "the branch never moved")
    #expect(try repo.revParse("HEAD") == c2, "HEAD is back on the branch")
    #expect(try statusLines(in: repo).isEmpty,
            "the abort restores the worktree and index — no merge artifacts")
    #expect(!mergeInProgress(in: repo), "no MERGE_HEAD is left behind")
    #expect(!repo.hasConflicts, "no unmerged entries are left behind")
}

// MARK: - Wire shape

@Test func mergeResultEncodesExactlyItsWireKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let result = Merge.Result(head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                              fastForwarded: true)
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["head", "fastForwarded"],
            "Merge.Result encodes exactly its two wire keys; got \(object.keys.sorted())")
    #expect(object["head"] as? String == result.head)
    #expect(object["fastForwarded"] as? Bool == true)
}
