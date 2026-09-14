// RepositoryHeaderView.swift

import SwiftUI
import YardGit

/// The `whereAmI` summary shown at the top of the window: the one-line
/// tracking status (`TrackingSummary.text(for:)`) with the short OID beside
/// it, any in-progress git operation, and the four working-tree counts —
/// stash, untracked, unstaged, staged — in the order `WhereAmI` declares
/// them. The in-progress line is the same sentence #0359's menu uses to
/// disable a rewrite, so the header explains a disabled menu item.
struct RepositoryHeaderView: View {
    let whereAmI: WhereAmI

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(TrackingSummary.text(for: whereAmI))
                    .font(.headline)
                Text(whereAmI.headOID)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let message = TrackingSummary.operationInProgress(for: whereAmI) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 16) {
                countLabel("Stash", whereAmI.stashCount)
                countLabel("Untracked", whereAmI.untrackedCount)
                countLabel("Unstaged", whereAmI.unstagedCount)
                countLabel("Staged", whereAmI.stagedCount)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countLabel(_ name: String, _ count: Int) -> some View {
        Text("\(name): \(count)")
    }
}

#Preview {
    RepositoryHeaderView(whereAmI: WhereAmI(
        branch: "main",
        upstream: "origin/main",
        ahead: 1,
        behind: 0,
        isMidRebase: false,
        isMidMerge: false,
        isMidCherryPick: false,
        isMidRevert: false,
        stashCount: 0,
        untrackedCount: 2,
        unstagedCount: 1,
        stagedCount: 0,
        hasConflicts: false,
        conflictCount: 0,
        headOID: "a1b2c3d",
        rawHead: "a1b2c3d0000000000000000000000000000000"
    ))
    .padding()
}
