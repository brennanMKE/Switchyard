// RemoteActionsTests.swift — remote management's data layer (#0530)

import Foundation
import Testing
import YardGit
import YardUI

@Suite("RemoteActions")
struct RemoteActionsTests {

    @Test func onlyAnAddWithItsCheckboxOnFetchesAfterwards() {
        #expect(RemoteAction.add(name: "b", url: "/x", fetch: true).followUp == .fetch(remote: "b"))
        #expect(RemoteAction.add(name: "b", url: "/x", fetch: false).followUp == nil)
        #expect(RemoteAction.fetch(remote: "b").followUp == nil)
    }

    @Test func onlyFetchAndPruneUseTheNetwork() {
        let all: [RemoteAction] = [
            .add(name: "b", url: "/x", fetch: true), .setURL(remote: "b", url: "/y"),
            .rename(remote: "b", to: "c"), .remove(remote: "b"), .fetch(remote: "b"), .prune(remote: "b"),
        ]
        #expect(all.filter(\.usesNetwork) == [.fetch(remote: "b"), .prune(remote: "b")])
        #expect(RemoteAction.prune(remote: "origin").progressLabel == "Pruning “origin”…")
    }

    @Test func aFailureShowsTheRefusalOrGitsStderrWithoutHintsAndACancelShowsNothing() throws {
        let refusal = RemoteAction.rename(remote: "a", to: "b")
            .failure(for: RemoteConfig.Refusal.nameInUse("b"))
        #expect(refusal == CommitActionFailure(
            title: "Couldn’t Rename Remote",
            message: "A remote named “b” already exists. Nothing was changed."))

        let stderr = "fatal: could not read Username for 'https://example.invalid': terminal prompts disabled\nhint: try this\n"
        let git = try #require(RemoteAction.fetch(remote: "gh")
            .failure(for: GitProcess.Failure.exited(code: 128, stderr: stderr, arguments: ["fetch"])))
        #expect(git.title == "Couldn’t Fetch “gh”")
        #expect(git.message.hasPrefix("fatal: could not read Username"))
        #expect(!git.message.contains("hint:"))
        #expect(git.message.contains("Switchyard never asks for a password."))

        #expect(RemoteAction.prune(remote: "gh").failure(for: CancellationError()) == nil)
    }

    @Test func theSheetsNameMessageFollowsGitAndTheExistingRemotes() {
        let existing = ["origin", "backup"]
        #expect(RemoteSheetRules.nameMessage("", existing: existing) == "Enter a name.")
        #expect(RemoteSheetRules.nameMessage("a b", existing: existing) == "A remote name can’t contain spaces.")
        #expect(RemoteSheetRules.nameMessage("origin", existing: existing)
                == "A remote named “origin” already exists.")
        #expect(RemoteSheetRules.nameMessage("origin/x", existing: existing)
                == "Can’t be used beside the remote “origin”.")
        #expect(RemoteSheetRules.nameMessage("mirror", existing: existing) == nil)
        // A rename: the remote's own name is not a conflict, but not a change either.
        #expect(RemoteSheetRules.nameMessage("backup", existing: existing, renaming: "backup")
                == "Enter a new name.")
        #expect(RemoteSheetRules.nameMessage("backup-2", existing: existing, renaming: "backup") == nil)
        // Under its own name is fine for a rename: the old name is gone afterwards (git
        // renames origin → origin/x cleanly, measured).
        #expect(RemoteSheetRules.nameMessage("backup/x", existing: existing, renaming: "backup") == nil)
        #expect(RemoteSheetRules.urlMessage("  ") == "Enter a URL.")
        #expect(RemoteSheetRules.urlMessage(" /srv/x.git ") == nil)
    }

    @Test func theRemovalConfirmationSaysWhatGoesWithTheRemote() {
        let many = RemoteRemovalConfirmation(remote: "origin", impact: .init(
            trackingBranches: ["origin/a", "origin/b", "origin/c", "origin/d"], upstreamOf: ["a", "b"]))
        #expect(many.title == "Remove the remote “origin”?")
        #expect(many.message == "Its 4 remote-tracking branches (origin/a, origin/b, origin/c and 1 more) "
            + "are deleted. 2 branches stop tracking it: a, b. Local branches and commits are kept. "
            + "Edit ▸ Undo can’t undo this. Add the remote again and fetch to get its branches back.")

        let one = RemoteRemovalConfirmation(remote: "b", impact: .init(
            trackingBranches: ["b/main"], upstreamOf: ["main"]))
        #expect(one.message.hasPrefix(
            "Its remote-tracking branch b/main is deleted. The branch main stops tracking it."))

        let none = RemoteRemovalConfirmation(remote: "b", impact: .init(trackingBranches: [], upstreamOf: []))
        #expect(none.message.hasPrefix("It has no remote-tracking branches. Local branches"))
    }

    @Test func renameAndRemoveCantBeUndoneAndPruneCan() {
        #expect(JournalMenuTitles.undo(operation: RemoteConfig.renameOperation) == "Can’t Undo Rename Remote")
        #expect(JournalMenuTitles.undo(operation: RemoteConfig.removeOperation) == "Can’t Undo Remove Remote")
        #expect(JournalMenu.undoBlocked(operation: RemoteConfig.removeOperation))
        #expect(!JournalMenu.undoBlocked(operation: RemoteSync.pruneOperation))
        #expect(JournalMenuTitles.undo(operation: RemoteSync.pruneOperation) == "Undo Prune")
        #expect(JournalMenuTitles.undo(operation: "push") == "Can’t Undo Push")
    }
}

/// `loadRepositorySidebar` carries the configured remotes. No network: the
/// remote is a bare repository in a temporary directory.
@Test func theSidebarLoadCarriesTheConfiguredRemotes() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let bare = try repo.addUpstream()
    defer { try? FileManager.default.removeItem(at: bare) }

    let summary = try await loadRepositorySidebar(at: repo.url.path)

    #expect(summary.remotes == [.init(name: "origin", fetchURL: bare.path, pushURLs: [bare.path])])
}
