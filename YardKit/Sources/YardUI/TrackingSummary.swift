// TrackingSummary.swift
//
// #0358: the one-line tracking status the header shows, built from
// `WhereAmI` alone so it is testable without a repository.

import YardGit

public nonisolated enum TrackingSummary {
    public static func text(for state: WhereAmI) -> String {
        guard let branch = state.branch else {
            return state.headOID.isEmpty ? "No commits yet" : "Detached HEAD at \(state.headOID)"
        }
        guard let upstream = state.upstream else {
            return "On branch \(branch) · no upstream"
        }
        let ahead = state.ahead ?? 0
        let behind = state.behind ?? 0
        switch (ahead, behind) {
        case (0, 0): return "On branch \(branch) · up to date with \(upstream)"
        case (_, 0): return "On branch \(branch) · \(ahead) ahead of \(upstream)"
        case (0, _): return "On branch \(branch) · \(behind) behind \(upstream)"
        default: return "On branch \(branch) · \(ahead) ahead, \(behind) behind \(upstream)"
        }
    }

    /// The in-progress git operation that blocks history changes, or `nil`.
    public static func operationInProgress(for state: WhereAmI) -> String? {
        if state.isMidRebase { return "A rebase is in progress" }
        if state.isMidMerge { return "A merge is in progress" }
        if state.isMidCherryPick { return "A cherry-pick is in progress" }
        if state.isMidRevert { return "A revert is in progress" }
        if state.hasConflicts { return "There are unresolved conflicts" }
        return nil
    }
}
