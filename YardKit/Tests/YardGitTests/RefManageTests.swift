// RefManageTests.swift — tag and branch management (#0363)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `RewriteTests.swift` does. A script is not a key; no keychain, ~/.gnupg, or
// ~/.ssh entry is touched.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try git.run(["config", key, value], workingDirectory: repo.url.path)
}

/// Every ref with its object name and type — the shape the happy paths are
/// asserted through, so a ref's existence, value, and kind are all read the
/// way the engine's consumers read them.
private func refShapes(in repo: FixtureRepository) throws -> [String] {
    try git.run(
        ["for-each-ref", "--format=%(refname) %(objectname) %(objecttype)"],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
}

private func refShape(_ refname: String, in repo: FixtureRepository) throws -> String? {
    try refShapes(in: repo).first { $0.hasPrefix("\(refname) ") }
}

/// Whether a ref exists at all.
private func refExists(_ refname: String, in repo: FixtureRepository) throws -> Bool {
    try refShape(refname, in: repo) != nil
}

/// The object type git reports for a ref's tip — `commit` for a lightweight
/// tag or a branch, `tag` for an annotated tag object.
private func refType(_ refname: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["for-each-ref", "--format=%(objecttype)", refname],
        workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines.first ?? ""
}

private func symbolicHead(in repo: FixtureRepository) throws -> String? {
    let output = try git.capture(
        ["symbolic-ref", "-q", "HEAD"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic)
    return output.exitCode == 0 ? output.lines.first : nil
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

/// `c1 → c2 → c3` on `main`.
private func linearFixture() throws -> (repo: FixtureRepository, c1: String, c2: String, c3: String) {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\n"]),
        .init("c2", files: ["f.txt": "a1\na2\n"]),
        .init("c3", files: ["f.txt": "a1\na2\na3\n"]),
    ])
    return (repo, try #require(repo.oids["c1"]), try #require(repo.oids["c2"]),
            try #require(repo.oids["c3"]))
}

// MARK: - Tag: happy paths

@Test func lightweightTagPointsAtTheCommit() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }

    let result = try Tag.create(
        name: "v1", commit: c2, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.ref == "refs/tags/v1")
    #expect(result.oid == c2, "a lightweight tag points straight at the commit")
    #expect(!result.annotated)
    #expect(try refType("refs/tags/v1", in: repo) == "commit")
    #expect(try refShape("refs/tags/v1", in: repo)
        == "refs/tags/v1 \(c2) commit", "for-each-ref sees the ref at the commit")
}

@Test func annotatedTagCarriesTheMessageFromStdin() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    let message = "release one\n\n- second paragraph\n- with a dash line\n"

    let result = try Tag.create(
        name: "v1", commit: c2, annotated: true, message: message,
        at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.ref == "refs/tags/v1")
    #expect(result.annotated)
    #expect(result.oid != c2, "an annotated tag's ref points at the tag object")
    #expect(try refType("refs/tags/v1", in: repo) == "tag")
    #expect(try refShape("refs/tags/v1", in: repo) == "refs/tags/v1 \(result.oid) tag")
    // The message rode stdin (`-F -`), so a multi-paragraph message with a
    // dash-leading line arrives byte-for-byte.
    let object = try git.run(
        ["cat-file", "tag", "refs/tags/v1"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text
    #expect(object.contains("type commit\n"))
    #expect(object.contains("object \(c2)\n"), "the tag object targets the named commit")
    #expect(object.contains(message.trimmingCharacters(in: .whitespacesAndNewlines)))
}

// MARK: - Tag: signing (pinned with a fake gpg program)

private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

private let succeedingGpgScript = """
#!/bin/sh
cat > /dev/null
printf '[GNUPG:] SIG_CREATED D\\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
exit 0
"""

private let failingGpgScript = """
#!/bin/sh
cat > /dev/null
echo "gpg: signing failed: No secret key" >&2
exit 2
"""

/// The signed-tag object's body — `cat-file -p` on the tag object, which for
/// a signed tag carries the signature block.
private func tagObject(_ ref: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["cat-file", "tag", ref], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text
}

@Test func signedAnnotatedTagCarriesTheSignatureWhenSignIsPassed() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try set("tag.gpgsign", "false", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    let result = try Tag.create(
        name: "signed", commit: "main", annotated: true, message: "m",
        signing: .sign, at: repo.url.path, extraEnvironment: hermetic)

    let object = try tagObject("refs/tags/signed", in: repo)
    #expect(object.contains("-----BEGIN PGP SIGNATURE-----"),
            "the explicit -s must sign the tag object even with tag.gpgsign=false")
    #expect(object.contains("object \(try repo.revParse("main"))\n"))
    #expect(result.annotated)
}

@Test func noSignBeatsATagGpgsignTrueConfig() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try set("tag.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if the tag were signed despite --no-sign,
    // the run would fail — success under .noSign is the proof.
    try installFakeGpg(failingGpgScript, in: repo)

    let result = try Tag.create(
        name: "unsigned", commit: "main", annotated: true, message: "m",
        signing: .noSign, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.annotated)
    let object = try tagObject("refs/tags/unsigned", in: repo)
    #expect(!object.contains("-----BEGIN PGP SIGNATURE-----"),
            "--no-sign must beat tag.gpgsign=true, the same precedence git commit has")
}

@Test func configSigningFollowsTagGpgsignNotCommitGpgsign() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    // commit.gpgsign=true is the commit path's key; only tag.gpgsign may
    // decide a .config tag signature.
    try set("commit.gpgsign", "true", in: repo)
    try set("tag.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    _ = try Tag.create(
        name: "config-signed", commit: "main", annotated: true, message: "m",
        signing: .config, at: repo.url.path, extraEnvironment: hermetic)

    let object = try tagObject("refs/tags/config-signed", in: repo)
    #expect(object.contains("-----BEGIN PGP SIGNATURE-----"),
            "tag.gpgsign=true under .config must sign")
}

@Test func aSigningFailureIsTypedAndCreatesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    let mainTip = try repo.revParse("refs/heads/main")

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Tag.create(
            name: "broken", commit: "main", annotated: true, message: "m",
            signing: .sign, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .signingFailed(reason) = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!reason.isEmpty, "the refusal carries git's own wording")
    #expect(try refShape("refs/tags/broken", in: repo) == nil, "no tag was created")
    #expect(try repo.revParse("refs/heads/main") == mainTip, "no ref moved")
    // The checkpoint the mutation attempt wrote is what undo reverses — the
    // same contract Rewrite's signing failure keeps — so unlike the
    // pre-check refusals above, no journal-anchor-free snapshot is asserted.
}

// MARK: - Tag: refusals that touch nothing

/// Runs one refusal, asserting it throws AND leaves HEAD, the branch, the
/// index bytes, and every ref — journal anchors included — byte-identical.
/// Returns the thrown refusal for the caller's typed assertion.
private func expectRefusal(
    _ label: String, _ repo: FixtureRepository, _ run: () throws -> Void
) throws -> RefManageError {
    let before = try fullSnapshot(repo)
    let thrown = #expect(throws: RefManageError.self, "\(label) must refuse") { try run() }
    #expect(try fullSnapshot(repo) == before,
            "\(label) must touch nothing — not even a journal anchor")
    return try #require(thrown, "\(label) must throw a typed refusal")
}

@Test func tagRefusalsTouchNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    try git.run(["tag", "v1", "main"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)
    try git.run(["tag", "feat/x", "main"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)

    // Creating a tag that exists.
    let thrown1 = try expectRefusal("tag exists", repo) {
        _ = try Tag.create(name: "v1", commit: "main", at: repo.url.path,
                           extraEnvironment: hermetic)
    }
    #expect(thrown1 == .alreadyExists(kind: .tag, name: "v1"))

    // Unknown commit.
    let thrown2 = try expectRefusal("unknown commit", repo) {
        _ = try Tag.create(name: "v2", commit: "no-such-revision", at: repo.url.path,
                           extraEnvironment: hermetic)
    }
    #expect(thrown2 == .unknownRevision("no-such-revision"))

    // Invalid name — a space (check-ref-format refuses it).
    let thrown3 = try expectRefusal("invalid tag name", repo) {
        _ = try Tag.create(name: "a b", commit: "main", at: repo.url.path,
                           extraEnvironment: hermetic)
    }
    guard case let .invalidName(kind, name3) = thrown3 else {
        Issue.record("expected .invalidName, got \(String(describing: thrown3))")
        return
    }
    #expect(kind == .tag)
    #expect(name3 == "a b")

    // A `/`-boundary clash with an existing tag.
    let thrown4 = try expectRefusal("tag name clash", repo) {
        _ = try Tag.create(name: "feat", commit: "main", at: repo.url.path,
                           extraEnvironment: hermetic)
    }
    guard case let .nameClash(requested, existing4) = thrown4 else {
        Issue.record("expected .nameClash, got \(String(describing: thrown4))")
        return
    }
    #expect(requested == "refs/tags/feat")
    #expect(existing4 == "refs/tags/feat/x")

    // Signing intent on a lightweight creation — nothing to sign.
    let thrown5 = try expectRefusal("signing a lightweight tag", repo) {
        _ = try Tag.create(name: "v3", commit: "main", signing: .sign,
                           at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(thrown5 == .signingRequiresAnnotated)

    // Annotated without a message.
    let thrown6 = try expectRefusal("annotated without message", repo) {
        _ = try Tag.create(name: "v4", commit: "main", annotated: true,
                           at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(thrown6 == .messageRequired)
}

// MARK: - Branch: create

@Test func branchCreateMakesTheRefWithoutCheckingItOut() throws {
    let (repo, c1, _, _) = try linearFixture()
    defer { repo.destroy() }

    let result = try Branch.create(name: "feature", start: c1, at: repo.url.path,
                                   extraEnvironment: hermetic)

    #expect(result.ref == "refs/heads/feature")
    #expect(result.oid == c1)
    #expect(try refShape("refs/heads/feature", in: repo)
        == "refs/heads/feature \(c1) commit")
    let headNow = try repo.revParse("HEAD")
    let mainTipNow = try repo.revParse("refs/heads/main")
    #expect(headNow == mainTipNow,
            "creating does not check the branch out")
    #expect(try symbolicHead(in: repo) == "refs/heads/main")
}

@Test func branchCreateDefaultsToHeadAndAcceptsARevision() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }

    let fromHead = try Branch.create(name: "from-head", at: repo.url.path,
                                     extraEnvironment: hermetic)
    let mainTip = try repo.revParse("refs/heads/main")
    #expect(fromHead.oid == mainTip)

    let fromRev = try Branch.create(name: "from-rev", start: "main~1",
                                    at: repo.url.path, extraEnvironment: hermetic)
    let mainParent = try repo.revParse("main~1")
    #expect(fromRev.oid == mainParent)
}

// MARK: - Branch: rename

@Test func renamingTheCheckedOutBranchMovesHeadsSymref() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    let oldTip = try repo.revParse("refs/heads/main")

    let result = try Branch.rename(old: "main", new: "trunk", at: repo.url.path,
                                   extraEnvironment: hermetic)

    #expect(result.ref == "refs/heads/trunk", "the payload names the new ref")
    #expect(result.oid == oldTip, "the rename moves the name, not the tip")
    #expect(result.headFollowed == true, "HEAD's symref follows the renamed checkout")
    #expect(try refShape("refs/heads/main", in: repo) == nil, "the old ref is gone")
    #expect(try refShape("refs/heads/trunk", in: repo) == "refs/heads/trunk \(oldTip) commit")
    #expect(try symbolicHead(in: repo) == "refs/heads/trunk",
            "HEAD still points at the branch, under its new name")
    #expect(try repo.revParse("HEAD") == oldTip)
}

@Test func renamingAnUncheckedOutBranchLeavesHeadAlone() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    _ = try Branch.create(name: "feature", start: "main", at: repo.url.path,
                          extraEnvironment: hermetic)

    let result = try Branch.rename(old: "feature", new: "renamed", at: repo.url.path,
                                   extraEnvironment: hermetic)

    #expect(result.headFollowed == false, "a non-checked-out rename does not touch HEAD")
    #expect(try symbolicHead(in: repo) == "refs/heads/main")
    #expect(try refShape("refs/heads/feature", in: repo) == nil)
    #expect(try refShape("refs/heads/renamed", in: repo) != nil)
}

@Test func renamingOntoAnExistingNameRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    _ = try Branch.create(name: "feature", start: "main", at: repo.url.path,
                          extraEnvironment: hermetic)
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.rename(old: "feature", new: "main", at: repo.url.path,
                              extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .alreadyExists(kind: .branch, name: "main"))
    #expect(try fullSnapshot(repo) == before,
            "the refusal leaves every ref — journal anchors included — byte-identical")
    #expect(try symbolicHead(in: repo) == "refs/heads/main")
}

// MARK: - Branch: delete

@Test func deletingAMergedBranchMovesTheRefOff() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    let created = try Branch.create(name: "feature", start: "main",
                                    at: repo.url.path, extraEnvironment: hermetic)

    let result = try Branch.delete(name: "feature", at: repo.url.path,
                                   extraEnvironment: hermetic)

    #expect(result.ref == "refs/heads/feature")
    #expect(result.oid == created.oid, "the payload names the tip the deleted ref held")
    #expect(try refShape("refs/heads/feature", in: repo) == nil)
    #expect(try symbolicHead(in: repo) == "refs/heads/main", "HEAD is untouched")
}

@Test func deletingTheCheckedOutBranchRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.delete(name: "main", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .deletingCheckedOutBranch(name, worktree) = try #require(thrown) else {
        Issue.record("expected .deletingCheckedOutBranch, got \(String(describing: thrown))")
        return
    }
    #expect(name == "main")
    #expect(worktree == repo.url.path, "the refusal names the holding worktree")
    #expect(try fullSnapshot(repo) == before, "the refusal touched nothing")
}

@Test func deletingABranchALinkedWorktreeHoldsRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    let worktree = try repo.addWorktree(named: "held", branch: "held-branch")
    defer { try? FileManager.default.removeItem(at: worktree) }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.delete(name: "held-branch", at: repo.url.path,
                              extraEnvironment: hermetic)
    }
    guard case let .branchHeldByWorktree(name, worktreePath) = try #require(thrown) else {
        Issue.record("expected .branchHeldByWorktree, got \(String(describing: thrown))")
        return
    }
    #expect(name == "held-branch")
    #expect(worktreePath == worktree.path, "the refusal names the linked worktree")
    #expect(try fullSnapshot(repo) == before)
}

@Test func deletingAnUnmergedBranchWithoutForceRefusesAndWithForceDeletes() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    // A branch whose tip is not reachable from HEAD: its commits would leave
    // every branch on deletion.
    _ = try Branch.create(name: "unmerged", start: "main", at: repo.url.path,
                          extraEnvironment: hermetic)
    try repo.checkout("unmerged")
    try repo.writeUntracked(["w.txt": "only here\n"])
    try git.run(["add", "w.txt"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", "unmerged work"],
                workingDirectory: repo.url.path, extraEnvironment: hermetic)
    let tip = try repo.revParse("refs/heads/unmerged")
    try repo.checkout("main")
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.delete(name: "unmerged", at: repo.url.path,
                              extraEnvironment: hermetic)
    }
    guard case let .unmergedBranch(name, refusedTip) = try #require(thrown) else {
        Issue.record("expected .unmergedBranch, got \(String(describing: thrown))")
        return
    }
    #expect(name == "unmerged")
    #expect(refusedTip == tip)
    #expect(try fullSnapshot(repo) == before, "the refusal touched nothing")

    let forced = try Branch.delete(name: "unmerged", force: true, at: repo.url.path,
                                   extraEnvironment: hermetic)
    #expect(forced.oid == tip)
    #expect(try refShape("refs/heads/unmerged", in: repo) == nil, "the ref is gone")
}

@Test func deletingAnUnknownBranchRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.delete(name: "no-such-branch", at: repo.url.path,
                              extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .unknownBranch("no-such-branch"))
    #expect(try fullSnapshot(repo) == before)
}

// MARK: - Branch: undo restores a deleted branch (verify, don't assume)

@Test func undoRestoresADeletedBranch() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    let mainTip = try repo.revParse("refs/heads/main")
    _ = try Branch.create(name: "feature", start: "main", at: repo.url.path,
                          extraEnvironment: hermetic)

    // The deletion itself must actually remove the ref — otherwise the
    // restore below would prove nothing.
    _ = try Branch.delete(name: "feature", at: repo.url.path, extraEnvironment: hermetic)
    #expect(try refShape("refs/heads/feature", in: repo) == nil,
            "precondition: the delete really removed the ref")
    #expect(try refShape("refs/heads/main", in: repo) != nil)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    let restored = try refShape("refs/heads/feature", in: repo)
    #expect(restored == "refs/heads/feature \(mainTip) commit",
            "undo must re-create the deleted ref at the value the checkpoint held")
    #expect(try symbolicHead(in: repo) == "refs/heads/main", "HEAD is untouched")
    #expect(try repo.revParse("refs/heads/main") == mainTip)
}

@Test func undoAfterATagCreationLeavesTheCreatedRefInPlace() throws {
    let (repo, _, c2, _) = try linearFixture()
    defer { repo.destroy() }
    let mainTip = try repo.revParse("refs/heads/main")

    let created = try Tag.create(name: "v1", commit: c2, at: repo.url.path,
                                 extraEnvironment: hermetic)
    #expect(!created.annotated)

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    // Verified, not assumed: undo does NOT delete a ref its snapshot did
    // not record (guide §11 decision 20 — a ref created since capture is
    // never touched). The pre-op snapshot restores HEAD and main; the tag
    // the creation added stays. The delete-restore case above is where undo
    // re-creates, because the deleted ref WAS recorded.
    #expect(try refShape("refs/tags/v1", in: repo) == "refs/tags/v1 \(created.oid) commit")
    #expect(try repo.revParse("refs/heads/main") == mainTip)
}

// MARK: - Branch: refusals on create

@Test func branchCreateRefusalsTouchNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.checkout("main")
    try git.run(["branch", "feat/x", "main"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)
    try git.run(["branch", "deep", "main"], workingDirectory: repo.url.path,
                extraEnvironment: hermetic)

    // An existing name.
    let thrown1 = try expectRefusal("branch exists", repo) {
        _ = try Branch.create(name: "main", at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(thrown1 == .alreadyExists(kind: .branch, name: "main"))

    // A `/`-boundary clash, short name against a deeper ref.
    let thrown2 = try expectRefusal("branch clash short name", repo) {
        _ = try Branch.create(name: "feat", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .nameClash(requested2, existing2) = thrown2 else {
        Issue.record("expected .nameClash, got \(String(describing: thrown2))")
        return
    }
    #expect(requested2 == "refs/heads/feat")
    #expect(existing2 == "refs/heads/feat/x")

    // The reverse clash, deeper name against an existing prefix.
    let thrown3 = try expectRefusal("branch clash deep name", repo) {
        _ = try Branch.create(name: "deep/sub", at: repo.url.path,
                              extraEnvironment: hermetic)
    }
    guard case let .nameClash(requested3, existing3) = thrown3 else {
        Issue.record("expected .nameClash, got \(String(describing: thrown3))")
        return
    }
    #expect(requested3 == "refs/heads/deep/sub")
    #expect(existing3 == "refs/heads/deep")

    // An invalid name.
    let thrown4 = try expectRefusal("invalid branch name", repo) {
        _ = try Branch.create(name: "a b", at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .invalidName(kind4, name4) = thrown4 else {
        Issue.record("expected .invalidName, got \(String(describing: thrown4))")
        return
    }
    #expect(kind4 == .branch)
    #expect(name4 == "a b")

    // An unknown start revision.
    let thrown5 = try expectRefusal("unknown start revision", repo) {
        _ = try Branch.create(name: "ok-name", start: "no-such-revision",
                              at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(thrown5 == .unknownRevision("no-such-revision"))
}

@Test func renamingAnUnknownBranchRefusesAndTouchesNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    let before = try fullSnapshot(repo)

    let thrown = #expect(throws: RefManageError.self) {
        _ = try Branch.rename(old: "no-such-branch", new: "anything",
                              at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .unknownBranch("no-such-branch"))
    #expect(try fullSnapshot(repo) == before)
}

// MARK: - Branch: upstream

@Test func setUpstreamTracksARemoteRefUnderItsFullName() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    try repo.addUpstream(branch: "main")
    _ = try Branch.create(name: "topic", at: repo.url.path, extraEnvironment: hermetic)

    let result = try Branch.setUpstream(name: "topic", upstream: "origin/main",
                                        at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.upstream == "refs/remotes/origin/main",
            "the payload names the upstream's full ref")
    #expect(try refShape("refs/remotes/origin/main", in: repo) != nil)
    #expect(try git.run(
        ["config", "--get", "branch.topic.merge"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/main")
    #expect(try git.run(
        ["config", "--get", "branch.topic.remote"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text.trimmingCharacters(in: .whitespacesAndNewlines) == "origin")
}

@Test func setUpstreamTracksALocalBranchByName() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    _ = try Branch.create(name: "topic", at: repo.url.path, extraEnvironment: hermetic)

    let result = try Branch.setUpstream(name: "topic", upstream: "main",
                                        at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.upstream == "refs/heads/main")
    #expect(try git.run(
        ["config", "--get", "branch.topic.merge"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).text.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/main")
}

@Test func setUpstreamRefusalsTouchNothing() throws {
    let (repo, _, _, _) = try linearFixture()
    defer { repo.destroy() }
    _ = try Branch.create(name: "topic", at: repo.url.path, extraEnvironment: hermetic)
    let before = try fullSnapshot(repo)

    let thrown1 = #expect(throws: RefManageError.self) {
        _ = try Branch.setUpstream(name: "no-such-branch", upstream: "origin/main",
                                   at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown1) == .unknownBranch("no-such-branch"))

    let thrown2 = #expect(throws: RefManageError.self) {
        _ = try Branch.setUpstream(name: "topic", upstream: "origin/nope",
                                   at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown2) == .unknownUpstream("origin/nope"))

    #expect(try fullSnapshot(repo) == before,
            "the refusals leave every ref — journal anchors included — byte-identical")
}

// MARK: - Wire shape

@Test func refManageResultsEncodeExactlyTheirWireKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)

    let tag = Tag.Result(ref: "refs/tags/v1", oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                         annotated: true)
    let tagObject = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(tag)) as? [String: Any])
    #expect(Set(tagObject.keys) == ["ref", "oid", "annotated"],
            "Tag.Result encodes exactly its wire keys; got \(tagObject.keys.sorted())")
    #expect(tagObject["ref"] as? String == "refs/tags/v1")
    #expect(tagObject["annotated"] as? Bool == true)

    let branch = Branch.Result(ref: "refs/heads/feature",
                               oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                               upstream: "refs/remotes/origin/main", headFollowed: true)
    let branchObject = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(branch)) as? [String: Any])
    #expect(Set(branchObject.keys) == ["ref", "oid", "upstream", "headFollowed"],
            "Branch.Result encodes exactly its wire keys; got \(branchObject.keys.sorted())")
    #expect(branchObject["upstream"] as? String == "refs/remotes/origin/main")
    #expect(branchObject["headFollowed"] as? Bool == true)

    let plain = Branch.Result(ref: "refs/heads/feature",
                              oid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let plainObject = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any])
    #expect(Set(plainObject.keys) == ["ref", "oid"],
            "absent-when-nil fields are absent, never null")
}
