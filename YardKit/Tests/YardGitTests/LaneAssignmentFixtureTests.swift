// LaneAssignmentFixtureTests.swift — table-driven lane fixtures in the row notation (#0025)

import Testing
@testable import YardGit

// MARK: - The row notation

/// A commit DAG and its expected lane assignment, parsed from the row
/// notation (documented in `docs/dag-lane-notation.md`, #0025).
///
/// One line per commit, children before parents — the order
/// `LaneAssigner.assign` requires. Every token is `name@lane`: the first
/// token on a line is the commit and the lane it must occupy, the remaining
/// tokens are its parents in parent order, each carrying the lane its edge
/// must continue in below the row. A line starting with `#` is a comment;
/// blank lines are skipped. A parent that never appears as a commit is a
/// dangling edge — legal, exactly like a parent outside a `--max-count`
/// window.
///
/// The notation is original to Switchyard: it is the two types `GraphNode`
/// and `GraphRow` flattened onto one line per commit, designed from their
/// shape and from nothing else. No other project's fixture format was
/// consulted.
struct DAGFixture: Equatable {

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// A token that is not `name@lane` with a non-negative integer lane.
        case malformedToken(token: String, line: String)
        /// The same commit name appeared on two lines.
        case duplicateCommit(String)
        /// No commit lines at all. An empty fixture would make every
        /// comparison `[] == []`, so it is refused outright.
        case emptyFixture

        var description: String {
            switch self {
            case let .malformedToken(token, line):
                "malformed token '\(token)' in line: \(line)"
            case let .duplicateCommit(name):
                "commit '\(name)' appears on two lines"
            case .emptyFixture:
                "fixture contains no commit lines"
            }
        }
    }

    /// The DAG, ready for `LaneAssigner.assign`.
    let nodes: [GraphNode]

    /// The expected output, row for row.
    let expected: [GraphRow]

    init(_ text: String) throws {
        var nodes: [GraphNode] = []
        var expected: [GraphRow] = []
        var seen: Set<String> = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var refs: [(name: String, lane: Int)] = []
            for token in line.split(whereSeparator: \.isWhitespace) {
                refs.append(try Self.parseRef(String(token), line: line))
            }
            guard let commit = refs.first else { continue }
            guard seen.insert(commit.name).inserted else {
                throw Failure.duplicateCommit(commit.name)
            }
            let parents = refs.dropFirst()
            nodes.append(GraphNode(oid: commit.name, parents: parents.map(\.name)))
            expected.append(GraphRow(
                oid: commit.name,
                parents: parents.map(\.name),
                lane: commit.lane,
                parentLanes: parents.map(\.lane)))
        }
        guard !nodes.isEmpty else { throw Failure.emptyFixture }
        self.nodes = nodes
        self.expected = expected
    }

    /// Parses one `name@lane` token. Exactly one `@`, a non-empty name, and
    /// a non-negative integer lane; anything else throws.
    static func parseRef(_ token: String, line: String) throws -> (name: String, lane: Int) {
        let parts = token.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              let lane = Int(parts[1]), lane >= 0 else {
            throw Failure.malformedToken(token: token, line: line)
        }
        return (String(parts[0]), lane)
    }
}

/// Parses the fixture, checks it holds exactly `commitCount` commits (so a
/// parser that silently drops lines cannot leave the comparison vacuous),
/// runs the assigner, and compares every row.
private func assertAssignmentMatches(
    _ text: String, commitCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let fixture = try DAGFixture(text)
    #expect(fixture.nodes.count == commitCount, sourceLocation: sourceLocation)
    let rows = LaneAssigner.assign(fixture.nodes)
    #expect(rows == fixture.expected, sourceLocation: sourceLocation)
}

// MARK: - Case fixtures

/// The criss-cross from `exactRowsForALiteralCrissCross`, in notation form.
/// Shared with the cross-check test below, which pins this constant to the
/// literal `GraphNode`/`GraphRow` arrays that test builds by hand.
private let crissCross = """
# b and s each merge the other (x = b+s, y = s+b); z merges the results.
z@0     x@0 y@1
y@1     s@1 b@2
x@0     b@0 s@1
s@1     base@1
b@0     base@0
base@0
"""

// MARK: - Cases

@Test func linearChainStaysInOneLane() throws {
    try assertAssignmentMatches("""
    c@0  b@0
    b@0  a@0
    a@0
    """, commitCount: 3)
}

@Test func branchAndMergeOpensASecondLane() throws {
    // The emission order git was measured to use for the merged fixture in
    // #0015 Given 1: merge, side, b, a.
    try assertAssignmentMatches("""
    merge@0  b@0 side@1
    side@1   a@1
    b@0      a@0
    a@0
    """, commitCount: 4)
}

@Test func crissCrossSharesThreeLanes() throws {
    try assertAssignmentMatches(crissCross, commitCount: 6)
}

@Test func octopusMergeFansOutOneLanePerParent() throws {
    // Emission order measured in #0015 Given 2: octo, z, y, x, base.
    try assertAssignmentMatches("""
    octo@0  x@0 y@1 z@2
    z@2     base@2
    y@1     base@1
    x@0     base@0
    base@0
    """, commitCount: 5)
}

@Test func sharedSecondParentJoinsItsAwaitingLane() throws {
    // m1 and m2 both carry side as their second parent; side's edge from m1
    // must join the lane already awaiting it, not open a fourth lane.
    // Emission order measured in #0015 Given 2.
    try assertAssignmentMatches("""
    tip@0   m1@0 m2@1
    m2@1    b@1 side@2
    b@1     base@1
    m1@0    a@0 side@2
    side@2  base@2
    a@0     base@0
    base@0
    """, commitCount: 7)
}

@Test func multipleRootsReuseTheFreedLane() throws {
    // Two unrelated single-commit histories: the first root frees lane 0
    // and the second occupies it instead of opening lane 1.
    try assertAssignmentMatches("""
    a@0
    b@0
    """, commitCount: 2)
}

@Test func orphanBranchFollowsInTheFreedLane() throws {
    // A disjoint chain emitted after the main chain — the orphan-branch
    // shape of `orphanRootReusesAFreedLane`, git-free. One column for all
    // four rows.
    try assertAssignmentMatches("""
    a2@0  a1@0
    a1@0
    o2@0  o1@0
    o1@0
    """, commitCount: 4)
}

@Test func convergenceClosesTheRightLanes() throws {
    // r converges lanes 0 and 1; lane 1 is free again when tip t arrives one
    // row later, and q converges 0 and 1 again at the bottom.
    try assertAssignmentMatches("""
    m@0  a@0 b@1
    a@0  r@0
    b@1  r@1
    r@0  q@0
    t@1  q@1
    q@0
    """, commitCount: 6)
}

@Test func allocationTakesTheLeftmostHole() throws {
    // Lanes 0 and 1 are both free (pa and pb were roots) while lane 2 is
    // still held by c's dangling edge to pc; tip d must land in lane 0.
    // pc never appears as a commit — a dangling parent, like a parent
    // outside a --max-count window.
    try assertAssignmentMatches("""
    a@0   pa@0
    b@1   pb@1
    c@2   pc@2
    pa@0
    pb@1
    d@0
    """, commitCount: 6)
}

// MARK: - The notation itself

@Test func notationEncodesTheSameDAGAsTheHandBuiltCrissCross() throws {
    // The same DAG `exactRowsForALiteralCrissCross` builds in code, decoded
    // from the notation. Both representations must be identical — this is
    // the test that fails when the parser misreads parent order, drops a
    // token, or takes a lane from the wrong side of the `@`.
    let fixture = try DAGFixture(crissCross)
    #expect(fixture.nodes == [
        GraphNode(oid: "z", parents: ["x", "y"]),
        GraphNode(oid: "y", parents: ["s", "b"]),
        GraphNode(oid: "x", parents: ["b", "s"]),
        GraphNode(oid: "s", parents: ["base"]),
        GraphNode(oid: "b", parents: ["base"]),
        GraphNode(oid: "base", parents: []),
    ])
    #expect(fixture.expected == [
        GraphRow(oid: "z", parents: ["x", "y"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "y", parents: ["s", "b"], lane: 1, parentLanes: [1, 2]),
        GraphRow(oid: "x", parents: ["b", "s"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "s", parents: ["base"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "b", parents: ["base"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "base", parents: [], lane: 0, parentLanes: []),
    ])
}

@Test func malformedTokensThrowNamingTheToken() {
    // Each shape throws the specific malformedToken failure. Asserting only
    // `DAGFixture.Failure.self` would be satisfied by `emptyFixture` from a
    // parser that silently skipped the bad token — measured, that exact
    // mutation left the loose assertion green.
    #expect(throws: DAGFixture.Failure.malformedToken(token: "a", line: "a")) {
        try DAGFixture("a\n")                                   // no @
    }
    #expect(throws: DAGFixture.Failure.malformedToken(token: "a@x", line: "a@x")) {
        try DAGFixture("a@x\n")                                 // non-integer lane
    }
    #expect(throws: DAGFixture.Failure.malformedToken(token: "a@-1", line: "a@-1")) {
        try DAGFixture("a@-1\n")                                // negative lane
    }
    #expect(throws: DAGFixture.Failure.malformedToken(token: "a@1@2", line: "a@1@2")) {
        try DAGFixture("a@1@2\n")                               // two @
    }
    #expect(throws: DAGFixture.Failure.malformedToken(token: "@1", line: "@1")) {
        try DAGFixture("@1\n")                                  // empty name
    }
    #expect(throws: DAGFixture.Failure.malformedToken(token: "a@", line: "a@ 1")) {
        try DAGFixture("a@ 1\n")                                // lane detached
    }
    // A malformed parent on an otherwise valid line: a parser that skipped
    // bad tokens would return a valid-looking one-commit fixture here.
    #expect(throws: DAGFixture.Failure.malformedToken(token: "x@y", line: "m@0 x@y")) {
        try DAGFixture("m@0 x@y\n")
    }
}

@Test func duplicateCommitThrows() {
    #expect(throws: DAGFixture.Failure.duplicateCommit("a")) {
        try DAGFixture("a@0\nb@0  a@0\na@0\n")
    }
}

@Test func emptyFixtureThrows() {
    #expect(throws: DAGFixture.Failure.emptyFixture) {
        try DAGFixture("# only a comment\n\n")
    }
}
