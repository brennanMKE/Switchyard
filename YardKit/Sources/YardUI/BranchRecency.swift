// BranchRecency.swift
//
// #0429 (umbrella #0425): the branch map's recency filter, guide §11
// decision 29. A lane shows when a ref at its tip was committed inside the
// window; `BranchMapLayout.make(shownTips:)` adds the root lane, `HEAD`'s
// lane and context parents. Pure, so `swift test` pins it.

import Foundation
import YardGit

public nonisolated enum BranchRecency: String, CaseIterable, Identifiable, Sendable {
    case day = "1d"
    case threeDays = "3d"
    case week = "1w"
    case twoWeeks = "2w"
    case month = "1m"
    case threeMonths = "3m"
    case all

    /// Decision 29's default.
    public static let standard: BranchRecency = .twoWeeks

    public var id: String { rawValue }

    /// The pop-up's item.
    public var title: String {
        switch self {
        case .day: "Last day"
        case .threeDays: "Last 3 days"
        case .week: "Last week"
        case .twoWeeks: "Last 2 weeks"
        case .month: "Last month"
        case .threeMonths: "Last 3 months"
        case .all: "All branches"
        }
    }

    /// The window's length; `nil` for `.all`. A month is 30 days.
    public var seconds: Int? {
        switch self {
        case .day: 86_400
        case .threeDays: 3 * 86_400
        case .week: 7 * 86_400
        case .twoWeeks: 14 * 86_400
        case .month: 30 * 86_400
        case .threeMonths: 90 * 86_400
        case .all: nil
        }
    }

    /// The tips `BranchMapLayout.make(shownTips:)` should show: every local
    /// and remote-tracking ref whose tip date (`dates`, keyed by full ref
    /// name) is at or after `now` minus the window, plus `revealed` -- tips
    /// the user picked in the sidebar. `nil`, which shows every lane, for
    /// `.all` and while the dates have not loaded.
    public func shownTips(
        refs: RefSnapshot?, dates: [String: Int]?, now: Date, revealed: Set<String>
    ) -> Set<String>? {
        guard let seconds, let refs, let dates else { return nil }
        let cutoff = Int(now.timeIntervalSince1970) - seconds
        var shown = revealed
        for entry in refs.refs where (dates[entry.name] ?? Int.min) >= cutoff {
            shown.insert(entry.oid)
        }
        return shown
    }
}
