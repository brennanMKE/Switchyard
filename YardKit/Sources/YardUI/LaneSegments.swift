// LaneSegments.swift
//
// #0365: what each History row's lane gutter draws, derived once from the
// whole loaded `[GraphRow]`. A `GraphRow` says where its own node sits and
// where its parent edges leave; it cannot say which edges from rows above
// cross it or end at it, and `LaneGutterView` needs both to draw a
// continuous graph. Every edge carries the two commits it joins, so #0366
// can colour it by branch and #0368 can dash it, without re-deriving it.
// Pure and `nonisolated`, like `LaneGeometry`.

import YardGit

/// One parent edge of the graph, as it appears in one row's gutter.
public nonisolated struct LaneEdge: Hashable, Sendable {
    /// The lane the edge occupies at this row's top edge (for `outgoing`,
    /// the lane it leaves this row's bottom edge in).
    public let lane: Int
    /// The commit the edge descends from.
    public let child: String
    /// The commit the edge runs toward.
    public let parent: String
    /// `parent`'s position in `child`'s parent list; 0 is the first parent.
    public let parentIndex: Int

    public init(lane: Int, child: String, parent: String, parentIndex: Int) {
        self.lane = lane
        self.child = child
        self.parent = parent
        self.parentIndex = parentIndex
    }
}

/// Everything one row's gutter strokes.
public nonisolated struct LaneRowSegments: Equatable, Sendable {
    /// Edges entering at the top that end at this row's node: straight when
    /// `lane == row.lane`, a converging curve otherwise. Empty for a tip --
    /// nothing above continues into it, so no line is drawn above its node.
    public let incoming: [LaneEdge]
    /// Edges crossing this row top to bottom without touching its node.
    public let passThrough: [LaneEdge]
    /// This row's own edges toward its parents, in `parents` order.
    public let outgoing: [LaneEdge]

    public init(incoming: [LaneEdge], passThrough: [LaneEdge], outgoing: [LaneEdge]) {
        self.incoming = incoming
        self.passThrough = passThrough
        self.outgoing = outgoing
    }
}

public nonisolated enum LaneSegments {
    /// One `LaneRowSegments` per row, same order as `rows` (the topological,
    /// newest-first order `graphRows` returns).
    public static func make(_ rows: [GraphRow]) -> [LaneRowSegments] {
        var open: [LaneEdge] = []
        var result: [LaneRowSegments] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            let incoming = open.filter { $0.parent == row.oid }
            let passThrough = open.filter { $0.parent != row.oid }
            let outgoing = zip(row.parents, row.parentLanes).enumerated().map { index, pair in
                LaneEdge(lane: pair.1, child: row.oid, parent: pair.0, parentIndex: index)
            }
            open = passThrough + outgoing
            result.append(LaneRowSegments(
                incoming: ordered(incoming), passThrough: ordered(passThrough), outgoing: outgoing))
        }
        return result
    }

    private static func ordered(_ edges: [LaneEdge]) -> [LaneEdge] {
        edges.sorted { ($0.lane, $0.child, $0.parentIndex) < ($1.lane, $1.child, $1.parentIndex) }
    }
}
