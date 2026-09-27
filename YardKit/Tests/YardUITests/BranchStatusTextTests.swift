// BranchStatusTextTests.swift
//
// #0422 pins the sidebar branch row's trailing text (`branchStatusText`)
// when the default branch does not resolve: every row used to read
// "unknown", a permanent answer shown as if it were pending.
//
// Imports YardUI WITHOUT `@testable`, matching this target's idiom (see
// RefFilterTests.swift): the pinned members are `public`.

import Foundation
import Testing
import YardGit
import YardUI

private let entry = RefSnapshot.Entry(name: "refs/heads/topic", oid: String(repeating: "a", count: 40))

private func row(
    upstream: String? = nil, upstreamGone: Bool = false,
    ahead: Int? = nil, behind: Int? = nil,
    defaultAhead: Int? = nil, defaultBehind: Int? = nil
) -> BranchStatus.Row {
    BranchStatus.Row(
        ref: "refs/heads/topic", upstream: upstream, upstreamGone: upstreamGone,
        baseline: upstream.map { BranchStatus.Baseline.upstream($0) } ?? .defaultBranch("main"),
        ahead: ahead, behind: behind,
        defaultAhead: defaultAhead, defaultBehind: defaultBehind)
}

private func text(_ row: BranchStatus.Row, content: [String: BranchStatus.MergedState]? = nil) -> String? {
    RepositorySidebarView.branchStatusText(
        for: entry, report: BranchStatus.Report(defaultBranch: "main", rows: [row]), content: content)
}

@Test("no default branch and no upstream: the row shows nothing")
func noBaselineShowsNothing() {
    #expect(text(row()) == nil)
    #expect(text(row(), content: [:]) == nil)
}

@Test("no default branch, live upstream: the upstream numbers alone")
func noDefaultWithUpstreamShowsOnlyNumbers() {
    let tracked = row(upstream: "refs/remotes/origin/topic", ahead: 1, behind: 0)
    #expect(text(tracked) == "↑1 vs origin/topic")
}

@Test("no default branch, upstream gone: merged is still reachable and shown")
func noDefaultUpstreamGoneStillSaysMerged() {
    #expect(text(row(upstream: "refs/remotes/origin/topic", upstreamGone: true)) == "merged")
}

@Test("default resolves, content pass pending: unknown is still shown")
func measurableButPendingStillSaysUnknown() {
    let pending = row(ahead: 2, behind: 0, defaultAhead: 2, defaultBehind: 0)
    #expect(text(pending) == "↑2 vs main · unknown")
}

@Test("default resolves and the tip is reachable: merged by ancestry")
func measurableAndReachableSaysMerged() {
    #expect(text(row(ahead: 0, behind: 3, defaultAhead: 0, defaultBehind: 3)) == "↓3 vs main · merged")
}

/// The VM fixture's shape through real git: the trunk is `uitest-main`, so
/// `origin/HEAD` is missing and the literal `main` fallback does not resolve.
@Test("a repository whose trunk is not main shows no branch status text")
func nonMainTrunkShowsNoText() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("a"), .init("b")])
    try repo.branch("spike-side")
    _ = try await GitProcess().run(["branch", "-m", "main", "uitest-main"], workingDirectory: repo.url.path)

    let report = try await BranchStatus.read(at: repo.url.path)
    let content = try? await BranchStatus.contentPass(for: report, at: repo.url.path)
    #expect(report.rows.count == 2)
    for name in ["refs/heads/uitest-main", "refs/heads/spike-side"] {
        let ref = RefSnapshot.Entry(name: name, oid: String(repeating: "0", count: 40))
        #expect(RepositorySidebarView.branchStatusText(for: ref, report: report, content: content) == nil)
    }
}
