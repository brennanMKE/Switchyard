// RemoteRenameTests.swift — rename and remove a remote; Undo refuses both (#0528)
//
// NO NETWORK. Every remote is a bare repository in a temporary directory.

import Foundation
import Testing
@testable import YardGit

/// `main` pushed to a bare `origin` with its upstream set, plus a local
/// `topic` with no upstream.
private struct TwoBranches {
    var repo: FixtureRepository
    let bare: URL

    init(_ format: FixtureRepository.RefFormat) throws {
        repo = try FixtureRepository(refFormat: format)
        try repo.build([.init("base", files: ["a.txt": "one\n"])])
        try repo.branch("topic")
        bare = try repo.addUpstream()
    }

    var path: String { repo.url.path }

    func destroy() {
        repo.destroy()
        try? FileManager.default.removeItem(at: bare)
    }

    func config(_ key: String) throws -> String? {
        try RemoteSync.configValue(key, at: path, git: GitProcess())
    }

    func operations() throws -> [String] {
        try JournalList.list(in: WorktreeContext.resolve(path: path)).items.compactMap { $0.metadata?.operation }
    }

    func remoteRefs() throws -> [String] {
        try GitProcess().run(["for-each-ref", "--format=%(refname)", "refs/remotes/"], workingDirectory: path).lines
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func removalImpactListsTrackingBranchesAndUpstreamsWithoutHEAD(format: FixtureRepository.RefFormat) throws {
    let fixture = try TwoBranches(format)
    defer { fixture.destroy() }
    try GitProcess().run(["remote", "set-head", "origin", "main"], workingDirectory: fixture.path)
    #expect(try fixture.remoteRefs() == ["refs/remotes/origin/HEAD", "refs/remotes/origin/main"])

    let impact = try RemoteConfig.removalImpact(of: "origin", at: fixture.path)

    #expect(impact == .init(trackingBranches: ["origin/main"], upstreamOf: ["main"]))
    #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try RemoteConfig.removalImpact(of: "nope", at: fixture.path)
    }
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func renameMovesRefsAndUpstreamsWritesOneEntryAndUndoRefusesIt(
    format: FixtureRepository.RefFormat
) throws {
    let fixture = try TwoBranches(format)
    defer { fixture.destroy() }
    let ctx = try WorktreeContext.resolve(path: fixture.path)
    try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
    let before = try fixture.operations()

    try RemoteConfig.rename("origin", to: "upstream", at: fixture.path)

    #expect(try RemoteConfig.list(at: fixture.path).map(\.name) == ["upstream"])
    #expect(try fixture.remoteRefs() == ["refs/remotes/upstream/main"])
    #expect(try fixture.config("branch.main.remote") == "upstream")
    #expect(try fixture.operations() == before + [RemoteConfig.renameOperation])

    let entry = try #require(try JournalAnchor.list(in: ctx).last)
    let refused = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(in: ctx) }
    #expect(try #require(refused) == .remoteChangeNotUndoable(
        operation: RemoteConfig.renameOperation, entry: entry.id, requested: 1, available: 0))
    #expect(try fixture.remoteRefs() == ["refs/remotes/upstream/main"], "the refused undo changed refs")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func removeDeletesRefsAndUpstreamsWritesOneEntryAndUndoRefusesIt(
    format: FixtureRepository.RefFormat
) throws {
    let fixture = try TwoBranches(format)
    defer { fixture.destroy() }
    let ctx = try WorktreeContext.resolve(path: fixture.path)
    try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
    let before = try fixture.operations()

    try RemoteConfig.remove("origin", at: fixture.path)

    #expect(try RemoteConfig.list(at: fixture.path).isEmpty)
    #expect(try fixture.remoteRefs().isEmpty)
    #expect(try fixture.config("branch.main.remote") == nil)
    #expect(try fixture.config("branch.main.merge") == nil)
    #expect(try fixture.operations() == before + [RemoteConfig.removeOperation])

    let entry = try #require(try JournalAnchor.list(in: ctx).last)
    let refused = #expect(throws: JournalUndo.Error.self) { try JournalUndo.undo(in: ctx) }
    #expect(try #require(refused) == .remoteChangeNotUndoable(
        operation: RemoteConfig.removeOperation, entry: entry.id, requested: 1, available: 0))
    #expect(try fixture.remoteRefs().isEmpty, "the refused undo brought remote-tracking refs back")
    #expect(try #require(refused).exitClass == .repositoryError)
}

@Test func renameAndRemoveRefuseBeforeGitRunsAndWriteNothing() throws {
    let fixture = try TwoBranches(.files)
    defer { fixture.destroy() }
    try RemoteConfig.add(name: "backup", url: fixture.bare.path, at: fixture.path)
    let before = try fixture.operations()

    #expect(throws: RemoteConfig.Refusal.nameInUse("backup")) {
        try RemoteConfig.rename("origin", to: "backup", at: fixture.path)
    }
    #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try RemoteConfig.rename("nope", to: "other", at: fixture.path)
    }
    // `git remote rename` itself accepts this (measured); Switchyard does not.
    #expect(throws: RemoteConfig.Refusal.nestedName("backup/x", existing: "backup")) {
        try RemoteConfig.rename("origin", to: "backup/x", at: fixture.path)
    }
    #expect(throws: RemoteConfig.Refusal.invalidName("a b", reason: "A remote name can’t contain spaces.")) {
        try RemoteConfig.rename("origin", to: "a b", at: fixture.path)
    }
    #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try RemoteConfig.remove("nope", at: fixture.path)
    }
    #expect(try RemoteConfig.list(at: fixture.path).map(\.name) == ["backup", "origin"])
    #expect(try fixture.operations() == before)
}
