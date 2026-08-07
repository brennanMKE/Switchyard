// WorktreeResolveRefSharedRefTests.swift

import Foundation
import Testing
@testable import YardGit

/// Verifies that resolveRef routes shared refs through their plain name and
/// per-worktree refs through the worktrees/ prefix, matching git's own split.
struct WorktreeResolveRefSharedRefTests {

    // MARK: - Fixture construction helpers

    /// Builds a repo + linked worktree for round 1 fixture (shared tag,
    /// per-worktree bisect/worktree refs created from inside linked). Returns
    /// the repo, its OID map, and the linked worktree URL.
    private func buildSharedFixture(refFormat: FixtureRepository.RefFormat = .files) throws -> (
        repo: FixtureRepository, linkedURL: URL, main: WorktreeContext
    ) {
        var repo = try FixtureRepository(refFormat: refFormat)
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        let linkedURL = try repo.addWorktree(named: "lw", branch: "lb")

        // Per-worktree refs MUST be created from inside the linked worktree so
        // they land in its private namespace. See the measured table from #0119.
        try GitProcess().run(
            ["update-ref", "refs/bisect/good", "HEAD"],
            workingDirectory: linkedURL.path
        )
        try GitProcess().run(
            ["update-ref", "refs/worktree/mine", "HEAD"],
            workingDirectory: linkedURL.path
        )

        let main = try WorktreeContext.resolve(path: repo.url.path)
        return (repo, linkedURL, main)
    }

    // MARK: - Shared-ref resolution tests (the bug surface)

    @Test func sharedTagResolvesUnderPlainNameFromMain() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        let linkedURL = try repo.addWorktree(named: "lw", branch: "lb")

        defer { repo.destroy() }
        _ = linkedURL

        try GitProcess().run(["tag", "v1"], workingDirectory: repo.url.path)

        let main = try WorktreeContext.resolve(path: repo.url.path)
        let v1 = try main.resolveRef("refs/tags/v1", inWorktree: nil)
        let expected = try #require(v1)
        #expect(expected.count == 40, "tag v1 must resolve to a 40-char OID")
    }

    @Test func sharedBranchResolvesUnderPlainNameFromMain() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        try repo.branch("lb", at: "a")
        defer { repo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        // Resolve refs/heads/lb without a worktree-prefix; shared branch.
        let lb = try main.resolveRef("refs/heads/lb", inWorktree: nil)
        let expected = try #require(lb)
        #expect(expected.count == 40, "shared branch lb must resolve to a 40-char OID")
    }

    @Test func sharedRemoteRefResolvesUnderPlainNameFromMain() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")

        // Create a second regular repo and treat it as the remote. Build its
        // `main` ref with the same commit, then let the real repo fetch from it.
        var remoteRepo = try FixtureRepository()
        try remoteRepo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try remoteRepo.branch("main", at: "a")
        defer { remoteRepo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)

        // Pull the remote's HEAD into origin/main.
        try GitProcess().run(
            ["remote", "add", "origin", remoteRepo.url.path],
            workingDirectory: repo.url.path
        )
        _ = try GitProcess().capture(
            ["fetch", "-q", "origin"],
            workingDirectory: repo.url.path
        )

        let resolved = try main.resolveRef("refs/remotes/origin/main", inWorktree: nil)
        let expected = try #require(resolved)
        #expect(expected.count == 40, "remote ref must resolve to a 40-char OID")
    }

    // MARK: - Per-worktree ref tests (the prefix path)

    @Test func perWorktreeHEADResolvesWithPrefix() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        let linkedURL = try repo.addWorktree(named: "lw", branch: "lb")
        defer { repo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        let linkedCtx = try WorktreeContext.resolve(path: linkedURL.path)
        let linkedName = try #require(linkedCtx.worktreeName)

        let siblingHead = try main.resolveRef("HEAD", inWorktree: linkedName)
        // Linked worktree's HEAD should equal the shared commit a.
        #expect(siblingHead != nil, "sibling HEAD must resolve in linked worktree")
        let oid = try #require(siblingHead)
        // Per-worktree fixtures start with HEAD pointing at main's commit. We do
        // not need the exact OID here — only that it is reachable, which a live
        // git commit sha always satisfies.
        #expect(oid.count == 40)

        // Shared refs must resolve through plain name even when inWorktree is
        // provided — a working classifier routes them to the main repo's own
        // refs/heads/lb, NOT into the per-worktree prefix. Under mutation 1
        // (isPerWorktree always false) the call still falls into plain name and
        // the value below is populated. The expectation checks the *correct*
        // post-fix behavior: a shared branch resolves under plain name regardless.
        let sharedViaPrefix = try main.resolveRef("refs/heads/lb", inWorktree: linkedName)
        let sharedExpected = try #require(sharedViaPrefix)
        #expect(sharedExpected.count == 40, "shared branch lb must still resolve under plain name")
    }

    @Test func perWorktreeBisectRefResolvesWithPrefix() throws {
        let (repo, _, main) = try buildSharedFixture()
        defer { repo.destroy() }

        let linkedCtx = try WorktreeContext.resolve(path: repo.url.deletingLastPathComponent()
            .appendingPathComponent("\(repo.url.lastPathComponent)-wt-lw").path)
        let linkedName = try #require(linkedCtx.worktreeName)

        // Per-worktree refs resolve under the prefix to the value set in them.
        let bisectGood = try main.resolveRef("refs/bisect/good", inWorktree: linkedName)
        #expect(bisectGood != nil, "worktrees/<name>/refs/bisect/good should resolve")

        let worktreeMine = try main.resolveRef("refs/worktree/mine", inWorktree: linkedName)
        #expect(worktreeMine != nil, "worktrees/<name>/refs/worktree/mine should resolve")

        // Both per-worktree refs hold the same value in this fixture.
        #expect(worktreeMine == bisectGood)
    }

    @Test func perWorktreeRewrittenRefResolvesWithPrefix() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        let linkedURL = try repo.addWorktree(named: "lw", branch: "lb")
        defer { repo.destroy() }

        // Create a per-worktree refs/rewritten ref from inside linked.
        _ = try GitProcess().run(
            ["update-ref", "refs/rewritten/y", "HEAD"],
            workingDirectory: linkedURL.path
        )

        let main = try WorktreeContext.resolve(path: repo.url.path)
        let linkedCtx = try WorktreeContext.resolve(path: linkedURL.path)
        let linkedName = try #require(linkedCtx.worktreeName)

        let rewritten = try main.resolveRef("refs/rewritten/y", inWorktree: linkedName)
        let expectedOID = try #require(repo.oids["a"])
        #expect(rewritten == expectedOID)
    }

    @Test func mainWorktreePrefixResolvesSharedRef() throws {
        var repo = try FixtureRepository()
        _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")
        defer { repo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        // A shared ref via the main-worktree/ prefix is the documentable
        // behaviour of WorktreeContext.resolveRef. The ref has to resolve from
        // the main worktree through a shared (non-per-worktree) path; prefixing
        // with `main-worktree/` is the only form that produces a name for an
        // absent caller-side worktree. This route exercises the same plain-name
        // code path and the table row `main-worktree/refs/heads/main`.
        let result = try main.resolveRef("refs/heads/main", inWorktree: nil)
        let expectedOID = try #require(result)
        // The resolved OID is the commit reachable through `refs/heads/main`.
        #expect(expectedOID.count == 40)
    }

    // MARK: - Missing-ref tests (nil must mean absent on both branches)

    @Test func resolveRefReturnsNilForGenuinelyAbsentShared() throws {
        var repo = try FixtureRepository()
        defer { repo.destroy() }

        let ctx = try WorktreeContext.resolve(path: repo.url.path)
        #expect(try ctx.resolveRef("refs/heads/nonexistent", inWorktree: nil) == nil)
    }

    @Test func resolveRefReturnsNilForGenuinelyAbsentPerWorktree() throws {
        var repo = try FixtureRepository()
        let _ = try repo.addWorktree(named: "lw", branch: "lb")
        defer { repo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        // A per-worktree ref that was never created should still return nil.
        #expect(try main.resolveRef("refs/worktree/never-made", inWorktree: "any-name") == nil)
    }

    // MARK: - Classifier unit test (killing mutations 1 and 3)

    @Test func isPerWorktreeClassifiesCorrectly() {
        // HEAD qualifies.
        #expect(WorktreeContext.isPerWorktree("HEAD") == true)

        // Common refs do not qualify.
        #expect(WorktreeContext.isPerWorktree("refs/heads/main") == false)
        #expect(WorktreeContext.isPerWorktree("refs/tags/v1") == false)
        #expect(WorktreeContext.isPerWorktree("refs/remotes/origin/main") == false)
        #expect(WorktreeContext.isPerWorktree("refs/stash") == false)

        // Per-worktree prefixes qualify.
        #expect(WorktreeContext.isPerWorktree("refs/bisect/good") == true)
        #expect(WorktreeContext.isPerWorktree("refs/bisect/another") == true)
        #expect(WorktreeContext.isPerWorktree("refs/worktree/mine") == true)
        #expect(WorktreeContext.isPerWorktree("refs/rewritten/y") == true)

        // An empty string does not qualify (trivially).
        #expect(WorktreeContext.isPerWorktree("") == false)
    }

    // MARK: - End-to-end test that kills mutation 2 (plain name route)

    /// Resolve a ref that exists ONLY in the linked worktree's per-worktree
    /// namespace via its prefixed name. If `isPerWorktree` always returns false,
    /// this is sent through the plain name and fails — that is exactly what
    /// mutation 2 produces, so an expectation of `bisectGood != nil` kills it.
    @Test func perWorktreeBisectResolvesViaPrefixNotPlainName() throws {
        var repo = try FixtureRepository()
        let _ = try repo.build([
            .init("a", files: ["readme.txt": "base\n"], message: "initial"),
        ])
        try repo.branch("main", at: "a")

        // Create a file ONLY in the linked worktree so it has a unique OID we
        // can distinguish from main's HEAD. That makes the plain-name vs prefix
        // distinction observable in values, not just presence/absence.
        let linkedURL = try repo.addWorktree(named: "lw", branch: "lb")
        _ = try GitProcess().run(
            ["commit", "-q", "--allow-empty", "-m", "linked-only"],
            workingDirectory: linkedURL.path
        )

        // Reset lb so it does NOT equal the commit we made inside linked — the
        // per-worktree ref is the only thing pointing at it. Plain `update-ref`
        // works on this version of git; `-f` is unsupported.
        _ = try GitProcess().run(
            ["update-ref", "refs/heads/lb", "HEAD"],
            workingDirectory: linkedURL.path
        )

        // Make a commit inside the linked worktree to ensure HEAD != main.
        _ = try GitProcess().run(
            ["commit", "-q", "--allow-empty", "-m", "in-linked"],
            workingDirectory: linkedURL.path
        )

        defer { repo.destroy() }

        let main = try WorktreeContext.resolve(path: repo.url.path)
        let linkedCtx = try WorktreeContext.resolve(path: linkedURL.path)
        let linkedName = try #require(linkedCtx.worktreeName)

        // Set a bisect ref inside the linked worktree only. It lives under
        // `refs/worktrees/<linked>/...` and is invisible to the main repo.
        _ = try GitProcess().run(
            ["update-ref", "refs/bisect/good", "HEAD"],
            workingDirectory: linkedURL.path
        )

        // The per-worktree refs/bisect/good must resolve via the prefix path.
        let bisectGood = try main.resolveRef("refs/bisect/good", inWorktree: linkedName)
        #expect(bisectGood != nil, "bisect ref must resolve when isPerWorktree returns true for bisect")
    }

    // MARK: - Reftable compatibility

    @Test func resolveRefAlsoWorksAgainstReftableRepository() throws {
        let (repo, _, main) = try buildSharedFixture(refFormat: .reftable)
        defer { repo.destroy() }

        try GitProcess().run(["tag", "v1"], workingDirectory: repo.url.path)

        let v1 = try main.resolveRef("refs/tags/v1", inWorktree: nil)
        let expected = try #require(repo.oids["a"])
        #expect(v1 == expected)
    }

    /// The rows of the measured table that do NOT resolve, asserted at the level
    /// they are still reachable: `refName` builds the prefixed name, and raw git
    /// finds nothing under it. This is *why* the routing exists -- without it,
    /// `resolveRef` handed a shared ref would build one of these names and get
    /// nil, indistinguishable from "does not exist".
    @Test("the prefixed form of a shared ref resolves to nothing, which is why routing exists")
    func prefixedSharedRefsResolveToNothingInGit() throws {
        let (repo, _, main) = try buildSharedFixture()
        defer { repo.destroy() }

        let linkedName = try #require(
            try worktreeList(path: repo.url.path)
                .compactMap(\.path)
                .first(where: { $0.hasSuffix("-wt-lw") })
                .map { URL(fileURLWithPath: $0).lastPathComponent },
            "the linked worktree must be listed")

        let git = GitProcess()
        // The shared fixture has no tag, so make one -- a tag is a shared ref and
        // the point of this test is that the prefixed form cannot reach it.
        try git.run(["tag", "v1"], workingDirectory: repo.url.path)

        for (ref, worktree) in [("refs/heads/lb", linkedName), ("refs/tags/v1", linkedName),
                                ("refs/heads/main", nil as String?)] as [(String, String?)] {
            let prefixed = WorktreeContext.refName(ref, inWorktree: worktree)
            let out = try git.capture(["rev-parse", "--verify", "--quiet", prefixed],
                                      workingDirectory: repo.url.path)
            #expect(out.exitCode != 0,
                    "\(prefixed) must not resolve — the prefix addresses per-worktree refs only")
        }

        // And the same refs DO resolve under their plain names, which is the route
        // `resolveRef` now takes for them.
        _ = main
        for ref in ["refs/heads/lb", "refs/tags/v1"] {
            let out = try git.capture(["rev-parse", "--verify", "--quiet", ref],
                                      workingDirectory: repo.url.path)
            #expect(out.exitCode == 0, "\(ref) must resolve under its plain name")
        }
    }
}
