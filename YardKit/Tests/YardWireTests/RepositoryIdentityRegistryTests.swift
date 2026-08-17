// RepositoryIdentityRegistryTests.swift — RepositoryIdentity (YardGit) crossing
// into RepositoryRegistry (YardKit) as a plain String (#0149). This target
// imports both packages, which is why these cross-boundary assertions live
// here rather than in either package's own test target.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("RepositoryIdentity crosses into RepositoryRegistry")
struct RepositoryIdentityRegistryTests {

    /// A unique directory that does not exist yet, under the resolved
    /// temporary directory. The registry must create it itself.
    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yard-registry-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func theLayoutConstantsAgreeWithServiceNames() {
        #expect(RepositoryLayout.stateDirectoryName == ServiceNames.repoStateDirectoryName)
        #expect(ServiceNames.journalMetadataRelativePath
            .hasPrefix(RepositoryLayout.stateDirectoryName + "/"))
    }

    @Test func aMovedRepositoryUpdatesItsRegistryRowInsteadOfAddingOne() throws {
        var fixture = try FixtureRepository()
        defer { fixture.destroy() }
        try fixture.build([.init("initial")])

        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let registry = RepositoryRegistry(directory: scratch)

        let originalContext = try WorktreeContext.resolve(path: fixture.url.path)
        let id = try RepositoryIdentity.resolve(in: originalContext)
        try registry.register(
            identity: id, commonDir: originalContext.commonDir,
            workingTree: originalContext.topLevel)

        let movedURL = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("yard-fixture-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: fixture.url, to: movedURL)
        defer { try? FileManager.default.removeItem(at: movedURL) }

        let movedContext = try WorktreeContext.resolve(path: movedURL.path)
        let movedID = try RepositoryIdentity.resolve(in: movedContext)
        #expect(movedID == id)

        let outcome = try registry.register(
            identity: movedID, commonDir: movedContext.commonDir,
            workingTree: movedContext.topLevel)

        #expect(outcome == .updated(previousCommonDir: originalContext.commonDir))

        let entries = try registry.entries()
        #expect(entries.count == 1)
    }
}
