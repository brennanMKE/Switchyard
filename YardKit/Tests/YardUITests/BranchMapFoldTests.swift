// BranchMapFoldTests.swift — the branch map's "⋯ N" folds (#0427)
//
// Same idiom as BranchMapLayoutTests: public-API import, hand-written DAGs
// in topological order.

import Testing
import YardGit
import YardUI

private func foldRow(_ oid: String, _ parents: String...) -> GraphRow {
    GraphRow(oid: oid, parents: parents, lane: 0, parentLanes: parents.map { _ in 0 })
}

/// main: m0 -> m1 -> ... -> m9 (m9 the root commit), `head` its tip.
private func mainLine(_ count: Int = 10) -> [GraphRow] {
    (0..<count).map { index in
        index == count - 1 ? foldRow("m\(index)") : foldRow("m\(index)", "m\(index + 1)")
    }
}

private func foldRefs(_ entries: (String, String)...) -> RefSnapshot {
    RefSnapshot(
        head: .symbolic(target: "refs/heads/main"),
        refs: [RefSnapshot.Entry(name: "refs/heads/main", oid: "m0")]
            + entries.map { RefSnapshot.Entry(name: "refs/heads/\($0.0)", oid: $0.1) })
}

private func point(_ lane: Int, _ row: Int) -> BranchMapLayout.Point {
    BranchMapLayout.Point(lane: lane, row: row)
}

@Test func aQuietRunBetweenForkPointsFoldsIntoOneRow() throws {
    // feature forks at m6. m1-m5 are quiet (5 commits): one fold on row 1,
    // then m6 on row 2 and the root tail m7-m9 (3 commits) folds on row 3.
    let rows = [foldRow("f1", "m6")] + mainLine()
    let layout = BranchMapLayout.make(rows: rows, refs: foldRefs(("feature", "f1")))
    #expect(layout.folds == [
        BranchMapLayout.Fold(lane: 0, row: 1, oids: ["m1", "m2", "m3", "m4", "m5"]),
        BranchMapLayout.Fold(lane: 0, row: 3, oids: ["m7", "m8", "m9"]),
    ])
    #expect(layout.nodes.map(\.oid) == ["f1", "m0", "m6"])
    #expect(layout.nodes.map(\.point) == [point(1, 0), point(0, 0), point(0, 2)])
    #expect(layout.rowCount == 4)
    #expect(layout.edges.contains(BranchMapLayout.Edge(kind: .fork, from: point(1, 0), to: point(0, 2))))
}

@Test func aRunShorterThanThreeDoesNotFold() throws {
    // Forks at m3 and m6 leave m1-m2 and m4-m5 quiet: two commits each.
    let rows = [foldRow("a1", "m3"), foldRow("b1", "m6")] + mainLine(8)
    let layout = BranchMapLayout.make(rows: rows, refs: foldRefs(("a", "a1"), ("b", "b1")))
    #expect(layout.folds.isEmpty)
    #expect(layout.nodes.count == 10)
}

@Test func aBranchKeepsItsTipAndLastCommitAndFoldsItsMiddle() throws {
    // feature: f0 (tip) -> f1 .. f4 -> f5 (last) -> m1.
    let rows = (0...5).map { $0 == 5 ? foldRow("f5", "m1") : foldRow("f\($0)", "f\($0 + 1)") } + mainLine(3)
    let layout = BranchMapLayout.make(rows: rows, refs: foldRefs(("feature", "f0")))
    #expect(layout.folds == [BranchMapLayout.Fold(lane: 1, row: 1, oids: ["f1", "f2", "f3", "f4"])])
    #expect(layout.nodes.filter { $0.lane == 1 }.map(\.oid) == ["f0", "f5"])
    #expect(layout.nodes.first { $0.oid == "f5" }?.row == 2)
    #expect(layout.nodes.first { $0.oid == "m1" }?.row == 3)
}

@Test func anExpandedFoldShowsItsCommitsAndOthersStayFolded() throws {
    let rows = [foldRow("f1", "m6")] + mainLine()
    let refs = foldRefs(("feature", "f1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs, expandedFolds: ["m1"])
    #expect(layout.folds.map(\.key) == ["m7"])
    #expect(layout.nodes.first { $0.oid == "m5" }?.point == point(0, 5))
    #expect(layout.nodes.first { $0.oid == "m6" }?.point == point(0, 6))
    #expect(layout.rowCount == 8)
}
