// LaneGutterView.swift
//
// Per-row lane-graph drawing (#0365): everything one row's gutter strokes is
// passed in as a `LaneRowSegments` -- the edges from rows above that cross
// this row, the ones converging into this row's node, and this row's own
// outgoing parent edges -- so the graph reads as one continuous drawing
// rather than one line per row. Edges that change lane are vertical-tangent
// curves, never straight diagonals.
//
// `graphRows(at:limit:revisions:git:)` and `CommitLog.run` are two separate
// engine calls, joined by `oid` in `CommitHistoryView`. A commit with no
// matching `GraphRow` is passed here as `row: nil`; this view then draws
// nothing but still reserves `width`, so an unmatched row's text does not
// shift relative to a matched one's.
//
// Node shape carries meaning (Differentiate Without Color): a filled dot is
// a commit, a hollow ring is a merge (the dot cleared underneath so the
// selection highlight shows through), and an extra ring marks `HEAD`. A tip
// draws no line above its node because no incoming edge reaches it.

import SwiftUI
import YardGit

struct LaneGutterView: View {
    /// This row's lane assignment, or `nil` when `CommitHistoryView` found
    /// no `GraphRow` for the commit -- draws nothing in that case.
    let row: GraphRow?

    /// The edges this row's gutter strokes, derived from the whole loaded
    /// row list, or `nil` alongside `row`.
    let segments: LaneRowSegments?

    /// Whether this row's commit is the repository's `HEAD`; adds an extra
    /// ring around the node.
    let isHead: Bool

    /// The gutter's width, shared by every row in one `CommitHistoryView`
    /// (`LaneGeometry.laneGutterWidth(maxLane:)` computed once for the whole
    /// loaded set) so the commit text lines up regardless of which lane any
    /// one row uses.
    let width: CGFloat

    /// oid -> owning branch tip (#0366), derived once by `CommitHistoryView`
    /// from the whole loaded row list. Edges stroke and nodes fill in the
    /// owning branch's colour; unowned history draws `.secondary`.
    let owners: [String: BranchTip]

    var body: some View {
        Canvas { context, size in
            guard let row, let segments else { return }
            let midY = size.height / 2
            let node = CGPoint(x: LaneGeometry.xOffset(forLane: row.lane), y: midY)

            func stroke(_ path: Path, for edge: LaneEdge) {
                let color = BranchColor.color(for: BranchOwnership.owner(of: edge, in: owners))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            func edge(from start: CGPoint, to end: CGPoint) -> Path {
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let midway = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: midway),
                                  control2: CGPoint(x: end.x, y: midway))
                }
                return path
            }

            for through in segments.passThrough {
                let x = LaneGeometry.xOffset(forLane: through.lane)
                stroke(edge(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height)), for: through)
            }
            for arriving in segments.incoming {
                stroke(edge(from: CGPoint(x: LaneGeometry.xOffset(forLane: arriving.lane), y: 0), to: node),
                       for: arriving)
            }
            for leaving in segments.outgoing {
                stroke(edge(from: node, to: CGPoint(x: LaneGeometry.xOffset(forLane: leaving.lane), y: size.height)),
                       for: leaving)
            }

            let radius = LaneGeometry.nodeRadius + 1
            let dot = Path(ellipseIn: CGRect(x: node.x - radius, y: node.y - radius,
                                             width: radius * 2, height: radius * 2))
            let nodeColor = BranchColor.color(for: owners[row.oid])
            if row.parents.count > 1 {
                var clearing = context
                clearing.blendMode = .clear
                clearing.fill(dot, with: .color(.black))
                context.stroke(dot, with: .color(nodeColor), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(nodeColor))
            }
            if isHead {
                let ring = radius + 3
                context.stroke(
                    Path(ellipseIn: CGRect(x: node.x - ring, y: node.y - ring, width: ring * 2, height: ring * 2)),
                    with: .color(.primary), lineWidth: 1.5)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

#Preview("Merge") {
    HStack(spacing: 0) {
        LaneGutterView(
            row: GraphRow(oid: "merge", parents: ["b", "side"], lane: 0, parentLanes: [0, 1]),
            segments: LaneSegments.make([
                GraphRow(oid: "merge", parents: ["b", "side"], lane: 0, parentLanes: [0, 1]),
                GraphRow(oid: "b", parents: ["a"], lane: 0, parentLanes: [0]),
                GraphRow(oid: "a", parents: [], lane: 0, parentLanes: []),
            ]).first,
            isHead: true,
            width: LaneGeometry.laneGutterWidth(maxLane: 1),
            owners: [:]
        )
        LaneGutterView(
            row: GraphRow(oid: "b", parents: ["a"], lane: 0, parentLanes: [0]),
            segments: LaneSegments.make([
                GraphRow(oid: "b", parents: ["a"], lane: 0, parentLanes: [0]),
                GraphRow(oid: "a", parents: [], lane: 0, parentLanes: []),
            ]).first,
            isHead: false,
            width: LaneGeometry.laneGutterWidth(maxLane: 1),
            owners: [:]
        )
        LaneGutterView(
            row: GraphRow(oid: "a", parents: [], lane: 0, parentLanes: []),
            segments: LaneSegments.make([
                GraphRow(oid: "a", parents: [], lane: 0, parentLanes: []),
            ]).first,
            isHead: false,
            width: LaneGeometry.laneGutterWidth(maxLane: 1),
            owners: [:]
        )
    }
    .frame(height: 120)
    .padding()
    .environment(\.colorScheme, .dark)
}
