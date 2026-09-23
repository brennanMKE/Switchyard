// SplitTests.swift — splitting one commit into two along a hunk boundary
// (#0062)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `AbsorbTests.swift` and `CommitCreateGPGTests.swift` do. A script is not a
// key; no keychain, ~/.gnupg, or ~/.ssh entry is touched.

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

private func stagedFile(_ path: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["show", ":\(path)"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

/// Whether a cherry-pick is in progress — the resumable state a conflicted
/// replay leaves behind. Asks git where `CHERRY_PICK_HEAD` lives rather than
/// assuming `.git/`, the same way the fixture harness locates sequencer
/// directories.
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

/// Writes `script` into the fixture worktree, marks it executable, and points
/// `gpg.program` at it — the #0036 fixture idiom, duplicated from
/// `AbsorbTests.swift` (that file's helpers are private to it).
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

/// Fails the way a real gpg with no usable secret key does.
private let failingGpgScript = """
#!/bin/sh
cat > /dev/null
echo "gpg: signing failed: No secret key" >&2
exit 2
"""

/// Reports success the way git requires: `[GNUPG:] SIG_CREATED ` on the
/// status fd (git passes `--status-fd=2`) and ASCII armor on stdout.
private let succeedingGpgScript = """
#!/bin/sh
cat > /dev/null
printf '[GNUPG:] SIG_CREATED D\\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
exit 0
"""

/// `c1 → c2` on `main`: fourteen lines at c1; at c2 line 3 becomes `T3` and
/// line 12 becomes `T12`. The two changes are nine lines apart — far beyond
/// `--unified=3`'s reach — so `commitDiff` reports exactly two hunks, one
/// carrying `+T3` and the other `+T12`.
private func twoHunkFixture() throws -> (repo: FixtureRepository, c1: String, c2: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
    ])
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]))
}

/// The commit's diff parsed into hunks — what the split itself locates by.
private func hunks(of revision: String, in repo: FixtureRepository) throws -> [Hunk] {
    try commitDiff(at: repo.url.path, revision: revision, git: git).flatMap(\.hunks)
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

// MARK: - The criterion: the pair rebuilds the original tree

@Test func splitRebuildsTheOriginalTreeAlongTheNamedBoundary() throws {
    let (repo, c1, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    let firstHunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") },
        "the line-3 hunk must exist in the commit's listing")
    #expect(try hunks(of: c2, in: repo).count == 2, "the fixture commits exactly two hunks")

    let result = try Split.run(
        commit: c2, hunkID: firstHunk.id, at: repo.url.path, extraEnvironment: hermetic)

    // The criterion: the second half's tree equals the original commit's
    // tree, byte for byte.
    let originalTree = try repo.revParse("\(c2)^{tree}")
    #expect(try repo.revParse("\(result.second)^{tree}") == originalTree,
            "the pair must rebuild the original commit's tree")
    // And the parentage is C^ → first → second.
    #expect(try repo.revParse("\(result.first)^") == c1,
            "the first half's parent is C^")
    #expect(try repo.revParse("\(result.second)^") == result.first,
            "the second half's parent is the first half")
    // The branch moved once, to the second half.
    #expect(try repo.revParse("refs/heads/main") == result.second)
    #expect(try repo.revParse("HEAD") == result.second, "an attached HEAD follows the branch")
    let firstTree = try repo.revParse("\(result.first)^{tree}")
    let secondTree = try repo.revParse("\(result.second)^{tree}")
    #expect(firstTree != secondTree,
        "the two halves carry different trees — the boundary did something")

    // The first half contains ONLY the chosen hunk's change: T3 present,
    // the second hunk's T12 absent (still the original l12).
    #expect(try fileAt(result.first, path: "f.txt", in: repo)
        == "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n")
    // The second half carries the rest.
    #expect(try fileAt(result.second, path: "f.txt", in: repo)
        == "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n")
    // The worktree was never touched by the split itself.
    #expect(try stagedPaths(in: repo).isEmpty)
}

// MARK: - Messages set non-interactively

@Test func messagesAreSetNonInteractively() throws {
    let (repo, _, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })

    // No GIT_EDITOR is involved by construction — GitProcess pins it to
    // `false`, and both messages ride `-m`-equivalent plumbing — so this
    // call completing at all is the non-interactivity proof. The messages
    // themselves are asserted below, verbatim.
    let result = try Split.run(
        commit: c2, hunkID: hunk.id,
        first: "first half subject", second: "second half subject",
        at: repo.url.path, extraEnvironment: hermetic)

    let list = try subjects(in: repo)
    #expect(list.count == 3, "c1, first, second — no fixup or extra commit")
    #expect(try #require(list.first) == "second half subject")
    #expect(try #require(list.dropFirst().first) == "first half subject")
    #expect(try #require(list.last) == "c1", "the original subject stays only on c1")

    // The oid the payload names is the commit whose subject was asserted.
    #expect(try repo.revParse("refs/heads/main") == result.second)
}

@Test func messagesDefaultToTheOriginalCommitMessage() throws {
    let (repo, _, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T12") },
        "the line-12 hunk must exist in the commit's listing")

    _ = try Split.run(
        commit: c2, hunkID: hunk.id, at: repo.url.path, extraEnvironment: hermetic)

    let list = try subjects(in: repo)
    #expect(list.count == 3)
    #expect(try #require(list.first) == "c2", "the second half defaults to C's original message")
    #expect(try #require(list.dropFirst().first) == "c2", "the first half defaults to C's original message")
}

// MARK: - Root commit: the empty-tree base

@Test func rootCommitSplitsAgainstTheEmptyTree() throws {
    var repo = try FixtureRepository()
    // A root commit that adds TWO files yields exactly two hunks — one per
    // file — which is the minimum a root split can work with.
    try repo.build([
        .init("root", files: [
            "f.txt": "f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8\n",
            "g.txt": "g1\ng2\ng3\ng4\ng5\ng6\ng7\ng8\n",
        ]),
    ])
    defer { repo.destroy() }
    let root = try #require(repo.oids["root"])
    let fHunk = try #require(
        try hunks(of: root, in: repo).first { $0.path == "f.txt" },
        "the f.txt hunk of the root commit must exist")

    let result = try Split.run(
        commit: root, hunkID: fHunk.id,
        first: "root first half", at: repo.url.path, extraEnvironment: hermetic)

    // The first half is a new root: no parent at all, carrying only f.txt.
    let parentProbe = try git.capture(
        ["rev-parse", "--verify", "--quiet", "\(result.first)^"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
    #expect(parentProbe.exitCode != 0, "the first half of a root split has no parent")
    let firstHalfTree = try repo.revParse("\(result.first)^{tree}")
    let rootTree = try repo.revParse("\(root)^{tree}")
    #expect(firstHalfTree != rootTree, "the first half lacks g.txt")
    #expect(try fileAt(result.first, path: "f.txt", in: repo)
        == "f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8\n")
    // The criterion holds at the root too.
    #expect(try repo.revParse("\(result.second)^{tree}") == rootTree,
            "the pair rebuilds the root commit's tree")
    #expect(try repo.revParse("refs/heads/main") == result.second)
}

// MARK: - Refusals that touch nothing

@Test func unknownHunkIDRefusesWithoutTouchingAnything() throws {
    let (repo, _, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: c2, hunkID: "0123456789ab", at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .unknownHunkID(id) = try #require(thrown) else {
        Issue.record("expected .unknownHunkID, got \(String(describing: thrown))")
        return
    }
    #expect(id == "0123456789ab")

    let after = try fullSnapshot(repo)
    #expect(after == before,
            "an unknown id must leave HEAD, the branch, the index bytes, and every ref byte-identical")
}

@Test func fewerThanTwoHunksRefusesWithNothingToDo() throws {
    var repo = try FixtureRepository()
    // c1 is a root commit adding one file: exactly one hunk. `empty`
    // rewrites f.txt with identical content, so `git commit --allow-empty`
    // records an empty diff — nothing for any listing to report.
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
        .init("empty", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
    ])
    defer { repo.destroy() }
    let c1 = try #require(repo.oids["c1"])
    let empty = try #require(repo.oids["empty"])
    let oneHunk = try #require(try hunks(of: c1, in: repo).first)
    #expect(try hunks(of: c1, in: repo).count == 1)

    let thrownOne = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: c1, hunkID: oneHunk.id, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrownOne) == .nothingToDo,
            "a one-hunk commit has no boundary to split at")

    let thrownEmpty = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: repo.revParse("HEAD"), hunkID: "0123456789ab",
            at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrownEmpty) == .nothingToDo,
            "an empty diff has nothing to split either — checked before the id lookup")
    #expect(try repo.revParse("HEAD") == #require(repo.oids["empty"]),
            "the refusals moved nothing")
}

@Test func commitOffTheCallerBranchRefuses() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\n"]),
    ])
    try repo.build([.init("side", parents: ["c1"], files: ["side.txt": "s\n"])])
    try repo.branch("main", at: "c2")
    try repo.checkout("main")
    defer { repo.destroy() }
    let side = try #require(repo.oids["side"])
    let sideHunk = try #require(try hunks(of: side, in: repo).first)
    let before = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: side, hunkID: sideHunk.id, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown).isCommitNotOnRef,
            "a commit on another line of history has no descendants on the caller's ref")
    #expect(try repo.revParse("refs/heads/main") == before, "nothing moved")
}

private extension SplitError {
    /// A small readability shim so the test asserts the case without a
    /// full pattern match at the call site.
    var isCommitNotOnRef: Bool {
        if case .commitNotOnRef = self { return true }
        return false
    }
}

// MARK: - Unmerged index refused before anything is touched

@Test func unmergedIndexIsRefusedBeforeTheSplitTouchesAnything() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")
    // A conflicted index has no ordinary listing to name a hunk from; the
    // conflict refusal fires first. Any id string exercises the same path.
    let thrown = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: "HEAD", hunkID: "0123456789ab", at: repo.url.path,
            extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(!files.isEmpty, "the refusal names the unmerged paths")
    #expect(try repo.revParse("HEAD") == before, "nothing was created or moved")
    #expect(!pickInProgress(in: repo), "the refusal precedes any replay")
}

// MARK: - Undo

@Test func undoRestoresThePreSplitStateExactly() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
    ])
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")
    let stagedVersion = "l1\nl2\nl3\nstaged\nl5\nl6\nl7\nl8\n"
    // Unrelated staged work rides through the split: it is the caller's,
    // never consumed by the hunk machinery.
    try repo.writeUntracked(["g.txt": stagedVersion])
    try git.run(["add", "g.txt"], workingDirectory: repo.url.path)

    let c2 = try #require(repo.oids["c2"])
    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })
    #expect(try hunks(of: c2, in: repo).count == 2, "the fixture commits exactly two hunks")
    _ = try Split.run(
        commit: c2, hunkID: hunk.id, first: "half one", second: "half two",
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(try repo.revParse("HEAD") != before, "the split must actually move the branch")
    #expect(try stagedPaths(in: repo) == ["g.txt"],
            "the caller's staged work survives the split")
    #expect(try stagedFile("g.txt", in: repo) == stagedVersion)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try stagedPaths(in: repo) == ["g.txt"],
            "the staged hunk comes back staged, from the checkpoint's index capture")
    #expect(try stagedFile("g.txt", in: repo) == stagedVersion)
}

// MARK: - Descendant replay

@Test func descendantsReplayOntoTheNewPairAndTheRefMovesOnce() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
        // A linear descendant: its pick's base is c2, whose tree the second
        // half reproduces exactly, so the pick applies cleanly (measured).
        .init("c3", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nE8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
    ])
    defer { repo.destroy() }
    let c1 = try #require(repo.oids["c1"])
    let c2 = try #require(repo.oids["c2"])
    let c3 = try #require(repo.oids["c3"])
    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })

    let result = try Split.run(
        commit: c2, hunkID: hunk.id, at: repo.url.path, extraEnvironment: hermetic)

    // main now reads c1 → first → second → c3' and nothing else.
    let count = try git.run(
        ["rev-list", "--count", "main"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines[0]
    #expect(count == "4")
    #expect(try repo.revParse("main~3") == c1)
    #expect(try repo.revParse("main~2") == result.first)
    #expect(try repo.revParse("main~1") == result.second)
    // The replayed descendant keeps its own tree and its own message.
    #expect(try repo.revParse("main") != c3, "the descendant was rewritten")
    let c3Tree = try repo.revParse("\(c3)^{tree}")
    #expect(try repo.revParse("main^{tree}") == c3Tree,
            "the replayed tip's tree equals the original descendant's")
    let replayedSubject = try #require(subjects(in: repo).first)
    #expect(replayedSubject == "c3", "the replay keeps the descendant's message")
    let c2Tree = try repo.revParse("\(c2)^{tree}")
    #expect(try repo.revParse("\(result.second)^{tree}") == c2Tree,
            "the criterion holds with descendants present too")
}

@Test func conflictingReplayLeavesThePickResumable() throws {
    // x1 is built BEFORE s on purpose (#0394 round 1, measured): the
    // replay's pick list is `git rev-list --reverse c2..m`, whose sibling
    // order rides the commit-date tie-break (Split.swift documents it).
    // Built in the other order, a load-slowed fixture build lets s and x1
    // cross a second boundary, `rev-list --reverse` then lists s first, s
    // picks cleanly onto the second half (its parent IS c2), HEAD moves off
    // the second half, and the `HEAD^{tree}` assertion below fails on the
    // tie-break, not on the contract. x1 first pins x1 as the first pick in
    // both timings — x1's pick is the one that conflicts — so the test
    // measures the resumable stop, not the machine's clock.
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
        // x1, a side branch off c1, rewrites line 3 — the very line the
        // chosen hunk changes. Measured: picking it onto the second half
        // (whose line 3 is T3) conflicts, because the pick's base is x1's
        // parent c1, where line 3 is l3.
        .init("x1", parents: ["c1"], files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\n"]),
        // s, on top of c2, changes an unrelated line.
        .init("s", parents: ["c2"], files: ["f.txt": "l1\nl2\nT3\nl4\nl5\nl6\nS7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
        // The merge resolves line 3 to x1's value; a dirty merge the
        // fixture resolves by writing the file (the harness's own idiom).
        .init("m", parents: ["s", "x1"], files: ["f.txt": "l1\nl2\nZ3\nl4\nl5\nl6\nS7\nl8\nl9\nl10\nl11\nT12\nl13\nl14\n"]),
    ])
    try repo.branch("main", at: "m")
    try repo.checkout("main")
    defer { repo.destroy() }
    let c2 = try #require(repo.oids["c2"])
    let mainBefore = try repo.revParse("refs/heads/main")
    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })

    let thrown = #expect(throws: SplitError.self) {
        _ = try Split.run(
            commit: c2, hunkID: hunk.id, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.map(\.path) == ["f.txt"], "the conflicted path is named")
    #expect(pickInProgress(in: repo), "the pick must be left in progress, not aborted")
    #expect(repo.hasConflicts, "the conflicted pick leaves unmerged entries to resolve")
    #expect(try repo.revParse("refs/heads/main") == mainBefore,
            "the branch ref has not moved — history is untouched until the replay finishes")
    #expect(try repo.revParse("HEAD") != mainBefore, "HEAD is detached on the new pair")
    let detachedTree = try repo.revParse("\(c2)^{tree}")
    #expect(try repo.revParse("HEAD^{tree}") == detachedTree,
            "HEAD sits on the split's second half")

    // Clean up so the fixture destructor is not fighting a live pick.
    _ = try? git.run(
        ["cherry-pick", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Signing preserved

@Test func signedCommitsStaySignedThroughTheSplit() throws {
    let (repo, _, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    // The base commit exists, unsigned; signing turns on for the split —
    // mirroring an existing history that starts being signed.
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })
    let result = try Split.run(
        commit: c2, hunkID: hunk.id, signing: .config,
        at: repo.url.path, extraEnvironment: hermetic)

    // Both halves are signed — commit-tree is plumbing and ignores
    // commit.gpgsign (measured), so the explicit flag is what signed them.
    #expect(try hasSignatureHeader(result.first, in: repo),
            "the first half must be signed")
    #expect(try hasSignatureHeader(result.second, in: repo),
            "the second half must be signed")
}

@Test func noSignIsForwardedToBothHalves() throws {
    let (repo, _, c2) = try twoHunkFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if either half tried to sign, the run would
    // fail — success under .noSign is the proof the intent reached both.
    try installFakeGpg(failingGpgScript, in: repo)

    let hunk = try #require(
        try hunks(of: c2, in: repo).first { $0.body.contains("+T3") })
    let result = try Split.run(
        commit: c2, hunkID: hunk.id, signing: .noSign,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(!(try hasSignatureHeader(result.first, in: repo)), "the first half must be unsigned")
    #expect(!(try hasSignatureHeader(result.second, in: repo)), "the second half must be unsigned")
}

// MARK: - Wire shape

@Test func splitResultEncodesExactlyItsWireKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    let result = Split.Result(
        first: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        second: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["first", "second"],
            "Split.Result encodes exactly its two wire keys; got \(object.keys.sorted())")
    #expect(object["first"] as? String == result.first)
    #expect(object["second"] as? String == result.second)
}
