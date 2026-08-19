// RepositoryHeaderView.swift

import SwiftUI
import YardGit

/// The `whereAmI` summary shown at the top of the window: branch, short OID,
/// upstream, and the four working-tree counts — stash, untracked, unstaged,
/// staged — in the order `WhereAmI` declares them.
struct RepositoryHeaderView: View {
    let whereAmI: WhereAmI

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(whereAmI.branch ?? "detached HEAD")
                    .font(.headline)
                Text(whereAmI.headOID)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let upstream = whereAmI.upstream {
                    Text(upstream)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
