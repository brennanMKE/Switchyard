// BranchMapMergedTests.swift — merged lanes dim (#0430)
//
// Public-API import, same idiom as BranchMapLayoutTests.

import Testing
import YardGit
import YardUI

private func mergedRow(_ oid: String, _ parents: String...) -> GraphRow {
    GraphRow(oid: oid, parents: parents, lane: 0, parentLanes: parents.map { _ in 0 })
}

private func statusRow(_ name: String, gone: Bool = false, defaultAhead: Int?) -> BranchStatus.Row {
    BranchStatus.Row(
        ref: "refs/heads/\(name)", upstream: gone ? "refs/remotes/origin/\(name)" : nil, upstreamGone: gone,
        baseline: .defaultBranch("main"), ahead: defaultAhead, behind: 0,
        defaultAhead: defaultAhead, defaultBehind: 0)
}

@Test func mergedBranchesFollowDecision27sCompositeAndLeaveOutUnknown() {
    let report = BranchStatus.Report(defaultBranch: "main", rows: [
        statusRow("ancestor", defaultAhead: 0),
        statusRow("gone", gone: true, defaultAhead: 2),
        statusRow("squashed", defaultAhead: 3),
        statusRow("open", defaultAhead: 1),
        statusRow("conflicted", defaultAhead: 1),
        statusRow("pending", defaultAhead: 4),
    ])
    let content: [String: BranchStatus.MergedState] = [
        "refs/heads/squashed": .merged(by: .content),
        "refs/heads/open": .notMerged,
        "refs/heads/conflicted": .unknown,
    ]
    #expect(BranchMapLayout.mergedBranches(in: report, content: content) == ["ancestor", "gone", "squashed"])
    #expect(BranchMapLayout.mergedBranches(in: report, content: [:]) == ["ancestor", "gone"],
            "before the content pass lands, only ancestry and upstream-gone answer")
}

@Test func aLaneDimsOnlyWhenEveryLocalBranchOnItIsMergedAndNeverTheRoot() throws {
    // main: m0 -> m1. feature f1, gamma and spike at g1, origin/orphan at o1,
    // all forking m1.
    let rows = [mergedRow("f1", "m1"), mergedRow("o1", "m1"), mergedRow("g1", "m1"), mergedRow("m0", "m1"), mergedRow("m1")]
    let refs = RefSnapshot(head: .symbolic(target: "refs/heads/main"), refs: [
        RefSnapshot.Entry(name: "refs/heads/feature", oid: "f1"), RefSnapshot.Entry(name: "refs/heads/gamma", oid: "g1"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "m0"), RefSnapshot.Entry(name: "refs/heads/spike", oid: "g1"),
        RefSnapshot.Entry(name: "refs/remotes/origin/orphan", oid: "o1"),
    ])
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    func lane(_ name: String) throws -> Int {
        try #require(layout.headers.first { $0.chips.contains { $0.name == name } }).lane
    }
    let dimmed = layout.dimmedLanes(mergedBranches: ["main", "feature", "gamma", "orphan", "origin/orphan"])
    #expect(dimmed == [try lane("feature")], "main is the root, spike is not merged, orphan is remote-only")
    #expect(layout.dimmedLanes(mergedBranches: ["gamma", "spike"]) == [try lane("gamma")])
}

@Test func aMergedLaneLabelSaysSoToVoiceOver() {
    let chips = [RefChip(name: "feature", kind: .localBranch, isHead: false)]
    #expect(BranchMapLabels.accessibilityLabel(chips, isMerged: true) == "Lane feature (merged)")
    #expect(BranchMapLabels.accessibilityLabel(chips) == "Lane feature")
}
