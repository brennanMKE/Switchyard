// RemoteFetchPruneTests.swift — Fetch and Prune one remote (#0529)
//
// NO NETWORK. Every remote is a bare repository in a temporary directory.

import Foundation
import Testing
@testable import YardGit

/// `main` pushed to two bare remotes, `origin` and `backup`, both fetched.
private struct TwoRemotes {
    var repo: FixtureRepository
    let origin: URL
    let backup: URL

    init(_ format: FixtureRepository.RefFormat) throws {
        repo = try FixtureRepository(refFormat: format)
        try repo.build([.init("base", files: ["a.txt": "one\n"])])
        origin = try repo.addUpstream()
        backup = try repo.addUpstream(remoteName: "backup")
    }

    var path: String { repo.url.path }

    func destroy() {
        repo.destroy()
        try? FileManager.default.removeItem(at: origin)
        try? FileManager.default.removeItem(at: backup)
    }

    /// Creates `refs/heads/<branch>` in `bare` at local `main`.
    func pushBranch(_ branch: String, to remote: String) throws {
        try GitProcess().run(["push", "-q", remote, "main:refs/heads/\(branch)"], workingDirectory: path)
    }

    func deleteBranch(_ branch: String, in bare: URL) throws {
        try GitProcess().run(["update-ref", "-d", "refs/heads/\(branch)"], workingDirectory: bare.path)
    }

    func has(_ ref: String) throws -> Bool {
        try GitProcess().capture(["rev-parse", "--verify", "-q", ref], workingDirectory: path).exitCode == 0
    }

    func operations() throws -> [String] {
        try JournalList.list(in: WorktreeContext.resolve(path: path)).items.compactMap { $0.metadata?.operation }
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func fetchOneRemoteLeavesTheOtherAloneAndWritesOneFetchEntry(
    format: FixtureRepository.RefFormat
) async throws {
    let fixture = try TwoRemotes(format)
    defer { fixture.destroy() }
    // A branch each remote has and neither remote-tracking namespace does:
    // pushing by refspec to a bare repo updates no remote-tracking ref.
    try await GitProcess().run(["push", "-q", fixture.origin.path, "main:refs/heads/new-o"], workingDirectory: fixture.path)
    try await GitProcess().run(["push", "-q", fixture.backup.path, "main:refs/heads/new-b"], workingDirectory: fixture.path)
    let before = try fixture.operations()

    try await RemoteSync.fetch(remote: "backup", at: fixture.path)

    #expect(try fixture.has("refs/remotes/backup/new-b"))
    #expect(try !fixture.has("refs/remotes/origin/new-o"), "Fetch “backup” fetched origin too")
    #expect(try fixture.operations() == before + ["fetch"])
}

@Test func fetchAnUnknownRemoteRefusesAndWritesNothing() async throws {
    let fixture = try TwoRemotes(.files)
    defer { fixture.destroy() }
    let before = try fixture.operations()

    await #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try await RemoteSync.fetch(remote: "nope", at: fixture.path)
    }
    await #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try await RemoteSync.prune(remote: "nope", at: fixture.path)
    }
    #expect(try fixture.operations() == before)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func pruneDeletesOnlyStaleBranchesAndUndoPruneBringsThemBack(
    format: FixtureRepository.RefFormat
) async throws {
    let fixture = try TwoRemotes(format)
    defer { fixture.destroy() }
    try fixture.pushBranch("gone", to: "origin")
    try fixture.pushBranch("gone", to: "backup")
    try fixture.deleteBranch("gone", in: fixture.origin)
    try fixture.deleteBranch("gone", in: fixture.backup)
    #expect(try fixture.has("refs/remotes/origin/gone"))
    let before = try fixture.operations()

    try await RemoteSync.prune(remote: "origin", at: fixture.path)

    #expect(try !fixture.has("refs/remotes/origin/gone"))
    #expect(try fixture.has("refs/remotes/origin/main"))
    #expect(try fixture.has("refs/remotes/backup/gone"), "Prune “origin” pruned backup too")
    #expect(try fixture.operations() == before + [RemoteSync.pruneOperation])

    try JournalUndo.undo(in: try await WorktreeContext.resolve(path: fixture.path))
    #expect(try fixture.has("refs/remotes/origin/gone"), "Undo Prune did not bring the branch back")
}
