// RefSnapshotTests.swift — ref capture and restore round-trip exactly (#0027)

import Foundation
import Testing
@testable import YardGit

struct RefSnapshotTests {

    private let git = GitProcess()

    private func snapshot(of repo: FixtureRepository) throws -> RefSnapshot {
        try RefSnapshot.capture(in: WorktreeContext.resolve(path: repo.url.path))
    }

    // MARK: - Capture

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func captureListsDirectRefsAndSymbolicHead(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.branch("side", at: "b")
        try git.run(["tag", "t1"], workingDirectory: repo.url.path)
        try repo.checkout("main")

        let snap = try snapshot(of: repo)
        #expect(snap.head == .symbolic(target: "refs/heads/main"))
        let names = snap.refs.map(\.name)
        #expect(names == ["refs/heads/main", "refs/heads/side", "refs/tags/t1"])
        let byName = Dictionary(uniqueKeysWithValues: snap.refs.map { ($0.name, $0.oid) })
        #expect(byName["refs/heads/main"] == repo.oids["c"])
        #expect(byName["refs/heads/side"] == repo.oids["b"])
    }

    @Test func captureRecordsDetachedHead() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let target = try #require(repo.oids["b"])
        try repo.checkoutDetached(target)

        let snap = try snapshot(of: repo)
        #expect(snap.head == .detached(oid: target))
    }

    /// `HEAD` is per-worktree: captured from a linked worktree, the snapshot
    /// records that worktree's branch, not the main worktree's.
    @Test func captureInLinkedWorktreeSeesItsOwnHead() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }

        let inWorktree = try RefSnapshot.capture(in: WorktreeContext.resolve(path: wt.path))
        #expect(inWorktree.head == .symbolic(target: "refs/heads/agent-branch"))
        let inMain = try snapshot(of: repo)
        #expect(inMain.head == .symbolic(target: "refs/heads/main"))
    }

    // MARK: - Round trips

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func roundTripRestoresMovedAndDeletedRefsButLeavesRefsCreatedSinceAlone(
        format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.branch("side", at: "b")
        let snap = try snapshot(of: repo)

        // Everything an agent can do to refs between checkpoint and undo:
        // move one, delete one, create one.
        let a = try #require(repo.oids["a"])
        try git.run(["update-ref", "refs/heads/main", a], workingDirectory: repo.url.path)
        try git.run(["update-ref", "-d", "refs/heads/side"], workingDirectory: repo.url.path)
        try git.run(["update-ref", "refs/heads/extra", a], workingDirectory: repo.url.path)
        #expect(try snapshot(of: repo) != snap)

        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        // Every ref the snapshot recorded round-trips: `main` moved back,
        // `side` re-created.
        let after = try snapshot(of: repo)
        #expect(snap.refs.allSatisfy { want in
            after.refs.contains(where: { $0.name == want.name && $0.oid == want.oid })
        })
        // `extra` was created after capture, so restore under option A
        // (guide §11 decision 20) leaves it alone rather than deleting it as
        // an "extra" ref.
        #expect(try WorktreeContext.resolve(path: repo.url.path)
            .resolveRef("refs/heads/extra", inWorktree: nil) == a)
    }

    /// `refs/rewritten/*` is per-worktree despite the `refs/` prefix
    /// (CLAUDE.md): it is what an interrupted rebase uses to remember its
    /// mapping. Guide §11 decision 6 (#0044) claims capture already carries
    /// it and same-worktree restore already round-trips it because
    /// `for-each-ref` enumerates it under a plain name in the owning
    /// worktree — this pins that claim (#0249).
    @Test func roundTripRestoresRefsRewritten() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let a = try #require(repo.oids["a"])
        let b = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/rewritten/onto", a], workingDirectory: repo.url.path)
        let snap = try snapshot(of: repo)
        #expect(snap.refs.contains { $0.name == "refs/rewritten/onto" && $0.oid == a })

        try git.run(["update-ref", "refs/rewritten/onto", b], workingDirectory: repo.url.path)
        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        #expect(try repo.revParse("refs/rewritten/onto") == a)
    }

    /// `refs/bisect/*` is per-worktree despite the `refs/` prefix (CLAUDE.md):
    /// it is what an in-progress `git bisect` uses to remember its state.
    /// `RefSnapshot.perWorktreeNamespaces` already carries it and #0044's own
    /// premise lists it alongside `refs/rewritten/` and `refs/worktree/`, but
    /// unlike those two, nothing pinned that capture and same-worktree
    /// restore actually round-trip it — this closes that gap (#0257).
    @Test func roundTripRestoresRefsBisect() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let a = try #require(repo.oids["a"])
        let b = try #require(repo.oids["b"])
        try git.run(["update-ref", "refs/bisect/bad", a], workingDirectory: repo.url.path)
        let snap = try snapshot(of: repo)
        #expect(snap.refs.contains { $0.name == "refs/bisect/bad" && $0.oid == a })

        try git.run(["update-ref", "refs/bisect/bad", b], workingDirectory: repo.url.path)
        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        #expect(try repo.revParse("refs/bisect/bad") == a)
    }

    /// The measured trap this design exists for: restoring while standing on
    /// a branch created after capture. `HEAD` must be retargeted in its own
    /// no-deref transaction — dereferenced, `symref-update HEAD` corrupts the
    /// current branch into a self-referential symref, and a single combined
    /// transaction is a multiple-updates fatal.
    @Test func restoreRetargetsSymbolicHeadWithoutDeletingTheBranchItWasOn() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let snap = try snapshot(of: repo)

        try git.run(["checkout", "-q", "-b", "temp"], workingDirectory: repo.url.path)
        let tempOid = try repo.revParse("refs/heads/temp")
        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        let head = try git.run(["symbolic-ref", "HEAD"], workingDirectory: repo.url.path)
        #expect(head.lines.first == "refs/heads/main")
        // `temp` was created after capture and restore under option A (guide
        // §11 decision 20) no longer deletes refs it did not record — it
        // survives, at the oid it held when the branch was on it.
        let temp = try git.capture(["rev-parse", "--verify", "-q", "refs/heads/temp"],
                                   workingDirectory: repo.url.path)
        #expect(temp.exitCode == 0, "refs/heads/temp must survive restore")
        #expect(temp.lines.first == tempOid)
        let after = try snapshot(of: repo)
        #expect(snap.refs.allSatisfy { want in
            after.refs.contains(where: { $0.name == want.name && $0.oid == want.oid })
        })
    }

    @Test func restoreDetachesHead() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let target = try #require(repo.oids["b"])
        try repo.checkoutDetached(target)
        let snap = try snapshot(of: repo)

        try repo.checkout("main")
        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        let symref = try git.capture(["symbolic-ref", "--quiet", "HEAD"],
                                     workingDirectory: repo.url.path)
        #expect(symref.exitCode != 0, "HEAD must be detached after restore")
        #expect(try repo.revParse("HEAD") == target)
    }

    /// A symref may dangle, so `HEAD` can be retargeted at a branch the refs
    /// transaction only re-creates a moment later.
    @Test func restoreRestoresAHeadTargetDeletedAfterCapture() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git.run(["checkout", "-q", "-b", "feature"], workingDirectory: repo.url.path)
        let snap = try snapshot(of: repo)

        try repo.checkout("main")
        try git.run(["update-ref", "-d", "refs/heads/feature"], workingDirectory: repo.url.path)
        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))

        let head = try git.run(["symbolic-ref", "HEAD"], workingDirectory: repo.url.path)
        #expect(head.lines.first == "refs/heads/feature")
        #expect(try repo.revParse("refs/heads/feature") == repo.oids["c"])
    }

    // MARK: - Atomicity

    /// One unapplicable update rejects the whole ref transaction: the ref
    /// that could have moved must not have.
    @Test func restoreIsAtomicWhenOneUpdateCannotApply() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let a = try #require(repo.oids["a"])
        let c = try #require(repo.oids["c"])
        let snap = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [
                RefSnapshot.Entry(name: "refs/heads/main", oid: a),
                RefSnapshot.Entry(name: "refs/heads/ghost",
                                  oid: "0123456789012345678901234567890123456789"),
            ])

        #expect(throws: GitProcess.Failure.self) {
            try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))
        }
        #expect(try repo.revParse("refs/heads/main") == c,
                "main must not move when the batch containing it is rejected")
    }

    // MARK: - Exclusions

    /// The journal's own namespace is invisible to snapshots: never captured,
    /// and never deleted as an "extra" ref — a snapshot must not delete the
    /// anchor keeping itself reachable (#0028).
    @Test func journalRefsAreNeitherCapturedNorDeletedByRestore() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let c = try #require(repo.oids["c"])
        try git.run(["update-ref", "refs/switchyard/test/01TEST", c],
                    workingDirectory: repo.url.path)

        let snap = try snapshot(of: repo)
        #expect(!snap.refs.contains { $0.name.hasPrefix("refs/switchyard/") })

        try snap.restore(in: WorktreeContext.resolve(path: repo.url.path))
        let anchor = try git.capture(["rev-parse", "--verify", "-q",
                                      "refs/switchyard/test/01TEST"],
                                     workingDirectory: repo.url.path)
        #expect(anchor.exitCode == 0, "restore must not delete journal anchors")
    }

    /// Every clone has the symbolic `refs/remotes/origin/HEAD`. Captured
    /// naively, restore writes its resolved OID back alongside its referent's
    /// and git rejects the batch as a multiple update — so restore would fail
    /// in any cloned repository. Symrefs other than `HEAD` stay out entirely.
    @Test func restoreSucceedsInAClonedRepositoryWithOriginHead() throws {
        var origin = try FixtureRepository.linear()
        defer { origin.destroy() }
        let clonePath = origin.url.deletingLastPathComponent()
            .appendingPathComponent("\(origin.url.lastPathComponent)-clone")
        defer { try? FileManager.default.removeItem(at: clonePath) }
        try git.run(["clone", "-q", origin.url.path, clonePath.path])

        let context = try WorktreeContext.resolve(path: clonePath.path)
        let snap = try RefSnapshot.capture(in: context)
        #expect(!snap.refs.contains { $0.name == "refs/remotes/origin/HEAD" })
        #expect(snap.refs.contains { $0.name == "refs/remotes/origin/main" })

        try snap.restore(in: context)
        #expect(try RefSnapshot.capture(in: context) == snap)
        let originHead = try git.run(["symbolic-ref", "refs/remotes/origin/HEAD"],
                                     workingDirectory: clonePath.path)
        #expect(originHead.lines.first == "refs/remotes/origin/main",
                "origin/HEAD must survive restore untouched")
    }
}
