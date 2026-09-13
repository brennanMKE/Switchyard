// ReplayTests.swift — revert and cherry-pick one commit against the current
// branch (#0360)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `RewriteTests.swift` does. A script is not a key; no keychain, ~/.gnupg,
// or ~/.ssh entry is touched.

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

/// Whether git's resumable replay state names `CHERRY_PICK_HEAD` or
/// `REVERT_HEAD` — the files a conflicted porcelain replay leaves behind.
/// Asks git where each lives rather than assuming `.git/`.
private func replayStateExists(_ name: String, in repo: FixtureRepository) -> Bool {
    guard let out = try? git.run(
        ["rev-parse", "--path-format=absolute", "--git-path", name],
        workingDirectory: repo.url.path),
        let path = out.lines.first, !path.isEmpty
    else { return false }
    return FileManager.default.fileExists(atPath: path)
}

private func pickInProgress(in repo: FixtureRepository) -> Bool {
    replayStateExists("CHERRY_PICK_HEAD", in: repo)
}

private func revertInProgress(in repo: FixtureRepository) -> Bool {
    replayStateExists("REVERT_HEAD", in: repo)
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

/// `c1 → c2 → c3` on `main`: c1 writes f.txt; c2 adds g.txt (a disjoint
/// change); c3 rewrites line 3 of f.txt. Reverting c3 returns the branch's
/// tree to c2's. (Reverting c2 here would only remove g.txt — the
/// conflict-on-revert shape lives in the same-line fixtures below.)
private func linearFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, c3: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\na4\na5\n"]),
        .init("c2", files: ["f.txt": "a1\na2\na3\na4\na5\n", "g.txt": "g1\ng2\n"]),
        .init("c3", files: ["f.txt": "a1\na2\nA3\na4\na5\n", "g.txt": "g1\ng2\n"]),
    ])
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["c3"]))
}

/// `c1 → c2` on `main` plus a side commit off c1 — the shape a cherry-pick
/// replays, and the shape an already-reachable pick must refuse.
private func sideBranchFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, side: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\n"]),
        .init("c2", files: ["f.txt": "a1\na2\nA3\n"]),
        .init("side", parents: ["c1"], files: ["side.txt": "s\n"]),
    ])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["side"]))
}

/// `c1 → c2` on `main` plus a side commit off c1 that rewrites the same
/// line c2 rewrites: picking the side commit onto `main` conflicts on
/// f.txt, the exit-8 shape.
private func sameLineSideFixture() throws -> (repo: FixtureRepository, c2: String, side: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nA3\nl4\nl5\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "l1\nl2\nS3\nl4\nl5\n"]),
    ])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["c2"]), try #require(repo.oids["side"]))
}

/// `c1 → c2 → m` on `main`, where `m` merges a side commit `s` off c1 —
/// the merge a revert must refuse.
private func mergeFixture() throws -> (repo: FixtureRepository, m: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "b1\nb2\nb3\nb4\nb5\n"]),
        .init("c2", files: ["f.txt": "b1\nb2\nb3\nb4\nb5\n", "g.txt": "g1\ng2\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "b1\nb2\nS3\nb4\nb5\n"]),
        .init("m", parents: ["c2", "side"], files: [
            "f.txt": "b1\nb2\nS3\nb4\nb5\n", "g.txt": "g1\ng2\n",
        ]),
    ])
    try repo.branch("main", at: "m")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["m"]))
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

// MARK: - The happy paths

@Test func revertProducesTheInverseCommit() throws {
    let (repo, c1, c2, c3) = try linearFixture()
    defer { repo.destroy() }
    _ = c1

    let result = try Replay.revert(commit: c3, at: repo.url.path, extraEnvironment: hermetic)

    // main now reads c1 → c2 → c3 → revert-of-c3, and the branch's tree is
    // back to c2's: the inverse change undid c3's line-3 rewrite.
    let list = try subjects(in: repo)
    #expect(list.count == 4, "c1, c2, c3, and one new revert commit — no extra commit")
    #expect(try #require(list.first) == #"Revert "c3""#,
            "the revert lands with git's default message, no editor involved")
    #expect(try repo.revParse("main~1") == c3, "the revert sits directly on the reverted commit")
    #expect(try repo.revParse("main~2") == c2)
    #expect(try repo.revParse("main^{tree}") == repo.revParse("\(c2)^{tree}"),
            "reverting the tip returns the branch's tree to the reverted commit's parent's tree")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "a1\na2\na3\na4\na5\n",
            "c3's rewrite is undone in the branch's content")
    #expect(try repo.revParse("refs/heads/main") == result.head)
    #expect(try repo.revParse("HEAD") == result.head, "an attached HEAD follows the branch")
}

@Test func cherryPickReplaysASideCommitOntoTheBranch() throws {
    let (repo, c1, c2, side) = try sideBranchFixture()
    defer { repo.destroy() }
    _ = c1

    let result = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)

    // main now reads c1 → c2 → side': the replayed commit carries the
    // picked commit's message and its change, on top of the current tip.
    let list = try subjects(in: repo)
    #expect(list.count == 3, "c1, c2, and the replayed side — no extra commit")
    #expect(try #require(list.first) == "side", "the replay keeps the picked commit's message")
    #expect(try repo.revParse("main~1") == c2, "the pick lands on the current tip")
    #expect(try fileAt("main", path: "side.txt", in: repo) == "s\n",
            "the picked change is on the branch")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "a1\na2\nA3\n",
            "the branch's own content is untouched by the pick")
    #expect(try repo.revParse("refs/heads/main") == result.head)
    #expect(try repo.revParse("HEAD") == result.head)
}

// MARK: - Conflicts: git's resumable state, the exit-8 shape

@Test func conflictingRevertLeavesGitsResumableState() throws {
    // Every commit rewrites line 3 of the same file: reverting c2 (which
    // set it to T3) asks for l3 back while the tip's tree carries c3's Z3 —
    // a collision on the very line the inverse change restores.
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\n"]),
    ])
    let c2 = try #require(repo.oids["c2"])
    let c3 = try #require(repo.oids["c3"])
    let mainBefore = try repo.revParse("refs/heads/main")

    // Reverting c2 (which set line 3 to T3) while the tip's tree carries
    // c3's A3 collides on the same line — a conflict.
    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: c2, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(files.first?.kind == .bothModified, "the collision is git's UU shape")
    #expect(revertInProgress(in: repo), "the revert must be left in progress, not aborted")
    #expect(repo.hasConflicts, "the conflicted revert leaves unmerged entries to resolve")
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch has not moved — history is untouched until the revert finishes")
    #expect(try repo.revParse("HEAD") == c3, "HEAD stays attached to the branch tip")
    #expect(try #require(thrown).exitClass == .blockedOnConflicts,
            "the exit-8 class is engine contract")

    _ = try? git.run(
        ["revert", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

@Test func conflictingCherryPickLeavesGitsResumableState() throws {
    let (repo, c2, side) = try sameLineSideFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(pickInProgress(in: repo), "the pick must be left in progress, not aborted")
    #expect(repo.hasConflicts)
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch ref has not moved — history is untouched until the pick finishes")
    #expect(try repo.revParse("HEAD") == c2, "HEAD stays attached to the branch tip")
    #expect(try #require(thrown).exitClass == .blockedOnConflicts,
            "the exit-8 class is engine contract")

    _ = try? git.run(
        ["cherry-pick", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Undo

@Test func revertUndoRestoresThePreReplayStateExactly() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

    _ = try Replay.revert(commit: "main", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the revert must actually move the branch")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try repo.revParse("main^{tree}") == repo.revParse("\(before)^{tree}"),
            "undo restores the branch's content, not just its ref")
}

@Test func cherryPickUndoRestoresThePreReplayStateExactly() throws {
    let (repo, _, _, side) = try sideBranchFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

    _ = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the pick must actually move the branch")
    #expect(try fileAt("main", path: "side.txt", in: repo) == "s\n",
            "the picked change landed")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    let gone = try git.capture(
        ["rev-parse", "--verify", "--quiet", "main:side.txt"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    #expect(gone.exitCode != 0, "the picked file is gone from the branch again")
}

// MARK: - Refusals that touch nothing

@Test func revertingAMergeRefusesAndTouchesNothing() throws {
    let (repo, m) = try mergeFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: m, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .mergeRevertRefused(commit) = try #require(thrown) else {
        Issue.record("expected .mergeRevertRefused, got \(String(describing: thrown))")
        return
    }
    #expect(commit == m, "the refusal names the merge commit")
    let after = try fullSnapshot(repo)
    #expect(after == before,
            "the refusal must leave HEAD, the branch, the index bytes, and every ref byte-identical")
    #expect(!revertInProgress(in: repo), "the refusal precedes any revert state")
    #expect(!pickInProgress(in: repo), "the refusal precedes any pick state")
}

@Test func cherryPickingAReachableCommitRefusesAndTouchesNothing() throws {
    let (repo, c1, c2, side) = try sideBranchFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    // The tip itself and an ancestor both read as already reachable.
    let tipThrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: c2, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .alreadyReachable(tipCommit) = try #require(tipThrown) else {
        Issue.record("expected .alreadyReachable for the tip, got \(String(describing: tipThrown))")
        return
    }
    #expect(tipCommit == c2)

    let ancestorThrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: c1, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .alreadyReachable = try #require(ancestorThrown) else {
        Issue.record("expected .alreadyReachable for the ancestor, got \(String(describing: ancestorThrown))")
        return
    }

    // The side commit is NOT reachable — the same call must be allowed, so
    // the refusal is the reachability probe's answer and nothing coarser.
    let allowed = try Replay.cherryPick(commit: side, at: repo.url.path, extraEnvironment: hermetic)
    #expect(try repo.revParse("refs/heads/main") == allowed.head,
            "the unreachable commit picked cleanly")
    #expect(try fullSnapshot(repo) != before, "the allowed pick moved the state the refusals kept pinned")
}

@Test func unknownCommitRefusesBothReplayOperationsWithoutTouchingAnything() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }

    let cases: [(name: String, run: () throws -> Replay.Result)] = [
        ("revert", { try Replay.revert(commit: "no-such-revision",
                                       at: repo.url.path, extraEnvironment: hermetic) }),
        ("cherry-pick", { try Replay.cherryPick(commit: "no-such-revision",
                                                at: repo.url.path, extraEnvironment: hermetic) }),
    ]
    for (name, run) in cases {
        let before = try fullSnapshot(repo)
        let thrown = #expect(throws: ReplayError.self) { try run() }
        guard case let .unknownCommit(revision) = try #require(thrown, "\(name) must refuse") else {
            Issue.record("\(name): expected .unknownCommit, got \(String(describing: thrown))")
            return
        }
        #expect(revision == "no-such-revision", "\(name) must name the revision it refused")
        let after = try fullSnapshot(repo)
        #expect(after == before,
                "\(name) must leave HEAD, the branch, the index bytes, and every ref byte-identical")
    }
}

@Test func anUnmergedIndexRefusesBothReplayOperationsBeforeAnythingStarts() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let revertThrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(revertFiles) = try #require(revertThrown) else {
        Issue.record("expected .blockedOnConflicts for revert, got \(String(describing: revertThrown))")
        return
    }
    #expect(!revertFiles.isEmpty, "the refusal names the unmerged paths")

    let pickThrown = #expect(throws: ReplayError.self) {
        _ = try Replay.cherryPick(commit: "HEAD", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard let pickError = try #require(pickThrown),
          case .blockedOnConflicts = pickError else {
        Issue.record("expected .blockedOnConflicts for cherry-pick, got \(String(describing: pickThrown))")
        return
    }

    #expect(try repo.revParse("HEAD") == before, "nothing was created or moved")
    #expect(!revertInProgress(in: repo), "the refusal leaves no revert state")
    #expect(!pickInProgress(in: repo), "the refusal leaves no pick state")
}

// MARK: - Signing: measured on the porcelain path, then pinned

@Test func revertHonorsCommitGpgSignConfig() throws {
    let (repo, _, _, c3) = try linearFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Replay.revert(commit: c3, signing: .config,
                                   at: repo.url.path, extraEnvironment: hermetic)

    // No flag was passed: the signature on the revert commit is the proof
    // the porcelain revert honors commit.gpgsign (measured — the ignore
    // finding #0060 recorded is commit-tree-specific).
    #expect(try hasSignatureHeader(result.head, in: repo),
            "the revert commit must be signed through commit.gpgsign alone")
}

@Test func cherryPickHonorsCommitGpgSignConfig() throws {
    let (repo, _, _, side) = try sideBranchFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Replay.cherryPick(commit: side, signing: .config,
                                       at: repo.url.path, extraEnvironment: hermetic)

    #expect(try hasSignatureHeader(result.head, in: repo),
            "the replayed commit must be signed through commit.gpgsign alone")
}

@Test func noSignOverridesConfigOnBothReplayPaths() throws {
    let (repo, _, _, side) = try sideBranchFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if either operation tried to sign, the run
    // would fail — success under .noSign is the proof the intent reached
    // both porcelain invocations.
    try installFakeGpg(failingGpgScript, in: repo)

    let picked = try Replay.cherryPick(commit: side, signing: .noSign,
                                       at: repo.url.path, extraEnvironment: hermetic)
    #expect(!(try hasSignatureHeader(picked.head, in: repo)),
            "the replayed commit must be unsigned when --no-sign overrides the config")

    let reverted = try Replay.revert(commit: "main~1", signing: .noSign,
                                     at: repo.url.path, extraEnvironment: hermetic)
    #expect(!(try hasSignatureHeader(reverted.head, in: repo)),
            "the revert commit must be unsigned when --no-sign overrides the config")
}

@Test func aSigningFailureIsTypedAndCleansUp() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    let before = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: ReplayError.self) {
        _ = try Replay.revert(commit: "main", signing: .config,
                              at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .signingFailed(reason) = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!reason.isEmpty, "the refusal carries git's own wording")
    #expect(try repo.revParse("refs/heads/main") == before,
            "no commit was written and the ref never moved")
    #expect(!revertInProgress(in: repo), "the failed revert was aborted, not left resumable")
    #expect(!repo.hasConflicts, "the abort restored a clean index")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "a1\na2\nA3\na4\na5\n",
            "the abort restored the worktree the half-applied revert had touched")
}

// MARK: - Wire shape

@Test func replayResultEncodesExactlyItsWireKey() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let result = Replay.Result(head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["head"],
            "Replay.Result encodes exactly its one wire key; got \(object.keys.sorted())")
    #expect(object["head"] as? String == result.head)
}
