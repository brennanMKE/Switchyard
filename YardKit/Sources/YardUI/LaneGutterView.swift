// LaneGutterView.swift
//
// Per-row lane-graph drawing (#0052): a node marker in the commit's own
// `lane` and a line to each entry in `parentLanes`, plus a line continuing
// up from the row's top edge in the commit's own lane so two rows sharing a
// lane read as one continuous column.
//
// `graphRows(at:limit:revisions:git:)` and `CommitLog.run` are two separate
// engine calls, joined by `oid` in `CommitHistoryView`. A commit with no
// matching `GraphRow` is passed here as `row: nil`; this view then draws
// nothing but still reserves `width`, so an unmatched row's text does not
// shift relative to a matched one's.
//
// Colours are `Color.primary`/`Color.secondary` -- semantic, so light and
// dark both render correctly with nothing hardcoded here.

import SwiftUI
import YardGit

struct LaneGutterView: View {
    /// This row's lane assignment, or `nil` when `CommitHistoryView` found
    /// no `GraphRow` for the commit -- draws nothing in that case.
    let row: GraphRow?

    /// The gutter's width, shared by every row in one `CommitHistoryView`
    /// (`LaneGeometry.laneGutterWidth(maxLane:)` computed once for the whole
    /// loaded set) so the commit text lines up regardless of which lane any
    /// one row uses.
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let midY = size.height / 2
            let nodeX = LaneGeometry.xOffset(forLane: row.lane)

            var lines = Path()
            // Continue the commit's own lane up from the top edge -- the
            // edge a parent row above drew down into this row. Harmless for
            // the newest row, which has nothing above it to connect to.
            lines.move(to: CGPoint(x: nodeX, y: 0))
            lines.addLine(to: CGPoint(x: nodeX, y: midY))
            // One line per parent edge (empty for a root, per GraphRow's
            // documented invariant).
            for parentLane in row.parentLanes {
                let parentX = LaneGeometry.xOffset(forLane: parentLane)
                lines.move(to: CGPoint(x: nodeX, y: midY))
                lines.addLine(to: CGPoint(x: parentX, y: size.height))
            }
            context.stroke(lines, with: .color(.secondary), lineWidth: 1.5)

            let node = Path(ellipseIn: CGRect(
                x: nodeX - LaneGeometry.nodeRadius,
                y: midY - LaneGeometry.nodeRadius,
                width: LaneGeometry.nodeRadius * 2,
                height: LaneGeometry.nodeRadius * 2))
            context.fill(node, with: .color(.primary))
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

#Preview("Merge") {
    HStack(spacing: 0) {
        LaneGutterView(
            row: GraphRow(oid: "merge", parents: ["b", "side"], lane: 0, parentLanes: [0, 1]),
            width: LaneGeometry.laneGutterWidth(maxLane: 1)
        )
        LaneGutterView(
            row: GraphRow(oid: "b", parents: ["a"], lane: 0, parentLanes: [0]),
            width: LaneGeometry.laneGutterWidth(maxLane: 1)
        )
        LaneGutterView(
            row: GraphRow(oid: "a", parents: [], lane: 0, parentLanes: []),
            width: LaneGeometry.laneGutterWidth(maxLane: 1)
        )
    }
    .frame(height: 120)
    .padding()
}
