// BranchMapGeometry.swift
//
// #0412 (umbrella #0410): the branch map's points. `BranchMapLayout` says
// which (lane, row) a commit sits in; this turns cells into points in the
// map's rows area (below the pinned header of branch labels), edges into
// polylines, and says which edges each row strip has to draw. Pure, like
// `LaneGeometry`, so `swift test` pins it.

import CoreGraphics

public nonisolated enum BranchMapGeometry {
    /// Height of one row strip.
    public static let rowHeight: CGFloat = 24
    /// Distance between adjacent lane centres -- the History gutter's
    /// spacing (#0358), so a lane reads the same width it always has.
    public static let laneSpacing: CGFloat = LaneGeometry.laneSpacing
    /// Lane 0's centre from the map's leading edge.
    public static let leadingInset: CGFloat = 24
    /// Room right of the last lane for its slanted label to run into.
    public static let trailingInset: CGFloat = 160
    /// Height of the pinned header the slanted branch labels sit in.
    public static let headerHeight: CGFloat = 120
    /// How far below its start (or above its end) an edge turns.
    public static let bend: CGFloat = rowHeight / 2
    /// The side of a node's square hit target, which is also its
    /// accessibility frame -- smaller than a row, so the #0399 compactness
    /// bound (26 pt) still holds.
    public static let nodeTarget: CGFloat = 22
    /// Radius of a commit's dot.
    public static let nodeRadius: CGFloat = 5

    public static func x(lane: Int) -> CGFloat {
        leadingInset + CGFloat(lane) * laneSpacing
    }

    /// The centre of `row` within the rows area (row 0's top is y = 0).
    public static func y(row: Int) -> CGFloat {
        CGFloat(row) * rowHeight + rowHeight / 2
    }

    public static func point(_ cell: BranchMapLayout.Point) -> CGPoint {
        CGPoint(x: x(lane: cell.lane), y: y(row: cell.row))
    }

    /// The rows area's size: every lane plus room for the last label, every
    /// row. A map with no lanes still has the leading and trailing insets.
    public static func contentSize(_ layout: BranchMapLayout) -> CGSize {
        let lastLane = max(layout.laneCount - 1, 0)
        return CGSize(width: x(lane: lastLane) + trailingInset, height: CGFloat(layout.rowCount) * rowHeight)
    }

    /// The polyline an edge draws, start to end.
    ///
    /// - A chain is a straight vertical.
    /// - A fork runs down its own lane and turns into the fork point half a
    ///   row above it; when the fork point is not below, it drops half a row
    ///   and runs straight there. On one row it is a straight line.
    /// - A merge turns into the parent's lane half a row below the merge
    ///   and runs down that lane to the parent; when the parent is not
    ///   below that turn, it is a straight line.
    public static func polyline(_ edge: BranchMapLayout.Edge) -> [CGPoint] {
        let start = point(edge.from)
        let end = point(edge.to)
        switch edge.kind {
        case .chain:
            return [start, end]
        case .fork:
            if start.y == end.y { return [start, end] }
            if end.y - bend > start.y { return [start, CGPoint(x: start.x, y: end.y - bend), end] }
            return [start, CGPoint(x: start.x, y: start.y + bend), end]
        case .merge:
            if end.y > start.y + bend { return [start, CGPoint(x: end.x, y: start.y + bend), end] }
            return [start, end]
        }
    }

    /// For each row, the indices into `layout.edges` whose polyline passes
    /// through that row's strip (`[row * rowHeight, (row + 1) * rowHeight]`).
    /// A strip draws exactly these, so an edge spanning a hundred rows is
    /// drawn piecewise by a hundred strips and reads as one line.
    public static func edgesByRow(_ layout: BranchMapLayout) -> [[Int]] {
        var result = Array(repeating: [Int](), count: layout.rowCount)
        guard layout.rowCount > 0 else { return result }
        for (index, edge) in layout.edges.enumerated() {
            let ys = polyline(edge).map(\.y)
            guard let low = ys.min(), let high = ys.max() else { continue }
            let first = max(Int((low / rowHeight).rounded(.down)), 0)
            let last = min(Int((high / rowHeight).rounded(.down)), layout.rowCount - 1)
            guard first <= last else { continue }
            for row in first...last { result[row].append(index) }
        }
        return result
    }

    /// For each row, the indices into `layout.nodes` on that row.
    public static func nodesByRow(_ layout: BranchMapLayout) -> [[Int]] {
        var result = Array(repeating: [Int](), count: layout.rowCount)
        for (index, node) in layout.nodes.enumerated() where node.row < layout.rowCount {
            result[node.row].append(index)
        }
        return result
    }

    /// The scroll offset that puts `target` (a point in the rows area) at the
    /// centre of a `viewport` showing `content`, clamped so the view never
    /// scrolls past the content's edges. `headerHeight` is the pinned header
    /// above the rows, which is part of the scrolled content.
    public static func scrollOffset(centering target: CGPoint, viewport: CGSize, content: CGSize) -> CGPoint {
        let fullHeight = content.height + headerHeight
        let maxX = max(content.width - viewport.width, 0)
        let maxY = max(fullHeight - viewport.height, 0)
        let x = min(max(target.x - viewport.width / 2, 0), maxX)
        let y = min(max(target.y + headerHeight - viewport.height / 2, 0), maxY)
        return CGPoint(x: x, y: y)
    }
}
