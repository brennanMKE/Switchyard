// SquashTests.swift — folding HEAD into its parent, both messages kept (#0374)
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

private func fullMessage(_ revision: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["log", "-n", "1", "--format=%B", revision], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text
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

private func stagedFileBytes(_ path: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["show", ":\(path)"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

/// The message bytes as stored in the commit object — `git cat-file commit`
/// minus its header block. `git log --format=%B` appends its own entry
/// terminator newline, so it is the wrong instrument for a byte-exact
/// message assertion (measured, git 2.50.1).
private func storedMessage(_ revision: String, in repo: FixtureRepository) throws -> String {
    let object = try git.run(
        ["cat-file", "commit", revision], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text
    guard let separator = object.range(of: "\n\n") else { return "" }
    return String(object[separator.upperBound...])
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

/// `root → parent msg → head msg` on `main`: the measured three-commit shape
/// the issue folds. `head msg` rewrites f.txt's first line over the parent's
/// change; the parent added g.txt; the root wrote f.txt.
private func squashFixture() throws -> (repo: FixtureRepository, root: String, parent: String, head: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("root", files: ["f.txt": "a1\na2\na3\n"]),
        .init("parent msg", files: ["f.txt": "a1\na2\na3\n", "g.txt": "g1\ng2\n"]),
        .init("head msg", files: ["f.txt": "A1\na2\na3\n", "g.txt": "g1\ng2\n"]),
    ])
    return (repo, try #require(repo.oids["root"]), try #require(repo.oids["parent msg"]),
            try #require(repo.oids["head msg"]))
}

/// `root → head msg` on `main` — the shape whose parent is the root commit.
private func twoCommitFixture() throws -> (repo: FixtureRepository, root: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("root", files: ["f.txt": "a1\na2\n"]),
        .init("head msg", files: ["f.txt": "A1\na2\n"]),
    ])
    return (repo, try #require(repo.oids["root"]))
}

/// A single-commit repository — `HEAD` is the root commit itself.
private func rootHeadFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([.init("root", files: ["f.txt": "r\n"])])
    return repo
}

/// `c1 → c2 → m` on `main`, where `m` merges a side commit `s` off c1 —
/// `HEAD` itself is a merge.
private func mergeTipFixture() throws -> (repo: FixtureRepository, m: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "b1\nb2\nb3\n"]),
        .init("c2", files: ["f.txt": "b1\nb2\nb3\n", "g.txt": "g\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "b1\nB2\nb3\n"]),
        .init("m", parents: ["c2", "side"], files: [
            "f.txt": "b1\nB2\nb3\n", "g.txt": "g\n",
        ]),
    ])
    try repo.branch("main", at: "m")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["m"]))
}

/// `c1 → c2 → m → head msg` on `main` — `HEAD` is a normal commit whose
/// parent is a merge.
private func mergeParentFixture() throws -> (repo: FixtureRepository, m: String, head: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "b1\nb2\nb3\n"]),
        .init("c2", files: ["f.txt": "b1\nb2\nb3\n", "g.txt": "g\n"]),
        .init("side", parents: ["c1"], files: ["f.txt": "b1\nB2\nb3\n"]),
        .init("m", parents: ["c2", "side"], files: [
            "f.txt": "b1\nB2\nb3\n", "g.txt": "g\n",
        ]),
        .init("head msg", parents: ["m"], files: [
            "f.txt": "b1\nB2\nb3\n", "g.txt": "g\n", "h.txt": "h\n",
        ]),
    ])
    try repo.branch("main", at: "head msg")
    try repo.checkout("main")
    return (repo, try #require(repo.oids["m"]), try #require(repo.oids["head msg"]))
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

// MARK: - combinedMessage

@Test func combinedMessageJoinsTheTwoMessagesWithOneBlankLine() {
    // The exact bytes the issue's measured mechanism feeds commit-tree:
    // `printf 'parent msg\n\nhead msg\n'`.
    #expect(Squash.combinedMessage(parent: "parent msg\n", child: "head msg\n")
            == "parent msg\n\nhead msg\n")
    #expect(Squash.combinedMessage(parent: "parent msg", child: "head msg")
            == "parent msg\n\nhead msg\n",
            "missing trailing newlines are normalized, not doubled")
    #expect(Squash.combinedMessage(parent: "parent msg\n\n\n", child: "head msg\n\n")
            == "parent msg\n\nhead msg\n",
            "every trailing newline collapses to the single blank line")
    #expect(Squash.combinedMessage(parent: "", child: "head msg\n") == "head msg\n",
            "an empty side contributes nothing — no dangling blank line")
    #expect(Squash.combinedMessage(parent: "parent msg\n", child: "") == "parent msg\n")
    #expect(Squash.combinedMessage(parent: "\n", child: "\n\n") == "",
            "two empty messages combine to nothing")
}

// MARK: - The fold

@Test func squashFoldsHeadIntoItsParentAsOneCommitCarryingHeadsTree() throws {
    let (repo, root, parent, head) = try squashFixture()
    defer { repo.destroy() }

    let result = try Squash.run(
        message: "parent msg\n\nhead msg\n", at: repo.url.path, extraEnvironment: hermetic)

    let count = try git.run(
        ["rev-list", "--count", "main"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines[0]
    #expect(count == "2", "two commits become one: the root and the folded commit")
    #expect(try repo.revParse("\(result.head)~1") == root, "the folded commit's parent is the root")
    let headTree = try repo.revParse("\(head)^{tree}")
    #expect(try repo.revParse("\(result.head)^{tree}") == headTree,
            "the new tip carries HEAD's tree byte-identically")
    #expect(try fileAt("main", path: "f.txt", in: repo) == "A1\na2\na3\n",
            "HEAD's change survives the fold — the tree does not change")
    #expect(try fileAt("main", path: "g.txt", in: repo) == "g1\ng2\n",
            "the parent's change survives the fold")
    #expect(try repo.revParse("refs/heads/main") == result.head)
    #expect(try repo.revParse("HEAD") == result.head, "an attached HEAD follows the branch")
    #expect(result.head != head, "a new commit object was written")
    _ = parent
}

@Test func twoCommitsBecomeOneCarryingTheCombinedMessage() throws {
    let (repo, root, parent, head) = try squashFixture()
    defer { repo.destroy() }

    let combined = Squash.combinedMessage(
        parent: try fullMessage(parent, in: repo), child: try fullMessage(head, in: repo))
    #expect(combined == "parent msg\n\nhead msg\n",
            "the prefill built from the two real messages is the measured shape")

    let result = try Squash.run(
        message: combined, at: repo.url.path, extraEnvironment: hermetic)

    #expect(try storedMessage(result.head, in: repo) == "parent msg\n\nhead msg\n",
            "the folded commit's message is the combined message, byte for byte in the commit object")
    let list = try subjects(in: repo)
    #expect(list.count == 2, "the branch now holds exactly the root and the fold")
    #expect(try #require(list.first) == "parent msg",
            "the combined message's subject is the parent's subject line")
    #expect(try #require(list.last) == "root")
    #expect(try repo.revParse("\(result.head)~1") == root)
    #expect(try repo.revParse("refs/heads/main") == result.head)
}

// MARK: - Refusals that touch nothing

@Test func aRootHeadRefusesAndTouchesNothing() throws {
    let repo = try rootHeadFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "combined", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .headIsRoot,
            "a single-commit repository has no parent to fold into")
    #expect(try fullSnapshot(repo) == before,
            "the refusal leaves HEAD, the branch, the index bytes, and every ref byte-identical")
}

@Test func aRootParentRefusesAndTouchesNothing() throws {
    let (repo, root) = try twoCommitFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "combined", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .parentIsRoot,
            "folding into the root commit would create a new root — the same refusal dropping the chain's root gets")
    #expect(try fullSnapshot(repo) == before, "the refusal touched nothing")
    _ = root
}

@Test func aMergeOnEitherSideRefusesAndTouchesNothing() throws {
    let (tipRepo, m) = try mergeTipFixture()
    defer { tipRepo.destroy() }
    let beforeTip = try fullSnapshot(tipRepo)
    let tipThrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "combined", at: tipRepo.url.path, extraEnvironment: hermetic)
    }
    guard case let .mergeRefused(tipCommit) = try #require(tipThrown) else {
        Issue.record("expected .mergeRefused at the tip, got \(String(describing: tipThrown))")
        return
    }
    #expect(tipCommit == m, "the refusal names HEAD itself, the merge commit")
    #expect(try fullSnapshot(tipRepo) == beforeTip, "the refusal touched nothing")

    let (parentRepo, parentMerge, head) = try mergeParentFixture()
    defer { parentRepo.destroy() }
    let beforeParent = try fullSnapshot(parentRepo)
    let parentThrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "combined", at: parentRepo.url.path, extraEnvironment: hermetic)
    }
    guard case let .mergeRefused(parentCommit) = try #require(parentThrown) else {
        Issue.record("expected .mergeRefused at the parent, got \(String(describing: parentThrown))")
        return
    }
    #expect(parentCommit == parentMerge, "the refusal names HEAD's parent, the merge commit")
    #expect(head != parentMerge, "the fixture really is a normal commit on a merge")
    #expect(try fullSnapshot(parentRepo) == beforeParent, "the refusal touched nothing")
}

@Test func anEmptyMessageRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try squashFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let emptyThrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(emptyThrown) == .emptyMessage)
    let blankThrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "  \n\t\n", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(blankThrown) == .emptyMessage, "empty after trimming whitespace too")
    #expect(try fullSnapshot(repo) == before, "the refusals touched nothing")
}

@Test func anUnmergedIndexRefusesBeforeAnythingIsTouched() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let thrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "combined", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(!files.isEmpty, "the refusal names the unmerged paths")
    #expect(try repo.revParse("HEAD") == before, "nothing was created or moved")
}

// MARK: - Detached HEAD

@Test func squashMovesDetachedHeadAndLeavesTheBranchAlone() throws {
    let (repo, root, _, head) = try squashFixture()
    defer { repo.destroy() }
    try git.run(["checkout", "--detach"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)

    let result = try Squash.run(message: "parent msg\n\nhead msg\n", at: repo.url.path,
                                extraEnvironment: hermetic)

    #expect(try repo.revParse("HEAD") == result.head, "a detached HEAD moves itself")
    #expect(try repo.revParse("refs/heads/main") == head,
            "the branch ref is untouched while detached")
    #expect(try repo.revParse("\(result.head)~1") == root)
}

// MARK: - Undo

@Test func undoRestoresThePreSquashStateExactly() throws {
    let (repo, _, _, _) = try squashFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("refs/heads/main")
    let stagedVersion = "s1\ns2\nstaged\n"
    // Unrelated staged work rides through the fold: the tree does not change,
    // so the caller's index is never consumed by the machinery.
    try repo.writeUntracked(["s.txt": stagedVersion])
    try git.run(["add", "s.txt"], workingDirectory: repo.url.path)

    let result = try Squash.run(message: "parent msg\n\nhead msg\n", at: repo.url.path,
                                extraEnvironment: hermetic)

    #expect(try repo.revParse("refs/heads/main") != before, "the squash must actually move the branch")
    #expect(try stagedPaths(in: repo) == ["s.txt"],
            "the caller's staged work survives the fold")
    #expect(try stagedFileBytes("s.txt", in: repo) == stagedVersion)
    #expect(try repo.revParse("refs/heads/main") == result.head)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    #expect(try #require(subjects(in: repo).first) == "head msg",
            "the original two commits are back")
    #expect(try stagedPaths(in: repo) == ["s.txt"],
            "the staged file comes back staged, from the checkpoint's index capture")
    #expect(try stagedFileBytes("s.txt", in: repo) == stagedVersion)
}

// MARK: - Signing

@Test func squashSignsWhenConfigAsksForIt() throws {
    let (repo, _, _, _) = try squashFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Squash.run(message: "parent msg\n\nhead msg\n", signing: .config,
                                at: repo.url.path, extraEnvironment: hermetic)

    #expect(try hasSignatureHeader(result.head, in: repo),
            "commit-tree ignores commit.gpgsign (measured), so the explicit --gpg-sign resolved from config is what signed the fold")
}

@Test func noSignProducesAnUnsignedSquashEvenUnderGpgsignTrue() throws {
    let (repo, _, _, _) = try squashFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if the fold tried to sign, the run would fail —
    // success under .noSign is the proof --no-gpg-sign reached commit-tree.
    try installFakeGpg(failingGpgScript, in: repo)

    let result = try Squash.run(message: "parent msg\n\nhead msg\n", signing: .noSign,
                                at: repo.url.path, extraEnvironment: hermetic)

    #expect(!(try hasSignatureHeader(result.head, in: repo)),
            "the folded commit must be unsigned")
}

@Test func aSquashSigningFailureIsTypedAndTouchesNothing() throws {
    let (repo, _, _, _) = try squashFixture()
    defer { repo.destroy() }
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    let before = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: SquashError.self) {
        _ = try Squash.run(message: "parent msg\n\nhead msg\n", signing: .sign,
                           at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .signingFailed(reason) = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!reason.isEmpty, "the refusal carries git's own wording")
    #expect(try repo.revParse("refs/heads/main") == before,
            "no commit was written and the ref never moved")
}