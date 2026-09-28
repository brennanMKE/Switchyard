// BranchHelpTextTests.swift
//
// #0433 pins the sidebar branch row's help text (`branchHelpText`): the row
// gives its width to the branch name and lets the status truncate, so the
// hover text is where the full status -- decision 27's baseline name
// included -- stays readable.
//
// Imports YardUI WITHOUT `@testable`, matching this target's idiom (see
// BranchStatusTextTests.swift): the pinned members are `public`.

import Testing
import YardGit
import YardUI

private let topic = RefSnapshot.Entry(name: "refs/heads/feature-near", oid: String(repeating: "a", count: 40))

@Test("no status: the help text is the full ref name alone")
func branchHelpWithoutStatusIsTheRefName() {
    #expect(RepositorySidebarView.branchHelpText(for: topic, status: nil) == "refs/heads/feature-near")
}

@Test("a status: the help text adds it in full on a second line, baseline included")
func branchHelpCarriesTheFullStatus() {
    let status = "↑4↓11 vs map-main · not merged"
    #expect(RepositorySidebarView.branchHelpText(for: topic, status: status)
        == "refs/heads/feature-near\n↑4↓11 vs map-main · not merged")
}

@Test("the help text carries branchStatusText's exact output")
func branchHelpCarriesBranchStatusText() {
    let row = BranchStatus.Row(
        ref: "refs/heads/feature-near", upstream: nil, upstreamGone: false,
        baseline: .defaultBranch("map-main"), ahead: 4, behind: 11,
        defaultAhead: 4, defaultBehind: 11)
    let report = BranchStatus.Report(defaultBranch: "map-main", rows: [row])
    let status = RepositorySidebarView.branchStatusText(
        for: topic, report: report, content: ["refs/heads/feature-near": .notMerged])
    #expect(status == "↑4↓11 vs map-main · not merged")
    #expect(RepositorySidebarView.branchHelpText(for: topic, status: status)
        == "refs/heads/feature-near\n↑4↓11 vs map-main · not merged")
}
