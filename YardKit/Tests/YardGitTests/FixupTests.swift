// FixupTests.swift — the staged-index fixup (#0039)
//
// NO SIGNING KEY IS CREATED OR USED ANYWHERE IN THIS FILE. `gpg` is not even
// required to be installed: the signing tests pin `gpg.program` to a fake
// shell script that imitates gpg's measured wire behavior, exactly as
// `CommitCreateGPGTests.swift` does. A script is not a key; no keychain,
// ~/.gnupg, or ~/.ssh entry is touched.

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

/// `$(git rev-parse --git-path rebase-merge)` exists — the measured signal a
/// rebase is left in progress and resumable.
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
/// perfectly present signature when `gpg.ssh.allowedSignersFile` is unset, so
/// it answers a different question than the criterion asks.
private func hasSignatureHeader(_ oid: String, in repo: FixtureRepository) throws -> Bool {
    try git.run(
        ["cat-file", "commit", oid], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).text.contains("gpgsig")
}

/// Writes `script` into the fixture worktree, marks it executable, and points
/// `gpg.program` at it. Duplicated from `CommitCreateGPGTests.swift` (that
/// file's helpers are `private` to it) rather than made public there.
private func installFakeGpg(_ script: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked(["fake-gpg.sh": script])
    let path = repo.url.appendingPathComponent("fake-gpg.sh").path
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: path)
    try set("gpg.program", path, in: repo)
}

/// Fails the way a real gpg with no usable secret key does (measured shape:
/// git wraps this in `error: gpg failed to sign the data:`).
private let failingGpgScript = """
#!/bin/sh
cat > /dev/null
echo "gpg: signing failed: No secret key" >&2
exit 2
"""

/// Reports success the way git requires: `[GNUPG:] SIG_CREATED ` on the
/// status fd (git passes `--status-fd=2`) and ASCII armor on stdout. Git
/// accepts this and embeds the armor as the commit's `gpgsig` header.
private let succeedingGpgScript = """
#!/bin/sh
cat > /dev/null
printf '[GNUPG:] SIG_CREATED D\\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
exit 0
"""

/// Succeeds for its first `succeedingCalls` invocations, then fails the way
/// `failingGpgScript` does for every call after — counted by appending one
/// byte per invocation to `gpg-call-count.txt` in the repository (its cwd is
/// the repository root, since that is where git invokes `gpg.program`).
///
/// Measured (git 2.50.1, a three-commit fixture, `commit.gpgsign=true`, no
/// explicit sign flag): `git commit --fixup=<target>` makes exactly **one**
/// invocation. `git rebase --autosquash <target>^` then makes exactly
/// **one** more before failing when `succeedingCalls == 1` — not two: the
/// rebase's first todo entry is a plain "pick" of `<target>` onto its own
/// existing parent, which git recognizes as already in place and replays
/// without creating a new commit (no new signature needed); the *second*
/// entry is the fixup squash, which does create a new commit and is where
/// the one rebase-side invocation — and the failure — lands.
private func succeedThenFailGpgScript(succeedingCalls: Int) -> String {
    """
    #!/bin/sh
    cat > /dev/null
    count_file="gpg-call-count.txt"
    count=0
    if [ -f "$count_file" ]; then
        count=$(wc -c < "$count_file" | tr -d ' ')
    fi
    printf 'x' >> "$count_file"
    if [ "$count" -lt \(succeedingCalls) ]; then
        printf '[GNUPG:] SIG_CREATED D\\n' >&2
        printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nfakefakefakefake\\n-----END PGP SIGNATURE-----\\n'
        exit 0
    else
        echo "gpg: signing failed: No secret key" >&2
        exit 2
    fi
    """
}

// MARK: - Happy path

@Test func fixupSquashesStagedChangeIntoTheTargetAndAutosquashes() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    let target = try #require(repo.oids["c2"])

    try stage(["staged.txt": "staged content\n"], in: repo)

    let result = try Fixup.run(
        target: target, at: repo.url.path, extraEnvironment: hermetic)

    #expect(result.head == (try repo.revParse("HEAD")))

    let log = try git.run(
        ["log", "--oneline"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
    #expect(log.count == 3, "three commits after the rewrite — no extra fixup commit survives")

    let subjectList = try subjects(in: repo)
    #expect(!subjectList.isEmpty)
    #expect(!subjectList.contains { $0.hasPrefix("fixup!") })

    // The rewritten history keeps c3 as HEAD and c1 as HEAD~2 — the fixup
    // folded into HEAD~1, which now carries both c2's own file and the
    // staged one.
    #expect(try fileAt("HEAD~1", path: "c2.txt", in: repo) == "c2\n")
    #expect(try fileAt("HEAD~1", path: "staged.txt", in: repo) == "staged content\n")
}

// MARK: - Non-ancestor target

@Test func nonAncestorTargetIsRefusedAndHeadIsUnchanged() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let mainTip = try repo.revParse("HEAD")
    // "side" branches off "a" but is never merged back — a commit reachable
    // from neither `main` nor `HEAD`, the sibling-branch case.
    try repo.build([.init("side", parents: ["a"])])
    let sideTip = try #require(repo.oids["side"])
    try repo.checkout("main")
    #expect(try repo.revParse("HEAD") == mainTip)

    try stage(["staged.txt": "content\n"], in: repo)

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: sideTip, at: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    #expect(failure == .targetNotAncestor(target: sideTip))
    #expect(try repo.revParse("HEAD") == mainTip)
}

// MARK: - Nothing staged

@Test func nothingStagedRefusesWithoutCreatingACommit() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1"), .init("c2")])
    let target = try #require(repo.oids["c1"])
    let before = try repo.revParse("HEAD")

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
    }
    #expect(try #require(thrown) == .nothingStaged)
    #expect(try repo.revParse("HEAD") == before)
}

// MARK: - Conflict

@Test func conflictBlocksAndLeavesTheRebaseResumable() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("c1", files: ["f.txt": "a\n"]),
        .init("c2", files: ["f.txt": "b\n"]),
        .init("c3", files: ["f.txt": "c\n"]),
    ])
    let target = try #require(repo.oids["c2"])

    try stage(["f.txt": "z\n"], in: repo)

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
    }
    let failure = try #require(thrown)
    guard case let .blockedOnConflicts(files) = failure else {
        Issue.record("expected .blockedOnConflicts, got \(failure)")
        return
    }
    #expect(files.count == 1)
    let conflict = try #require(files.first)
    #expect(conflict.path == "f.txt")
    #expect(conflict.kind == .bothModified)
    #expect(rebaseInProgress(in: repo), "the rebase must be left resumable, not aborted")

    // Clean up so the fixture destructor is not fighting a live rebase.
    _ = try? git.run(["rebase", "--abort"], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

// MARK: - Undo

@Test func undoRestoresHeadAndBranchTipToThePreFixupState() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    let target = try #require(repo.oids["c2"])
    let before = try repo.revParse("HEAD")

    try stage(["staged.txt": "staged content\n"], in: repo)

    _ = try Fixup.run(target: target, at: repo.url.path, extraEnvironment: hermetic)
    #expect(try repo.revParse("HEAD") != before, "the fixup must actually change HEAD")

    let context = try WorktreeContext.resolve(path: repo.url.path)
    try JournalUndo.undo(in: context)

    #expect(try repo.revParse("HEAD") == before)
    #expect(try repo.revParse("refs/heads/main") == before)
}

// MARK: - Signing preserved

@Test func signedCommitsStaySignedWhenSigningIsConfigured() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    // Build the base commits first, unsigned (the fixture's default), then
    // turn signing on — mirroring an already-existing history that starts
    // being signed, and keeping the ancestor/nothing-staged guards above
    // unaffected by gpg.
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(succeedingGpgScript, in: repo)
    let target = try #require(repo.oids["c2"])

    try stage(["staged.txt": "staged content\n"], in: repo)

    _ = try Fixup.run(target: target, signing: .config, at: repo.url.path, extraEnvironment: hermetic)

    let log = try git.run(
        ["log", "--format=%H"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines
    #expect(log.count == 3)

    // Only the commits the rebase actually rewrote are re-signed — HEAD
    // (c3, replayed) and HEAD~1 (c2, replayed with the fixup squashed in).
    // The base of the rebase, c1, is untouched by the rewrite and was built
    // before signing was turned on, so it stays exactly as it was.
    #expect(try hasSignatureHeader(try #require(log.first), in: repo))
    #expect(try hasSignatureHeader(log[1], in: repo))
    #expect(!(try hasSignatureHeader(log[2], in: repo)), "c1 was never rewritten by the rebase")
}

// MARK: - Signing failure

@Test func signingFailureThrowsAndLeavesNoRebaseInProgress() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    // Base commits first, unsigned, then signing turned on with a gpg that
    // always fails — otherwise the fixture's own base commits could never
    // be built.
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    try installFakeGpg(failingGpgScript, in: repo)
    let target = try #require(repo.oids["c2"])
    let before = try repo.revParse("HEAD")

    try stage(["staged.txt": "staged content\n"], in: repo)

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: target, signing: .config, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .signingFailed = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!rebaseInProgress(in: repo), "a signing failure must not leave a resumable rebase")
    #expect(try repo.revParse("HEAD") == before, "no commit landed unsigned")
}

// MARK: - Signing fails mid-rebase, after the fixup commit itself signed fine

/// Exercises `classifiedRebaseFailure`'s signing branch specifically —
/// `signingFailureThrowsAndLeavesNoRebaseInProgress` above fails at the
/// `git commit --fixup=` step (`classifiedCommitFailure`) and never reaches
/// the rebase at all. Here the fixup commit signs successfully and the
/// **rebase's** first signature attempt is the one that fails, so this is
/// the only test that reaches the `git rebase --abort` call inside
/// `classifiedRebaseFailure`'s signing branch.
@Test func signingSucceedsForTheFixupCommitThenFailsDuringTheRebase() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("c1"), .init("c2"), .init("c3")])
    let target = try #require(repo.oids["c2"])
    let before = try repo.revParse("HEAD")

    try set("commit.gpgsign", "true", in: repo)
    try set("gpg.format", "openpgp", in: repo)
    // Measured: 1 gpg call for the fixup commit, then the rebase's own
    // first (and, once it fails, only) signature attempt is call #2 — so
    // succeeding through call 1 and failing from call 2 onward puts the
    // failure inside the rebase, not the commit.
    try installFakeGpg(succeedThenFailGpgScript(succeedingCalls: 1), in: repo)

    try stage(["staged.txt": "staged content\n"], in: repo)

    let thrown = #expect(throws: FixupError.self) {
        _ = try Fixup.run(target: target, signing: .config, at: repo.url.path, extraEnvironment: hermetic)
    }
    guard case .signingFailed = try #require(thrown) else {
        Issue.record("expected .signingFailed, got \(String(describing: thrown))")
        return
    }
    #expect(!rebaseInProgress(in: repo), "a signing failure mid-rebase must leave no rebase in progress")

    // `git rebase --abort` restores HEAD to where it stood immediately
    // before the rebase began, not all the way back to the pre-fixup tip:
    // the fixup commit itself was a separate, already-successful `git
    // commit --fixup=` that predates the rebase, and abort has no way to
    // undo it (measured). So HEAD has moved off `before` — the fixup commit
    // landed — but its rewrite was never applied: HEAD's own parent is
    // `before`, i.e. exactly the one commit `git commit --fixup=` made,
    // sitting un-autosquashed and un-rewritten on top.
    let head = try repo.revParse("HEAD")
    #expect(head != before, "the fixup commit itself did land before the rebase failed")
    let parent = try git.run(
        ["rev-parse", "HEAD^"], workingDirectory: repo.url.path, extraEnvironment: hermetic
    ).lines.first
    #expect(parent == before, "HEAD is exactly one commit — the un-rewritten fixup — past the pre-fixup tip")
}
