// RemoteSyncTests.swift — Fetch, Pull and Push against a local bare remote (#0452-#0454)
//
// NO NETWORK. Every remote here is a bare repository in a temporary
// directory, reached by path. NO SIGNING KEY is created or used.

import Foundation
import Testing
@testable import YardGit

/// A fixture with one commit on `main`, pushed to a bare `origin` with the
/// upstream set. `bare` is removed by `destroy()`.
private struct Tracked {
    var repo: FixtureRepository
    let bare: URL

    init(_ format: FixtureRepository.RefFormat) throws {
        repo = try FixtureRepository(refFormat: format)
        try repo.build([.init("base", files: ["a.txt": "one\n"])])
        bare = try repo.addUpstream()
    }

    func destroy() {
        repo.destroy()
        try? FileManager.default.removeItem(at: bare)
    }

    var path: String { repo.url.path }

    /// The bare remote's `refs/heads/<branch>`, or nil when it has none.
    func remoteTip(_ branch: String = "main") throws -> String? {
        let out = try GitProcess().capture(
            ["rev-parse", "--verify", "-q", "refs/heads/\(branch)"], workingDirectory: bare.path)
        let oid = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.exitCode == 0 && !oid.isEmpty ? oid : nil
    }

    /// Commits `file` on `main` in a throwaway clone of the bare remote and
    /// pushes it, the way another machine would. Returns the new tip.
    @discardableResult
    func advanceRemote(file: String) throws -> String {
        let git = GitProcess()
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("yard-remote-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        try git.run(["clone", "-q", bare.path, clone.path])
        try (file + "\n").write(
            to: clone.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let identity = ["-c", "user.name=Other", "-c", "user.email=other@example.invalid",
                        "-c", "commit.gpgsign=false"]
        try git.run(["add", file], workingDirectory: clone.path)
        try git.run(identity + ["commit", "-q", "-m", "remote \(file)"], workingDirectory: clone.path)
        try git.run(["push", "-q", "origin", "HEAD:refs/heads/main"], workingDirectory: clone.path)
        return try remoteTip() ?? ""
    }

    /// Commits `file` locally, unstaged nothing left behind.
    func commitLocally(file: String) throws {
        try repo.writeUntracked([file: file + "\n"])
        try GitProcess().run(["add", file], workingDirectory: path)
        try GitProcess().run(["commit", "-q", "-m", "local \(file)"], workingDirectory: path)
    }

    func journalOperations() throws -> [String] {
        let ctx = try WorktreeContext.resolve(path: path)
        return try JournalList.list(in: ctx).items.compactMap { $0.metadata?.operation }
    }
}

// MARK: - Fetch (#0452)

@Test(arguments: FixtureRepository.RefFormat.supported())
func fetchMovesTheRemoteTrackingRefAndWritesOneFetchEntry(
    format: FixtureRepository.RefFormat
) async throws {
    let fixture = try Tracked(format)
    defer { fixture.destroy() }
    let localMain = try fixture.repo.revParse("refs/heads/main")
    let newTip = try fixture.advanceRemote(file: "b.txt")
    let before = try fixture.journalOperations()

    try await RemoteSync.fetch(at: fixture.path)

    #expect(try fixture.repo.revParse("refs/remotes/origin/main") == newTip)
    #expect(try fixture.repo.revParse("refs/heads/main") == localMain, "fetch must not move the branch")
    #expect(try fixture.journalOperations() == before + ["fetch"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoAfterFetchPutsTheRemoteTrackingRefBack(format: FixtureRepository.RefFormat) async throws {
    let fixture = try Tracked(format)
    defer { fixture.destroy() }
    let oldTracking = try fixture.repo.revParse("refs/remotes/origin/main")
    try fixture.advanceRemote(file: "b.txt")

    try await RemoteSync.fetch(at: fixture.path)
    try JournalUndo.undo(in: try await WorktreeContext.resolve(path: fixture.path))

    #expect(try fixture.repo.revParse("refs/remotes/origin/main") == oldTracking)
}

@Test func aFetchFromAMissingRemoteThrowsGitsStderr() async throws {
    let fixture = try Tracked(.files)
    defer { fixture.destroy() }
    try FileManager.default.removeItem(at: fixture.bare)

    await #expect {
        try await RemoteSync.fetch(at: fixture.path)
    } throws: { error in
        guard case let .exited(_, stderr, _) = error as? GitProcess.Failure else { return false }
        return stderr.contains("does not appear to be a git repository")
    }
}

@Test func everyRefusalIsARepositoryError() {
    let all: [RemoteSync.Refusal] = [
        .detachedHead, .noUpstream(branch: "b"), .noRemote,
        .ambiguousRemote(["a", "b"]), .localUpstream(branch: "b"),
    ]
    for refusal in all {
        #expect(refusal.exitClass == .repositoryError)
        #expect(!refusal.description.isEmpty)
    }
}

@Test func remoteNamesListsTheConfiguredRemotes() async throws {
    let fixture = try Tracked(.files)
    defer { fixture.destroy() }
    #expect(try await RemoteSync.remoteNames(at: fixture.path) == ["origin"])
    try await GitProcess().run(["remote", "add", "backup", "/nonexistent/b.git"], workingDirectory: fixture.path)
    #expect(try await RemoteSync.remoteNames(at: fixture.path) == ["backup", "origin"])
    try await GitProcess().run(["remote", "remove", "backup"], workingDirectory: fixture.path)
    try await GitProcess().run(["remote", "remove", "origin"], workingDirectory: fixture.path)
    #expect(try await RemoteSync.remoteNames(at: fixture.path) == [])
}

// MARK: - Pull (#0453)

@Test(arguments: FixtureRepository.RefFormat.supported())
func pullFastForwardsTheBranchAndTheWorktree(format: FixtureRepository.RefFormat) async throws {
    let fixture = try Tracked(format)
    defer { fixture.destroy() }
    let old = try fixture.repo.revParse("HEAD")
    let newTip = try fixture.advanceRemote(file: "b.txt")

    let result = try await RemoteSync.pull(at: fixture.path)

    #expect(result == .fastForwarded(from: old, to: newTip))
    #expect(try fixture.repo.revParse("HEAD") == newTip)
    #expect(FileManager.default.fileExists(atPath: fixture.path + "/b.txt"))
    #expect(try await gitStatus(at: fixture.path).entries.isEmpty)
    #expect(try fixture.journalOperations().last == "pull")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func undoAfterPullPutsTheBranchTheWorktreeAndTheTrackingRefBack(
    format: FixtureRepository.RefFormat
) async throws {
    let fixture = try Tracked(format)
    defer { fixture.destroy() }
    let old = try fixture.repo.revParse("HEAD")
    try fixture.advanceRemote(file: "b.txt")

    try await RemoteSync.pull(at: fixture.path)
    try JournalUndo.undo(in: try await WorktreeContext.resolve(path: fixture.path))

    #expect(try fixture.repo.revParse("HEAD") == old)
    #expect(try fixture.repo.revParse("refs/remotes/origin/main") == old)
    #expect(!FileManager.default.fileExists(atPath: fixture.path + "/b.txt"),
            "undo must take the pulled file back out of the worktree")
    #expect(try await gitStatus(at: fixture.path).entries.isEmpty)
}

@Test func pullWhenUpToDateReportsUpToDate() async throws {
    let fixture = try Tracked(.files)
    defer { fixture.destroy() }
    #expect(try await RemoteSync.pull(at: fixture.path) == .upToDate)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func aDivergedPullRefusesWithGitsStderrAndLeavesTheBranch(
    format: FixtureRepository.RefFormat
) async throws {
    let fixture = try Tracked(format)
    defer { fixture.destroy() }
    try fixture.advanceRemote(file: "b.txt")
    try fixture.commitLocally(file: "c.txt")
    let local = try fixture.repo.revParse("HEAD")
    // A `git pull` would rebase with this set; the pull must not.
    try await GitProcess().run(["config", "pull.rebase", "true"], workingDirectory: fixture.path)

    await #expect {
        try await RemoteSync.pull(at: fixture.path)
    } throws: { error in
        guard case let .exited(_, stderr, _) = error as? GitProcess.Failure else { return false }
        return stderr.contains("Not possible to fast-forward")
    }
    #expect(try fixture.repo.revParse("HEAD") == local)
}

@Test func pullRefusesADetachedHeadAndABranchWithNoUpstreamWritingNothing() async throws {
    let fixture = try Tracked(.files)
    defer { fixture.destroy() }
    let before = try fixture.journalOperations()

    try await GitProcess().run(["switch", "-q", "-c", "loner"], workingDirectory: fixture.path)
    await #expect(throws: RemoteSync.Refusal.noUpstream(branch: "loner")) {
        try await RemoteSync.pull(at: fixture.path)
    }
    try fixture.repo.checkoutDetached(try fixture.repo.revParse("HEAD"))
    await #expect(throws: RemoteSync.Refusal.detachedHead) {
        try await RemoteSync.pull(at: fixture.path)
    }
    #expect(try fixture.journalOperations() == before)
}
