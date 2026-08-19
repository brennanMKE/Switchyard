// CommitDetailView.swift

import SwiftUI
import YardGit

/// The Detail pane's content for a selected commit (#0082): its metadata,
/// then its diff. `ContentView` owns loading `files` (`loadCommitDiff`,
/// `RepositoryLoader.swift`) and passes the result in here separately from
/// `entry`, because the diff loads asynchronously off the History
/// selection while `entry`'s metadata is already in hand from
/// `CommitLogEntry`.
public struct CommitDetailView: View {
    private let entry: CommitLogEntry
    /// `nil` while the diff is loading; `[]` for a genuinely empty diff
    /// (e.g. an `--allow-empty` commit) once loaded.
    private let files: [FileDiff]?
    /// Set when `loadCommitDiff` throws.
    private let diffError: String?

    /// `commitDiff` returns an empty result for **every** merge commit,
    /// whatever it changed (measured, #0341) -- so a blank pane there would
    /// misread as "this changed nothing". `entry.parents.count > 1` decides
    /// the explicit note independently of what `files` came back as.
    private var isMerge: Bool { entry.parents.count > 1 }

    public init(entry: CommitLogEntry, files: [FileDiff]?, diffError: String?) {
        self.entry = entry
        self.files = files
        self.diffError = diffError
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata
                Divider()
                diffContent
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.subject)
                .font(.headline)
                .textSelection(.enabled)

            Text(entry.message)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(entry.shortOid)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(signatureLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !entry.refs.isEmpty {
                Text(entry.refs)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !entry.trailers.isEmpty {
                trailers
            }
        }
    }

    /// Trailers surfaced distinctly from the message body -- agent
    /// provenance (`Agent-Name:` and its kin) is recorded precisely, so a
    /// human can see it as data rather than reading it out of prose.
    private var trailers: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Trailers")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(entry.trailers.enumerated()), id: \.offset) { _, trailer in
                Text(trailer.description)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var signatureLabel: String {
        switch entry.signatureStatus {
        case .noSig: "No signature"
        case .good: "Good signature"
        case .goodUntrusted: "Good signature (untrusted)"
        case .bad: "Bad signature"
        case .expiredSignature: "Good signature (expired)"
        case .expiredKey: "Good signature (expired key)"
        case .revokedKey: "Good signature (revoked key)"
        case .cannotCheck: "Signature not checked"
        case .unknown: "Unknown signature status"
        }
    }

    // MARK: - Diff

    @ViewBuilder
    private var diffContent: some View {
        if isMerge {
            Text("Merge commit diffs are not shown yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let diffError {
            Text("Couldn't load diff: \(diffError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let files {
            if files.isEmpty {
                Text("This commit introduced no changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(files, id: \.path) { file in
                        FileDiffView(file: file)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

#Preview {
    CommitDetailView(
        entry: CommitLogEntry(
            oid: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            parents: ["0000000000000000000000000000000000000a"],
            author: "Ada Lovelace",
            refs: "HEAD -> main",
            signatureStatus: .good,
            message: "Add the Detail pane",
            trailers: []
        ),
        files: [
            FileDiff(
                path: "Sources/Example.swift",
                oldMode: nil,
                newMode: nil,
                isBinary: false,
                headerText: "diff --git a/Sources/Example.swift b/Sources/Example.swift\n",
                hunks: [
                    Hunk(
                        id: "abc123",
                        path: "Sources/Example.swift",
                        oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
                        header: "@@ -1,2 +1,3 @@",
                        body: [" line one", "+line two (added)", " line three"]
                    ),
                ]
            ),
        ],
        diffError: nil
    )
}
