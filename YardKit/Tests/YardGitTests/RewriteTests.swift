// RewriteTests.swift — reorder, drop, and reword on the first-parent chain
// (#0063)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `SplitTests.swift` and `AbsorbTests.swift` do. A script is not a key; no
// keychain, ~/.gnupg, or ~/.ssh entry is touched.

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

private func stagedPaths(in repo: FixtureRepository) throws -> [String] {
    try git.run(
        ["diff", "--cached", "--name-only"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines
}

/// Whether a cherry-pick is in progress — the resumable state a conflicted
/// replay leaves behind. Asks git where `CHERRY_PICK_HEAD` lives rather than
/// assuming `.git/`.
private func pickInProgress(in repo: FixtureRepository) -> Bool {
    guard let out = try? git.run(
        ["rev-parse", "--path-format=absolute", "--git-path", "CHERRY_PICK_HEAD"],
        workingDirectory: repo.url.path),
        let path = out.lines.first, !path.isEmpty
    else { return false }
    return FileManager.default.fileExists(atPath: path)
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
/// change); c3 rewrites line 3 of f.txt. The disjointness is what lets a
/// reorder replay cleanly — c3's pick onto c1 and c2's pick after it both
/// apply without touching each other's lines.
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

/// `c1 → c2 → c3` where every commit rewrites line 3 of the same file: c2
/// sets it to `T3` over c1's `l3`, c3 sets `Z3`. Dropping c2 or moving c3
/// before it makes the pick's base (`c2`, line 3 = T3) disagree with the new
/// head's tree (line 3 = l3) on the very line the pick changes — a conflict.
private func oneLineFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, c3: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n"]),
    ])
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["c3"]))
}

/// `c1 → c2 → m` on `main`, where `m` merges a side commit `s` off c1 —
/// a merge commit on the branch's first-parent chain. The two lines of
/// change are disjoint (c2 adds g.txt; the side commit rewrites line 3),
/// so the fixture's own merge resolves cleanly and the replay below the
/// merge gets past the side pick before hitting the merge.
private func mergeFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, m: String) {
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
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["m"]))
}

/// `c1 → c2` on `main` plus a side commit off c1 — the shapes a
/// cross-branch reorder and an off-branch reword/drop must refuse.
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

// MARK: - Reword

@Test func rewordRewritesTheMessageAndReplaysTheDescendants() throws {
    let (repo, c1, c2, c3) = try linearFixture()
    defer { repo.destroy() }

    // No GIT_EDITOR is involved by construction — GitProcess pins it to
    // `false`, and the message rides stdin to commit-tree — so this call
    // completing at all is the non-interactivity proof. The message is
    // asserted below, verbatim.
    let result = try Rewrite.reword(
        commit: c2, message: "rewritten subject", at: repo.url.path, extraEnvironment: hermetic)

    // main now reads c1 → c2' → c3': the same trees, the new message.
    let list = try subjects(in: repo)
    #expect(list.count == 3, "c1, the reworded commit, the replayed c3 — no extra commit")
    #expect(try #require(list.first) == "c3", "the replay keeps the descendant's message")
    #expect(try #require(list.dropFirst().first) == "rewritten subject")
    #expect(try #require(list.last) == "c1", "the original subject stays only on c1")
    #expect(try repo.revParse("main~2") == c1)
    #expect(try repo.revParse("\(result.head)~1^{tree}") == repo.revParse("\(c2)^{tree}"),
            "the rebuilt commit carries c2's tree unchanged")
    #expect(try repo.revParse("main^{tree}") == repo.revParse("\(c3)^{tree}"),
            "the replayed descendant keeps its own tree")
    #expect(try repo.revParse("\(result.head)~1") != c2, "the commit was rewritten")
    #expect(try repo.revParse("main") != c3, "the descendant was rewritten")
    #expect(try repo.revParse("refs/heads/main") == result.head)
    #expect(try repo.revParse("HEAD") == result.head, "an attached HEAD follows the branch")
}

@Test func reorderingToTheSameMessageRefusesWithNothingToDo() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)
    // The exact original message, raw (%B), is what the walk compares
    // against — a reword to the same bytes is a no-op.
    let original = try git.run(
        ["log", "-n", "1", "--format=%B", c2], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reword(
            commit: c2, message: original, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .nothingToDo,
            "the message already matches — rewriting every descendant oid for nothing is refused")
    #expect(try fullSnapshot(repo) == before, "the refusal touched nothing")
}

@Test func rewordOfTheTipRebuildsTheTipWithoutAReplay() throws {
    let (repo, _, c2, c3) = try linearFixture()
    defer { repo.destroy() }

    let result = try Rewrite.reword(
        commit: "main", message: "tip rewritten", at: repo.url.path, extraEnvironment: hermetic)

    let list = try subjects(in: repo)
    #expect(list.count == 3)
    #expect(try #require(list.first) == "tip rewritten")
    #expect(try repo.revParse("\(result.head)^") == c2, "the rebuilt tip's parent is unchanged")
    #expect(try repo.revParse("\(result.head)^{tree}") == repo.revParse("\(c3)^{tree}"),
            "the rebuilt tip carries c3's tree")
    #expect(try repo.revParse("refs/heads/main") == result.head)
}

// MARK: - Drop

@Test func dropRemovesTheCommitAndItsChanges() throws {
    let (repo, c1, c2, _) = try linearFixture()
    defer { repo.destroy() }

    let result = try Rewrite.drop(commit: c2, at: repo.url.path, extraEnvironment: hermetic)

    // main now reads c1 → c3': the dropped commit's g.txt is gone.
    let count = try git.run(
        ["rev-list", "--count", "main"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines[0]
    #expect(count == "2")
    #expect(try repo.revParse("main~1") == c1)
    let replayedSubject = try #require(subjects(in: repo).first)
    #expect(replayedSubject == "c3", "the replay keeps the descendant's message")
    #expect(try repo.revParse("main") != repo.oids["c3"], "the descendant was rewritten")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "a1\na2\nA3\na4\na5\n",
            "the descendant's own change survives the drop")
    let gone = try git.capture(
        ["rev-parse", "--verify", "--quiet", "main:g.txt"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    #expect(gone.exitCode != 0, "the dropped commit's file is gone from the branch")
    #expect(try repo.revParse("refs/heads/main") == result.head)
}

@Test func dropOfTheTipMovesTheRefToTheParentWithoutAReplay() throws {
    let (repo, _, c2, c3) = try linearFixture()
    defer { repo.destroy() }

    let result = try Rewrite.drop(commit: c3, at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") == c2,
            "dropping the tip moves the ref straight onto its parent")
    #expect(result.head == c2, "the payload names the branch's new head")
    #expect(try repo.revParse("HEAD") == c2)
    let count = try git.run(
        ["rev-list", "--count", "main"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines[0]
    #expect(count == "2")
}

@Test func droppingAMergeRefusesAndTouchesNothing() throws {
    let (repo, _, _, m) = try mergeFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.drop(commit: m, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .dropMergeRefused(commit) = try #require(thrown) else {
        Issue.record("expected .dropMergeRefused, got \(String(describing: thrown))")
        return
    }
    #expect(commit == m, "the refusal names the merge commit")
    let after = try fullSnapshot(repo)
    #expect(after == before,
            "dropping a merge must leave HEAD, the branch, the index bytes, and every ref byte-identical")
    #expect(!pickInProgress(in: repo), "the refusal precedes any replay")
}

// MARK: - Reorder

@Test func reorderBeforePutsTheCommitImmediatelyBeforeTheReference() throws {
    let (repo, c1, _, c3) = try linearFixture()
    defer { repo.destroy() }

    let result = try Rewrite.reorder(
        commit: c3, position: .before, reference: try #require(repo.oids["c2"]),
        at: repo.url.path, extraEnvironment: hermetic)
    _ = c1

    // main now reads c1 → c3' → c2': the moved commit sits first.
    let list = try subjects(in: repo)
    #expect(list.count == 3)
    #expect(try #require(list.first) == "c2", "the reference commit is the new tip")
    #expect(try #require(list.dropFirst().first) == "c3", "the moved commit sits before it")
    #expect(try #require(list.last) == "c1")
    // A pure reorder re-applies the same set of changes in a new order, so
    // the branch's final tree is the original tip's tree, byte for byte.
    #expect(try repo.revParse("main^{tree}") == repo.revParse("\(c3)^{tree}"),
            "the reorder must not change what the branch contains")
    #expect(try repo.revParse("refs/heads/main") == result.head)
}

@Test func reorderAfterPutsTheCommitImmediatelyAfterTheReference() throws {
    let (repo, c1, _, c3) = try linearFixture()
    defer { repo.destroy() }

        let result = try Rewrite.reorder(
        commit: try #require(repo.oids["c2"]), position: .after, reference: c3,
        at: repo.url.path, extraEnvironment: hermetic)
    _ = c1

    // Moving c2 after c3 and moving c3 before c2 are the same new chain.
    let list = try subjects(in: repo)
    #expect(list.count == 3)
    #expect(try #require(list.first) == "c2")
    #expect(try #require(list.dropFirst().first) == "c3")
    #expect(try repo.revParse("main^{tree}") == repo.revParse("\(c3)^{tree}"))
    #expect(try repo.revParse("refs/heads/main") == result.head)
}

@Test func reorderAlreadyAtThePositionRefusesWithNothingToDo() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    // c3 is already immediately after c2; c2 is already immediately before
    // c3. Both orderings are the chain as it stands.
    let thrownAfter = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(
            commit: repo.revParse("main"), position: .after,
            reference: repo.revParse("main~1"), at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrownAfter) == .nothingToDo)
    let thrownBefore = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(
            commit: repo.revParse("main~1"), position: .before,
            reference: repo.revParse("main"), at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrownBefore) == .nothingToDo)
    #expect(try fullSnapshot(repo) == before, "the refusals moved nothing")
}

// MARK: - Undo

@Test func rewordUndoRestoresThePreRewriteStateExactly() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")
    let stagedVersion = "h1\nh2\nstaged\n"
    // Unrelated staged work rides through the rewrite: it is the caller's,
    // never consumed by the machinery. Rewording the tip needs no
    // descendant replay — the same shape Split's undo test uses.
    try repo.writeUntracked(["h.txt": stagedVersion])
    try git.run(["add", "h.txt"], workingDirectory: repo.url.path)

    _ = try Rewrite.reword(
        commit: "main", message: "rewritten", at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the reword must actually move the branch")
    #expect(try stagedPaths(in: repo) == ["h.txt"],
            "the caller's staged work survives the rewrite")
    #expect(try stagedFileBytes("h.txt", in: repo) == stagedVersion)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try stagedPaths(in: repo) == ["h.txt"],
            "the staged file comes back staged, from the checkpoint's index capture")
    #expect(try stagedFileBytes("h.txt", in: repo) == stagedVersion)
}

private func stagedFileBytes(_ path: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["show", ":\(path)"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

@Test func dropUndoRestoresThePreRewriteStateExactly() throws {
    let (repo, _, _, c3) = try linearFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

_ = try Rewrite.drop(commit: repo.revParse("main~1"), at: repo.url.path,
                         extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the drop must actually move the branch")
    #expect(try #require(subjects(in: repo).first) == "c3",
            "the branch now ends at the replayed descendant")
    #expect(try repo.revParse("main^{tree}") != repo.revParse("\(c3)^{tree}"),
            "the replayed tip's tree lacks the dropped commit's change")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "a1\na2\nA3\na4\na5\n",
            "the descendant's own change survives")
    let gone = try git.capture(
        ["rev-parse", "--verify", "--quiet", "main:g.txt"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    #expect(gone.exitCode != 0, "the dropped commit's file is gone")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
}

@Test func reorderUndoRestoresThePreRewriteStateExactly() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

    _ = try Rewrite.reorder(
        commit: "main", position: .before, reference: c2,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the reorder must move the branch")
    let list = try subjects(in: repo)
    #expect(try #require(list.first) == "c2", "the reference commit is the new tip")
    #expect(try #require(list.dropFirst().first) == "c3", "the moved commit sits before it")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try #require(subjects(in: repo).first) == "c3", "the original order is back")
}

// MARK: - Conflicts: the pick-in-progress exit-8 state

@Test func conflictingDropLeavesThePickResumable() throws {
    let (repo, c1, c2, _) = try oneLineFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.drop(commit: c2, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(pickInProgress(in: repo), "the pick must be left in progress, not aborted")
    #expect(repo.hasConflicts, "the conflicted pick leaves unmerged entries to resolve")
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch has not moved — history is untouched until the replay finishes")
    #expect(try repo.revParse("HEAD") == c1, "HEAD is detached on the drop's base")

    _ = try? git.run(
        ["cherry-pick", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

@Test func conflictingReorderLeavesThePickResumable() throws {
    let (repo, c1, c2, c3) = try oneLineFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(
            commit: c3, position: .before, reference: c2,
            at: repo.url.path, extraEnvironment: hermetic)
    }
    _ = mainBefore
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(pickInProgress(in: repo), "the pick must be left in progress, not aborted")
    #expect(repo.hasConflicts)
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch ref has not moved — history is untouched until the replay finishes")
    #expect(try repo.revParse("HEAD") == c1, "HEAD is detached on the unchanged base")

    _ = try? git.run(
        ["cherry-pick", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - A merge in the replay tail fails git's way, cleaned up

@Test func rewordBelowAMergeFailsTheReplayAndTouchesNothing() throws {
    let (repo, _, c2, m) = try mergeFixture()
    defer { repo.destroy() }
    let mainBefore = try repo.revParse("refs/heads/main")

    // The descendants of c2 include the merge itself; cherry-pick refuses a
    // merge without -m, the replay fails, and the cleanup aborts the pick
    // and re-attaches HEAD. Nothing was moved.
    var caught: Error?
    do {
        _ = try Rewrite.reword(
            commit: c2, message: "rewritten", at: repo.url.path, extraEnvironment: hermetic)
    } catch {
        caught = error
    }
    let error = try #require(caught, "the merge in the replay tail must fail the rewrite")
    #expect(error is GitProcess.Failure,
            "git's own refusal is not a typed rewrite refusal; got \(String(describing: error))")
    #expect(!pickInProgress(in: repo), "the cleanup aborted the failed replay")
    #expect(try repo.revParse("refs/heads/main") == mainBefore, "the branch never moved")
    #expect(try repo.revParse("HEAD") == mainBefore, "HEAD was re-attached to the branch")
    _ = m
}

// MARK: - Signing preserved

@Test func signedCommitsStaySignedThroughAReword() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Rewrite.reword(
        commit: c2, message: "signed rewrite", signing: .config,
        at: repo.url.path, extraEnvironment: hermetic)

    // The rebuilt commit is signed — commit-tree is plumbing and ignores
    // commit.gpgsign (measured), so the explicit flag is what signed it.
    #expect(try hasSignatureHeader(result.head, in: repo),
            "the rebuilt commit must be signed")
}

@Test func noSignIsForwardedToTheRebuiltCommitAndTheReplay() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if the rebuild or any replayed pick tried to
    // sign, the run would fail — success under .noSign is the proof the
    // intent reached both.
    try installFakeGpg(failingGpgScript, in: repo)

    let result = try Rewrite.reword(
        commit: c2, message: "unsigned rewrite", signing: .noSign,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(!(try hasSignatureHeader(result.head, in: repo)),
            "the rebuilt commit must be unsigned")
    let replayed = try #require(subjects(in: repo).first)
    #expect(replayed == "c3", "the descendant was replayed")
    #expect(!(try hasSignatureHeader(try repo.revParse("main"), in: repo)),
            "the replayed descendant must be unsigned")
}

@Test func signIsForwardedToTheReplay() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "false", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    // Dropping c2 replays c3 — the only commits this operation creates —
    // so a signed replayed descendant is the proof --gpg-sign reached the
    // cherry-pick.
    let result = try Rewrite.drop(
        commit: c2, signing: .sign, at: repo.url.path, extraEnvironment: hermetic)

    #expect(try hasSignatureHeader(result.head, in: repo),
            "the replayed descendant must be signed when --sign is forwarded")
}

// MARK: - Refusals that touch nothing

@Test func unknownCommitRefusesEverySubcommandWithoutTouchingAnything() throws {
    let (repo, _, _, c3) = try linearFixture()
    defer { repo.destroy() }

    let cases: [(name: String, run: () throws -> Rewrite.Result)] = [
        ("reword", { try Rewrite.reword(commit: "no-such-revision", message: "m",
                                        at: repo.url.path, extraEnvironment: hermetic) }),
        ("drop", { try Rewrite.drop(commit: "no-such-revision",
                                    at: repo.url.path, extraEnvironment: hermetic) }),
        ("reorder commit", { try Rewrite.reorder(commit: "no-such-revision", position: .before,
                                                 reference: "main", at: repo.url.path,
                                                 extraEnvironment: hermetic) }),
        ("reorder reference", { try Rewrite.reorder(commit: "main", position: .after,
                                                    reference: "no-such-revision",
                                                    at: repo.url.path,
                                                    extraEnvironment: hermetic) }),
    ]
    for (name, run) in cases {
        let before = try fullSnapshot(repo)
        let thrown = #expect(throws: RewriteError.self) { try run() }
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

@Test func aCommitOffTheCallerRefRefusesRewordAndDrop() throws {
    let (repo, _, _, side) = try sideBranchFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")

    let rewordThrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reword(commit: side, message: "m", at: repo.url.path,
                               extraEnvironment: hermetic)
    }
    guard case let .commitNotOnRef(commit, ref) = try #require(rewordThrown) else {
        Issue.record("expected .commitNotOnRef, got \(String(describing: rewordThrown))")
        return
    }
    #expect(commit == side)
    #expect(ref == "refs/heads/main")

    let dropThrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.drop(commit: side, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(dropThrown).isCommitNotOnRef)

    #expect(try repo.revParse("refs/heads/main") == #require(repo.oids["c2"]),
            "nothing moved")
}

private extension RewriteError {
    var isCommitNotOnRef: Bool {
        if case .commitNotOnRef = self { return true }
        return false
    }
}

@Test func reorderTargetsOffTheFirstParentChainRefuse() throws {
    let (repo, _, _, side) = try sideBranchFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)
    let c2 = try #require(repo.oids["c2"])

    // The side commit is an ancestor of main but not on its first-parent
    // chain: moving it within the chain is not a reorder.
    let offChainCommit = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(commit: side, position: .after, reference: c2,
                                at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .reorderTargetNotOnBranch(revision, ref) = try #require(offChainCommit) else {
        Issue.record("expected .reorderTargetNotOnBranch, got \(String(describing: offChainCommit))")
        return
    }
    #expect(revision == side)
    #expect(ref == "refs/heads/main")

    // The reference off the chain is the same refusal.
    let offChainReference = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reorder(commit: c2, position: .before, reference: side,
                                at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(offChainReference).isReorderTargetNotOnBranch)

    let after = try fullSnapshot(repo)
    #expect(after == before, "the refusals leave HEAD, the branch, the index bytes, and every ref byte-identical")
}

private extension RewriteError {
    var isReorderTargetNotOnBranch: Bool {
        if case .reorderTargetNotOnBranch = self { return true }
        return false
    }
}

@Test func anUnmergedIndexRefusesBeforeAnyRewriteTouchesAnything() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let rewordThrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reword(commit: "HEAD", message: "m", at: repo.url.path,
                               extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(rewordThrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: rewordThrown))")
        return
    }
    #expect(!files.isEmpty, "the refusal names the unmerged paths")
    #expect(try repo.revParse("HEAD") == before, "nothing was created or moved")
    #expect(!pickInProgress(in: repo), "the refusal precedes any replay")
}

@Test func aSigningFailureIsTypedAndTouchesNothing() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    let before = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: RewriteError.self) {
        _ = try Rewrite.reword(commit: c2, message: "m", signing: .sign,
                               at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .signingFailed(reason) = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!reason.isEmpty, "the refusal carries git's own wording")
    #expect(try repo.revParse("refs/heads/main") == before, "no commit was written and the ref never moved")
    #expect(!pickInProgress(in: repo), "the failure happened before any replay")
}

// MARK: - Wire shape

@Test func rewriteResultEncodesExactlyItsWireKey() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let result = Rewrite.Result(head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["head"],
            "Rewrite.Result encodes exactly its one wire key; got \(object.keys.sorted())")
    #expect(object["head"] as? String == result.head)
}
