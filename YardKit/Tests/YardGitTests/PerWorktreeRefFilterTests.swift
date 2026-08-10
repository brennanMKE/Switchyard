// PerWorktreeRefFilterTests.swift — cross-worktree ref filtering (#0175)

import Foundation
import Testing
@testable import YardGit

struct PerWorktreeRefFilterTests {

    private let git = GitProcess()

    /// Measured on git 2.50.1: `refs/worktree/*` and `refs/bisect/*` are listed
    /// by `for-each-ref` **only in the worktree that owns them**, under plain
    /// names. So a `RefSnapshot` is a per-worktree artifact, and applying one
    /// elsewhere would plant another worktree's private refs.
    @Test func perWorktreeRefsAreVisibleOnlyInTheirOwnWorktree() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }

        try git.run(["update-ref", "refs/worktree/private", "HEAD"],
                    workingDirectory: wt.path)
        try git.run(["update-ref", "refs/bisect/bad", "HEAD"],
                    workingDirectory: wt.path)

        let sideNames = try git.run(["for-each-ref", "--format=%(refname)"],
                                    workingDirectory: wt.path).lines
        let mainNames = try git.run(["for-each-ref", "--format=%(refname)"],
                                    workingDirectory: repo.url.path).lines
        #expect(sideNames.contains("refs/worktree/private"))
        #expect(sideNames.contains("refs/bisect/bad"))
        #expect(!mainNames.contains("refs/worktree/private"),
                "the main worktree must not see the sibling's private refs")
        #expect(!mainNames.contains("refs/bisect/bad"))
    }

    /// The filter drops exactly the three per-worktree namespaces and nothing
    /// else — a filter that took `refs/` wholesale would strip every branch.
    @Test func theFilterDropsOnlyPerWorktreeNamespaces() {
        let snapshot = RefSnapshot(head: .detached(oid: "abc"), refs: [
            .init(name: "refs/heads/main", oid: "1"),
            .init(name: "refs/tags/v1", oid: "2"),
            .init(name: "refs/worktree/private", oid: "3"),
            .init(name: "refs/bisect/bad", oid: "4"),
            .init(name: "refs/rewritten/onto", oid: "5"),
            .init(name: "refs/remotes/origin/main", oid: "6"),
        ])
        let filtered = snapshot.withoutPerWorktreeRefs
        #expect(filtered.refs.map(\.name) == [
            "refs/heads/main", "refs/tags/v1", "refs/remotes/origin/main",
        ])
        #expect(filtered.head == snapshot.head, "HEAD is unaffected by the filter")
    }

    /// A same-worktree restore must NOT filter: those refs are exactly the
    /// state an in-progress bisect or rebase needs back.
    @Test func theUnfilteredSnapshotStillCarriesThem() {
        let snapshot = RefSnapshot(head: .detached(oid: "abc"), refs: [
            .init(name: "refs/worktree/private", oid: "3"),
        ])
        #expect(snapshot.refs.count == 1)
        #expect(snapshot.withoutPerWorktreeRefs.refs.isEmpty)
    }

    /// Round trip against a real repository: capturing in the sibling sees its
    /// private refs, and the filtered snapshot does not — so applying it in
    /// the main worktree cannot plant them.
    @Test func aCaptureFromASiblingFiltersToSomethingSafeToApply() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        try git.run(["update-ref", "refs/worktree/private", "HEAD"],
                    workingDirectory: wt.path)

        let sideContext = try WorktreeContext.resolve(path: wt.path)
        let captured = try RefSnapshot.capture(in: sideContext)
        #expect(captured.refs.contains { $0.name == "refs/worktree/private" },
                "the capture must contain the private ref, or the filter proves nothing")

        let safe = captured.withoutPerWorktreeRefs
        #expect(!safe.refs.contains { $0.name == "refs/worktree/private" })
        // Branches survive: the filter must not be a blunt refs/ strip.
        #expect(safe.refs.contains { $0.name == "refs/heads/main" })
    }
}
