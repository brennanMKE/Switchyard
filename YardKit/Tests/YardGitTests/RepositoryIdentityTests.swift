// RepositoryIdentityTests.swift — #0149

import Foundation
import Testing
@testable import YardGit

@Suite("RepositoryIdentity")
struct RepositoryIdentityTests {

    @Test func resolveCreatesAnIdAndTheSecondCallReturnsIt() throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([.init("initial")])

        let context = try WorktreeContext.resolve(path: fixture.url.path)

        let first = try RepositoryIdentity.resolve(in: context)
        let second = try RepositoryIdentity.resolve(in: context)
        #expect(!first.isEmpty)
        #expect(first == second)

        let fm = FileManager.default
        let path = context.commonDir + "/" + RepositoryLayout.repositoryIDRelativePath
        #expect(fm.fileExists(atPath: path))

        let fileAttributes = try fm.attributesOfItem(atPath: path)
        let filePosix = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(filePosix.uint16Value & 0o777 == 0o600)

        let directory = RepositoryLayout.stateDirectory(in: context)
        let dirAttributes = try fm.attributesOfItem(atPath: directory)
        let dirPosix = try #require(dirAttributes[.posixPermissions] as? NSNumber)
        #expect(dirPosix.uint16Value & 0o777 == 0o700)
    }

    @Test func aLinkedWorktreeResolvesTheSameId() throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([.init("initial")])

        let mainContext = try WorktreeContext.resolve(path: fixture.url.path)
        let mainID = try RepositoryIdentity.resolve(in: mainContext)

        let linkedURL = try fixture.addWorktree(named: "linked", branch: "issue/linked")
        let linkedContext = try WorktreeContext.resolve(path: linkedURL.path)
        let linkedID = try RepositoryIdentity.resolve(in: linkedContext)

        #expect(mainID == linkedID)
    }

    @Test func theIdSurvivesAMoveOnDisk() throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([.init("initial")])

        let originalContext = try WorktreeContext.resolve(path: fixture.url.path)
        let originalID = try RepositoryIdentity.resolve(in: originalContext)

        let movedURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("yard-fixture-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: fixture.url, to: movedURL)
        defer { try? FileManager.default.removeItem(at: movedURL) }

        let movedContext = try WorktreeContext.resolve(path: movedURL.path)
        let movedID = try RepositoryIdentity.resolve(in: movedContext)

        #expect(movedID == originalID)
    }

    @Test func anEmptyIdFileIsReplaced() throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([.init("initial")])

        let context = try WorktreeContext.resolve(path: fixture.url.path)
        let directory = RepositoryLayout.stateDirectory(in: context)
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = context.commonDir + "/" + RepositoryLayout.repositoryIDRelativePath
        try Data().write(to: URL(fileURLWithPath: path))

        let resolved = try RepositoryIdentity.resolve(in: context)
        #expect(!resolved.isEmpty)

        let fileContents = try #require(FileManager.default.contents(atPath: path))
        let onDisk = try #require(String(data: fileContents, encoding: .utf8))
        #expect(onDisk.trimmingCharacters(in: .whitespacesAndNewlines) == resolved)
    }
}
