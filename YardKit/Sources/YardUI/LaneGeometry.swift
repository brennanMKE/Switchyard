// LaneGeometry.swift
//
// Pure geometry for the History pane's lane gutter (#0052): lane index ->
// x-offset, the gutter's total width as a function of the maximum lane
// actually used (so a linear history does not reserve space for lanes it
// never draws), and the widest lane any row or edge touches. No SwiftUI
// import -- a `CGFloat` in, `CGFloat` out helper `swift test` exercises
// directly, per the issue's "no engine logic in the view layer; anything
// worth testing lives in the package" criterion.
//
// `nonisolated`: like `PaneLayout`, a caseless enum of pure functions has no
// reason to inherit `YardUI`'s `.defaultIsolation(MainActor.self)` --
// marking it lets callers off the main actor, including this target's
// tests, call it without an `await`.

import CoreGraphics
import YardGit

public nonisolated enum LaneGeometry {
    /// Horizontal distance between adjacent lane centers, in points.
    public static let laneSpacing: CGFloat = 14

    /// Radius of a commit's node marker, in points.
    public static let nodeRadius: CGFloat = 3

    /// Leading inset before lane 0's center, in points.
    public static let leadingInset: CGFloat = 8

    /// Trailing inset after the widest touched lane's center, in points.
    public static let trailingInset: CGFloat = 8

    /// The x-offset of `lane`'s center within the gutter.
    public static func xOffset(forLane lane: Int) -> CGFloat {
        leadingInset + CGFloat(lane) * laneSpacing
    }

    /// The gutter's total width for a loaded set whose widest touched lane
    /// is `maxLane` -- 0 for a purely linear history, so lane 0 alone still
    /// reserves only enough width for itself. A negative `maxLane` (an empty
    /// loaded set, where `maxLane(in:)` below already returns 0, or any
    /// other caller) is clamped to 0 rather than producing a negative width.
    public static func laneGutterWidth(maxLane: Int) -> CGFloat {
        xOffset(forLane: max(maxLane, 0)) + trailingInset
    }

    /// The widest column any row's own lane or any parent edge touches.
    /// Mirrors `LaneAssignmentTests`' private `maxLane(_:)` helper, which
    /// the lane-assignment suite uses to catch a lane leak: a parent edge
    /// can reach a lane wider than any row's own `lane` (an octopus merge,
    /// for instance), so `lane` alone is not enough.
    public static func maxLane(in rows: [GraphRow]) -> Int {
        rows.map { row in max(row.lane, row.parentLanes.max() ?? 0) }.max() ?? 0
    }
}
