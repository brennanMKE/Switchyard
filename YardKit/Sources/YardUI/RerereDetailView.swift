// RerereDetailView.swift
//
// The Detail pane's content for a selected recorded rerere resolution
// (#0065): the conflict id and its attributed paths, then the recorded
// diff — the preimage → postimage bytes the rr-cache holds, loaded by
// `loadRerereResolution` (`RepositoryLoader.swift`) and rendered through
// `FileDiffView`, the same component `CommitDetailView` uses.
//
// The destructive arm is "Forget…", behind the same two-step confirm the
// review sheet's amend arm uses (`amendSelected` swaps the action row for a
// Cancel + confirm pair): forgetting a recorded resolution is destructive —
// the same conflict will ask for a human resolution again — so a single
// mis-click must not do it. The engine call is `rerereForget`
// (`RerereForget.swift`), wrapping the measured `git rerere forget <path>`.

import SwiftUI
import YardGit

public struct RerereDetailView: View {
    /// The repository the resolution belongs to — the forget call needs it.
    public let repositoryPath: String
    /// The selected entry, held as a value: after a forget the sidebar
    /// reloads and the entry leaves the recorded set, and this pane keeps
    /// showing what was selected until a new selection replaces it.
    public let entry: Rerere.Entry
    /// `nil` while the diff is loading; the loaded resolution otherwise.
    public let resolution: Rerere.Resolution?
    /// Set when `loadRerereResolution` throws.
    public let resolutionError: String?
    /// Fired after a successful forget, so the owner can reload the
    /// sidebar the resolution came from.
    public var onForgotten: () -> Void

    /// Whether the Forget arm can act at all: git identifies recorded
    /// resolutions by conflicted path (measured — no `git rerere`
    /// subcommand takes a conflict id), so a forget needs a live path.
    /// A settled resolution has none, and the pane says so instead of
    /// offering an arm that cannot work.
    public var canForgetResolution: Bool { !entry.paths.isEmpty }

    @State private var forgetArmed = false
    @State private var forgetting = false
    @State private var forgotten: RerereForgetOutcome?
    @State private var forgetError: String?

    public init(
        repositoryPath: String,
        entry: Rerere.Entry,
        resolution: Rerere.Resolution?,
        resolutionError: String?,
        onForgotten: @escaping () -> Void = {}
    ) {
        self.repositoryPath = repositoryPath
        self.entry = entry
        self.resolution = resolution
        self.resolutionError = resolutionError
        self.onForgotten = onForgotten
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata
                Divider()
                diffContent
                Divider()
                forgetSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recorded rerere resolution")
                .font(.headline)
            Text(entry.conflictID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                if entry.paths.isEmpty {
                    Text("No live path is attributed to this resolution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.paths.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !entry.replayedPaths.isEmpty {
                    Text("Replayed: \(entry.replayedPaths.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Diff

    @ViewBuilder
    private var diffContent: some View {
        if let resolutionError {
            Text("Couldn't load the recorded resolution: \(resolutionError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let resolution {
            if resolution.diff.isEmpty {
                Text("The preimage and postimage are identical; nothing to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(resolution.diff, id: \.path) { file in
                        FileDiffView(file: file)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Forget

    @ViewBuilder
    private var forgetSection: some View {
        if let forgotten {
            VStack(alignment: .leading, spacing: 4) {
                Text("Resolution forgotten.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !forgotten.forgot.isEmpty {
                    Text("git reported: \(forgotten.forgot.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !canForgetResolution {
            Text("git identifies recorded resolutions by conflicted path, and no live path is "
                + "attributed to this one — there is no measured git surface that forgets a "
                + "resolution by conflict id, so it cannot be forgotten here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if forgetArmed {
                    Text("Forget this resolution? The same conflict will ask for a human "
                        + "resolution again instead of replaying it.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let forgetError {
                    Text("Couldn't forget the resolution: \(forgetError)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    if forgetArmed {
                        Button("Cancel") {
                            forgetArmed = false
                            forgetError = nil
                        }
                        .disabled(forgetting)
                        Button("Forget resolution", role: .destructive) {
                            Task { await forget() }
                        }
                        .disabled(forgetting)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Forget…") {
                            forgetArmed = true
                            forgetError = nil
                        }
                    }
                }
            }
        }
    }

    private func forget() async {
        forgetting = true
        defer { forgetting = false }
        do {
            forgotten = try await forgetRerereResolution(at: repositoryPath, entry.paths)
            forgetArmed = false
            onForgotten()
        } catch {
            forgetError = String(describing: error)
        }
    }
}

#Preview {
    RerereDetailView(
        repositoryPath: "/tmp/repo",
        entry: Rerere.Entry(
            conflictID: "650b3bb115602e8f349398d8d6c560baaef932e3",
            state: .recorded,
            paths: ["f.txt"],
            replayedPaths: []),
        resolution: nil,
        resolutionError: nil
    )
    .frame(width: 480, height: 360)
}
