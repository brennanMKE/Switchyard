// AbsorbTests.swift — distributing staged hunks into the commits that last
// touched their lines (#0061)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `CommitCreateGPGTests.swift` and `FixupTests.swift` do. A script is not a
// key; no keychain, ~/.gnupg, or ~/.ssh entry is touched.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private let git = GitProcess()

private func set(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try git.run(["config", key, value], workingDirectory: repo.url.path)
}

private func stage(_ files: [String: String], in repo: FixtureRepository) throws {
    try repo.writeUntracked(files)
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
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

private func stagedFile(_ path: String, in repo: FixtureRepository) throws -> String {
    try git.run(
        ["show", ":\(path)"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text
}

private func stagedPaths(in repo: FixtureRepository) throws -> [String] {
    try git.run(
        ["diff", "--cached", "--name-only"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines
}

private func rebaseInProgress(in repo: FixtureRepository) -> Bool {
    guard let out = try? git.run(
        ["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"],
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
/// `FixupTests.swift` (that file's helpers are private to it).
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

/// `c1 → c2 → c3` on `main`, all editing `f.txt`: twelve lines at c1, line 4
/// becomes `L4` at c2, line 12 becomes `L12` at c3. The two commits touch
/// lines far enough apart (7+) that a staged change on either line blames to
/// exactly one of them with `--unified=3` context.
private func twelveLineFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"]),
    ])
    return repo
}

// MARK: - Happy path: one hunk, one target

@Test func singleStagedHunkLandsInTheCommitThatLastTouchedItsLines() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")
    let target = try #require(repo.oids["c2"])

    // The staged change sits on line 4 — the line c2 wrote last. Line 12
    // (c3's change) is left alone in the staged content.
    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"], in: repo)

    let result = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)

    let outcome = try #require(result.plan.hunks.first, "the staged diff has exactly one hunk")
    #expect(result.plan.hunks.count == 1)
    #expect(outcome.hunkID.isEmpty == false)
    #expect(outcome.leftStaged == false)
    #expect(outcome.target == target, "line 4 was last touched by c2")
    #expect(outcome.reason == nil)

    #expect(result.head == (try repo.revParse("HEAD")))
    #expect(try repo.revParse("HEAD") != before, "the rewrite must move HEAD")

    let count = try git.run(
        ["rev-list", "--count", "HEAD"], workingDirectory: repo.url.path,
        extraEnvironment: hermetic
    ).lines[0]
    #expect(count == "3", "three commits after the rewrite — no fixup commit survives")
    let subjectList = try subjects(in: repo)
    #expect(!subjectList.isEmpty)
    #expect(!subjectList.contains { $0.hasPrefix("fixup!") })

    // The hunk's change is in c2's rewritten tree, and nothing else moved:
    // c2' still carries c2's own state at line 12 (l12, lowercase), and the
    // descendant c3' carries both the absorbed line and its own L12.
    #expect(try fileAt("HEAD~1", path: "f.txt", in: repo)
        == "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n")
    #expect(try fileAt("HEAD", path: "f.txt", in: repo)
        == "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n")
    #expect(try fileAt("HEAD~2", path: "f.txt", in: repo)
        == "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n",
        "the root commit's tree is untouched")
    #expect(try stagedPaths(in: repo).isEmpty, "the absorbed hunk leaves the index clean")
}

// MARK: - Happy path: two hunks, two targets, one pass

@Test func twoHunksToTwoDifferentCommitsInOnePass() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }
    let c2 = try #require(repo.oids["c2"])
    let c3 = try #require(repo.oids["c3"])

    // Both changes staged in one pass: line 4 blames c2, line 12 blames c3,
    // and they are far enough apart to stay two separate hunks.
    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nM12\n"], in: repo)

    let result = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.plan.hunks.count == 2)
    #expect(result.plan.unconfident.isEmpty)
    #expect(Set(result.plan.confident.compactMap(\.target)) == Set([c2, c3]))
    #expect(result.head == (try repo.revParse("HEAD")))

    let log = try git.run(
        ["log", "--oneline"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
    #expect(log.count == 3, "three commits — two fixups folded, none left standing")
    let subjectList = try subjects(in: repo)
    #expect(!subjectList.isEmpty)
    #expect(!subjectList.contains { $0.hasPrefix("fixup!") })

    // Each change lands in its own commit's tree, descendants intact.
    #expect(try fileAt("HEAD~1", path: "f.txt", in: repo)
        == "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n")
    #expect(try fileAt("HEAD", path: "f.txt", in: repo)
        == "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nM12\n")
    #expect(try stagedPaths(in: repo).isEmpty)
}

// MARK: - No confident target: stays staged and reported

@Test func unconfidentHunkStaysStagedAndIsReported() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nl8\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nL8\n"]),
    ])
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    // Lines 4 and 8 are only 4 apart, so both staged changes merge into ONE
    // hunk — whose touched lines blame two different commits (c2 wrote line
    // 4, c3 wrote line 8). No confident target exists.
    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nM8\n"], in: repo)

    let result = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)

    let outcome = try #require(result.plan.hunks.first)
    #expect(result.plan.hunks.count == 1)
    #expect(result.plan.confident.isEmpty)
    #expect(outcome.leftStaged == true, "the hunk must be reported as left staged")
    #expect(outcome.target == nil)
    #expect(outcome.reason != nil && !outcome.reason!.isEmpty,
            "the reason must be reported beside the left-staged hunk")

    #expect(result.head == nil, "nothing was rewritten, so there is no new HEAD")
    #expect(try repo.revParse("HEAD") == before, "HEAD must be untouched")
    #expect(!rebaseInProgress(in: repo))

    // Stays staged AND the staged content is intact.
    #expect(try stagedPaths(in: repo) == ["f.txt"])
    #expect(try stagedFile("f.txt", in: repo)
        == "l1\nl2\nl3\nM4\nl5\nl6\nl7\nM8\n")
}

// MARK: - Nothing staged

@Test func nothingStagedRefusesWithoutTouchingAnything() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let thrown = #expect(throws: AbsorbError.self) {
        _ = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .nothingStaged)
    #expect(try repo.revParse("HEAD") == before)
}

// MARK: - --dry-run: pure planning

/// A snapshot of everything a run could touch: HEAD, its tree, the branch
/// tip, the index file's own bytes, and every ref (journal anchors included,
/// since a checkpoint would write one — a dry run must not).
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
    lines.append("\(indexBytes.count):\(indexBytes.sha1Hash())")
    return lines.joined(separator: "\n")
}

private extension Data {
    func sha1Hash() -> String {
        // SHA-1 over the bytes, via git's own plumbing — no CryptoKit import
        // needed for a test-only fingerprint.
        String(try! git.run(
            ["hash-object", "--stdin"], workingDirectory: "",
            standardInput: self).lines.first ?? "")
    }
}

@Test func dryRunLeavesTreeIndexAndRefsByteIdentical() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }

    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"], in: repo)
    let before = try fullSnapshot(repo)

    let result = try Absorb.run(dryRun: true, at: repo.url.path, extraEnvironment: hermetic)

    let outcome = try #require(result.plan.hunks.first)
    #expect(outcome.leftStaged == false)
    #expect(outcome.target == (try #require(repo.oids["c2"])))
    #expect(result.plan.unconfident.isEmpty)
    #expect(result.head == nil, "a dry run never reports a rewritten HEAD")

    let after = try fullSnapshot(repo)
    #expect(after == before,
            "a dry run must leave HEAD, the branch, the index bytes, and every ref byte-identical")
    #expect(try stagedPaths(in: repo) == ["f.txt"], "the hunk is still staged")
}

// MARK: - Undo

@Test func undoRestoresThePreAbsorbStateExactly() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"]),
        .init("c2", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nl8\n"]),
        .init("c3", files: ["f.txt": "l1\nl2\nl3\nL4\nl5\nl6\nl7\nL8\n"]),
    ])
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")
    let stagedVersion = "l1\nl2\nl3\nM4\nl5\nl6\nl7\nL8\n"

    try stage(["f.txt": stagedVersion], in: repo)

    let result = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)
    #expect(result.head != nil)
    #expect(try repo.revParse("HEAD") != before, "the absorb must actually rewrite")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    _ = try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
    // The staged hunk comes back staged, with its exact pre-absorb content —
    // the checkpoint captured the index before the reset undid it.
    #expect(try stagedPaths(in: repo) == ["f.txt"])
    #expect(try stagedFile("f.txt", in: repo) == stagedVersion)
}

// MARK: - Conflicting replay: resumable rebase

@Test func conflictingReplayLeavesTheRebaseResumable() throws {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\na2\na3\na4\na5\na6\na7\na8\n"]),
        // c2 wrote line 4 (T1) — the hunk's target.
        .init("c2", files: ["f.txt": "a1\na2\na3\nT1\na5\na6\na7\na8\n"]),
        // c3 rewrote line 5 — ADJACENT to the hunk's line 4, so replaying
        // the fixup squash against c3's own change cannot merge (measured:
        // git conflicts on adjacent changed lines; three lines away it does
        // not).
        .init("c3", files: ["f.txt": "a1\na2\na3\nT1\nX5\na6\na7\na8\n"]),
    ])
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    try stage(["f.txt": "a1\na2\na3\nT2\nX5\na6\na7\na8\n"], in: repo)

    let thrown = #expect(throws: AbsorbError.self) {
        _ = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(files.count == 1)
    #expect(try #require(files.first).path == "f.txt")
    #expect(rebaseInProgress(in: repo), "the rebase must be left resumable, not aborted")
    #expect(try repo.revParse("HEAD") != before, "the fixup commit landed before the replay conflicted")

    // Clean up so the fixture destructor is not fighting a live rebase.
    _ = try? git.run(["rebase", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Nothing staged / unmerged index

@Test func unmergedIndexIsRefusedBeforeAnythingIsTouched() throws {
    let repo = try FixtureRepository.conflicted()
    defer { repo.destroy() }
    let before = try repo.revParse("HEAD")

    let thrown = #expect(throws: AbsorbError.self) {
        _ = try Absorb.run(at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case let .blockedOnConflicts(files) = try #require(thrown) else {
        Issue.record("expected .blockedOnConflicts, got \(String(describing: thrown))")
        return
    }
    #expect(!files.isEmpty, "the refusal names the unmerged paths")
    #expect(try repo.revParse("HEAD") == before, "nothing was committed")
    #expect(!rebaseInProgress(in: repo), "the refusal precedes any rebase")
}

// MARK: - Signing preserved

@Test func signedCommitsStaySignedThroughTheAbsorbRewrite() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }
    // Base commits first, unsigned (the fixture's default), then turn signing
    // on — mirroring an already-existing history that starts being signed.
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)

    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"], in: repo)

    let result = try Absorb.run(
        signing: .config, at: repo.url.path, extraEnvironment: hermetic)
    #expect(result.head != nil)

    let log = try git.run(
        ["log", "--format=%H"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
    #expect(log.count == 3)
    // Only the commits the rebase rewrote are re-signed — HEAD (c3 replayed)
    // and HEAD~1 (c2, replayed with the fixup squashed in). The rebase's
    // base, c1, was built before signing was turned on and stays as it was.
    #expect(try hasSignatureHeader(try #require(log.first), in: repo))
    #expect(try hasSignatureHeader(log[1], in: repo))
    #expect(!(try hasSignatureHeader(log[2], in: repo)), "c1 was never rewritten by the rebase")
}

@Test func noSignIsForwardedToEveryCommitAndTheRebase() throws {
    let repo = try twelveLineFixture()
    defer { repo.destroy() }
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // A gpg that always fails: if any rewritten commit tried to sign, the run
    // would fail — success under --no-gpg-sign is the proof the flag reached
    // the fixup commits and the rebase.
    try installFakeGpg(failingGpgScript, in: repo)
    let before = try repo.revParse("HEAD")

    try stage(["f.txt": "l1\nl2\nl3\nM4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nL12\n"], in: repo)

    let result = try Absorb.run(
        signing: .noSign, at: repo.url.path, extraEnvironment: hermetic)
    #expect(result.head != nil)
    #expect(try repo.revParse("HEAD") != before)

    let log = try git.run(
        ["log", "--format=%H"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
    #expect(log.count == 3)
    for oid in log {
        #expect(!(try hasSignatureHeader(oid, in: repo)), "\(oid) must be unsigned")
    }
}

// MARK: - Wire shape

@Test func hunkOutcomeEncodesExactlyItsWireKeys() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)

    let confident = AbsorbHunkOutcome(
        hunkID: "0123456789ab", path: "f.txt", leftStaged: false,
        target: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", reason: nil)
    let confidentKeys = Set(try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(confident)) as? [String: Any]
    ).keys)
    #expect(confidentKeys == ["hunkID", "path", "leftStaged", "target"],
            "a confident outcome encodes exactly its four present keys; got \(confidentKeys.sorted())")

    let unconfident = AbsorbHunkOutcome(
        hunkID: "0123456789ab", path: "f.txt", leftStaged: true,
        target: nil, reason: "lines last touched by several commits")
    let unconfidentKeys = try #require(
        try JSONSerialization.jsonObject(with: encoder.encode(unconfident)) as? [String: Any]
    ) as [String: Any]
    #expect(Set(unconfidentKeys.keys) == ["hunkID", "path", "leftStaged", "reason"],
            "a left-staged outcome encodes no target key — presence is the confidence signal")
    #expect(unconfidentKeys["leftStaged"] as? Bool == true)
    #expect((unconfidentKeys["reason"] as? String)?.isEmpty == false)
}
