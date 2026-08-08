// CrossToolGuardTests.swift — the cross-tool guard names what moved (#0031)
//
// Deliberately NOT @testable: undo (#0034) calls the guard as a public
// caller, so a member silently dropping to internal must fail here at
// compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct CrossToolGuardTests {

    private let git = GitProcess()

    private func capture(at path: String) throws -> RefSnapshot {
        try RefSnapshot.capture(in: WorktreeContext.resolve(path: path))
    }

    private func divergences(
        from recorded: RefSnapshot, at path: String
    ) throws -> [CrossToolGuard.Divergence] {
        try CrossToolGuard.divergences(
            from: recorded, in: WorktreeContext.resolve(path: path))
    }

    // MARK: - Order and determinism (pure diff)

    @Test func diffReportsHeadFirstThenRefsInSortedOrder() {
        let old = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let new = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        // Recorded refs deliberately in reverse-sorted order: the report's
        // order must come from sorting, not from input order.
        let names = ["refs/tags/v9", "refs/heads/z", "refs/heads/m",
                     "refs/heads/f", "refs/heads/b", "refs/heads/a"]
        let recorded = RefSnapshot(
            head: .symbolic(target: "refs/heads/m"),
            refs: names.map { RefSnapshot.Entry(name: $0, oid: old) })
        let current = RefSnapshot(
            head: .detached(oid: new),
            refs: names.map { RefSnapshot.Entry(name: $0, oid: new) })

        let report = CrossToolGuard.diff(recorded: recorded, current: current)
        #expect(report.map(\.ref) == ["HEAD", "refs/heads/a", "refs/heads/b",
                                      "refs/heads/f", "refs/heads/m",
                                      "refs/heads/z", "refs/tags/v9"])
        #expect(report.first == CrossToolGuard.Divergence(
            ref: "HEAD", expected: "ref:refs/heads/m", actual: new))
    }

    // MARK: - Nothing moved

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func untouchedRepositoryReportsNoDivergence(
        _ format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try repo.branch("side", at: "b")

        let recorded = try capture(at: repo.url.path)
        #expect(try divergences(from: recorded, at: repo.url.path).isEmpty)
        // And the throwing form returns quietly.
        try CrossToolGuard.requireUnchanged(
            since: recorded, in: WorktreeContext.resolve(path: repo.url.path))
    }

    // MARK: - Ref moves, both ref formats

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func plainGitCommitReportsExactlyTheMovedBranch(
        _ format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let before = try repo.revParse("refs/heads/main")

        // The normal case: an agent commits with plain git between two
        // switchyard commands.
        try "d\n".write(to: repo.url.appendingPathComponent("d.txt"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "behind the journal's back"],
                    workingDirectory: repo.url.path)
        let after = try repo.revParse("refs/heads/main")

        let report = try divergences(from: recorded, at: repo.url.path)
        // Exactly one: HEAD still points at the same branch (`ref:` compares
        // the symref target, not its resolution), so only the branch moved.
        try #require(report.count == 1)
        #expect(report[0] == CrossToolGuard.Divergence(
            ref: "refs/heads/main", expected: before, actual: after))
    }

    @Test func checkoutReportsHeadAloneWithSymbolicTargets() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("side", at: "b")
        let recorded = try capture(at: repo.url.path)

        try repo.checkout("side")

        let report = try divergences(from: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0] == CrossToolGuard.Divergence(
            ref: "HEAD",
            expected: "ref:refs/heads/main",
            actual: "ref:refs/heads/side"))
    }

    @Test func detachedHeadReportsBareOidAgainstSymbolicTarget() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let b = try #require(repo.oids["b"])
        try repo.checkoutDetached(b)
        let recorded = try capture(at: repo.url.path)

        try repo.checkout("main")

        let report = try divergences(from: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0] == CrossToolGuard.Divergence(
            ref: "HEAD", expected: b, actual: "ref:refs/heads/main"))
    }

    @Test func deletedBranchReportsAbsentActual() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("side", at: "b")
        let recorded = try capture(at: repo.url.path)
        let b = try #require(repo.oids["b"])

        try git.run(["update-ref", "-d", "refs/heads/side"],
                    workingDirectory: repo.url.path)

        let report = try divergences(from: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0] == CrossToolGuard.Divergence(
            ref: "refs/heads/side", expected: b, actual: nil))
    }

    @Test func branchCreatedByAnotherToolReportsAbsentExpected() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let a = try #require(repo.oids["a"])

        // Restore would DELETE this ref (#0027 plans deletions from the same
        // listing) — work the journal never knew about. The whole guard
        // exists so that clobber is refused with a name attached.
        try git.run(["update-ref", "refs/heads/intruder", a],
                    workingDirectory: repo.url.path)

        let report = try divergences(from: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0] == CrossToolGuard.Divergence(
            ref: "refs/heads/intruder", expected: nil, actual: a))
    }

    // MARK: - Worktrees: shared refs guarded, HEAD per-worktree

    @Test func sharedRefMovedFromASiblingWorktreeIsReported() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let recorded = try capture(at: repo.url.path)

        // A sibling agent commits in its own worktree: refs/heads/* is
        // shared, so the move is visible — and guarded — from here.
        try "w\n".write(to: wt.appendingPathComponent("w.txt"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: wt.path)
        try git.run(["commit", "-qm", "sibling"], workingDirectory: wt.path)

        let report = try divergences(from: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0].ref == "refs/heads/agent-branch")
        #expect(report[0].expected == repo.oids["c"])
        #expect(report[0].actual == (try repo.revParse("refs/heads/agent-branch")))
        // The sibling's HEAD is per-worktree state; it is not this context's
        // HEAD and is not reported here. Surfacing "a restore would disturb
        // worktree agent-a" is #0044's layer on top of this report.
    }

    // MARK: - Exclusions

    @Test func journalNamespaceRefsAreInvisibleToTheGuard() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let c = try #require(repo.oids["c"])

        // Journal machinery written after capture (an anchor for the next
        // entry, say) is not "another tool moving refs": the snapshot's
        // namespace filter applies to both sides of the comparison.
        try git.run(["update-ref", "refs/switchyard/test/01GUARD", c],
                    workingDirectory: repo.url.path)

        #expect(try divergences(from: recorded, at: repo.url.path).isEmpty)
    }

    // MARK: - The refusal

    @Test func requireUnchangedThrowsNamingEveryRefAndBothValues() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.branch("side", at: "b")
        let recorded = try capture(at: repo.url.path)
        let a = try #require(repo.oids["a"])
        let b = try #require(repo.oids["b"])
        let c = try #require(repo.oids["c"])

        // Two independent moves: one branch rewound, one deleted.
        try git.run(["update-ref", "refs/heads/main", a],
                    workingDirectory: repo.url.path)
        try git.run(["update-ref", "-d", "refs/heads/side"],
                    workingDirectory: repo.url.path)

        let error = try #require(throws: CrossToolGuard.Error.self) {
            try CrossToolGuard.requireUnchanged(
                since: recorded,
                in: WorktreeContext.resolve(path: repo.url.path))
        }
        #expect(error == .repositoryChanged(divergences: [
            .init(ref: "refs/heads/main", expected: c, actual: a),
            .init(ref: "refs/heads/side", expected: b, actual: nil),
        ]))
        // The human-readable form names refs and values too — a bare
        // "repository changed" is useless to whoever hits it.
        #expect(error.description.contains("refs/heads/main was \(c), now \(a)"))
        #expect(error.description.contains("refs/heads/side was \(b), now absent"))
        #expect(error.exitClass == .repositoryError)
    }
}
