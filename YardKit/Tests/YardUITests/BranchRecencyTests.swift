// BranchRecencyTests.swift — the branch map's recency filter (#0429)
//
// Public-API import, same idiom as BranchMapLayoutTests.

import Foundation
import Testing
import YardGit
import YardUI

private func recencyRow(_ oid: String, _ parents: String...) -> GraphRow {
    GraphRow(oid: oid, parents: parents, lane: 0, parentLanes: parents.map { _ in 0 })
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day = 86_400

@Test func theWindowShowsTipsCommittedInsideItPlusRevealedOnes() {
    let refs = RefSnapshot(head: .symbolic(target: "refs/heads/main"), refs: [
        RefSnapshot.Entry(name: "refs/heads/main", oid: "fresh"),
        RefSnapshot.Entry(name: "refs/heads/older", oid: "older"),
        RefSnapshot.Entry(name: "refs/remotes/origin/undated", oid: "undated"),
    ])
    let dates = [
        "refs/heads/main": 1_800_000_000 - 1 * day,
        "refs/heads/older": 1_800_000_000 - 20 * day,
    ]
    #expect(BranchRecency.twoWeeks.shownTips(refs: refs, dates: dates, now: now, revealed: []) == ["fresh"])
    #expect(BranchRecency.month.shownTips(refs: refs, dates: dates, now: now, revealed: []) == ["fresh", "older"])
    #expect(BranchRecency.day.shownTips(refs: refs, dates: dates, now: now, revealed: ["picked"])
        == ["fresh", "picked"], "a tip exactly one day old is inside a one-day window")
    #expect(BranchRecency.all.shownTips(refs: refs, dates: dates, now: now, revealed: []) == nil)
    #expect(BranchRecency.twoWeeks.shownTips(refs: refs, dates: nil, now: now, revealed: []) == nil,
            "before the dates load, nothing is filtered")
    #expect(BranchRecency.standard == .twoWeeks)
}

@Test func aFilteredMapKeepsTheRootAndHeadAndGreysAParentAShownLaneNeeds() throws {
    // main: m0 -> m1 -> m2. base: b1 -> m1; child: c1 -> b1 (stacked on
    // base); stale: s1 -> m2; work (HEAD): w1 -> m2. Only child is recent.
    let rows = [
        recencyRow("c1", "b1"), recencyRow("w1", "m2"), recencyRow("s1", "m2"), recencyRow("b1", "m1"),
        recencyRow("m0", "m1"), recencyRow("m1", "m2"), recencyRow("m2"),
    ]
    let refs = RefSnapshot(head: .symbolic(target: "refs/heads/work"), refs: [
        RefSnapshot.Entry(name: "refs/heads/base", oid: "b1"), RefSnapshot.Entry(name: "refs/heads/child", oid: "c1"),
        RefSnapshot.Entry(name: "refs/heads/main", oid: "m0"), RefSnapshot.Entry(name: "refs/heads/stale", oid: "s1"),
        RefSnapshot.Entry(name: "refs/heads/work", oid: "w1"),
    ])
    let layout = BranchMapLayout.make(rows: rows, refs: refs, shownTips: ["c1"])
    #expect(layout.headers.map { $0.chips.map(\.name) } == [["main"], ["base"], ["child"], ["work"]])
    #expect(layout.headers.map(\.isContext) == [false, true, false, false])
    #expect(!layout.nodes.contains { $0.oid == "s1" }, "a hidden lane's commits are not drawn")
    let all = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(all.headers.count == 5)
    #expect(all.headers.allSatisfy { !$0.isContext })
}
