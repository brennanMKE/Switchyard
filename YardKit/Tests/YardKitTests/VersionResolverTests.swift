// VersionResolverTests.swift

import Foundation
import Testing
@testable import YardKit

/// #0219 — `--version` reports the host app's version.
///
/// Both branches are covered against fake bundle layouts built on disk under
/// `build/version-fixtures` (scratch stays inside the worktree), each in a
/// UUID-stamped directory that is removed when the test finishes. The resolver
/// takes the executable URL as a parameter, so the fake layouts are pointed at
/// directly — no process spawning, no `Bundle.main` involvement.
struct VersionResolverTests {

    // MARK: - Fixture plumbing

    /// `build/version-fixtures/<stamp>` under the package root, derived from
    /// `#filePath` so it is absolute and stays inside the worktree.
    private static func makeFixtureRoot() -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/YardKitTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // package root
        return packageRoot
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("version-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Writes a fake app bundle and returns the URL of its entry point at
    /// `Contents/Resources/bin/switchyard` — the layout the installer uses.
    private static func makeBundle(
        root: URL,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        entryRelativePath: String = "Fake.app/Contents/Resources/bin/switchyard"
    ) throws -> URL {
        let entry = root.appendingPathComponent(entryRelativePath)
        let bin = entry.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("stub entry point".utf8).write(to: entry)

        if let shortVersion {
            let info: [String: Any] = buildVersion.map { build in
                ["CFBundleShortVersionString": shortVersion, "CFBundleVersion": build]
            } ?? ["CFBundleShortVersionString": shortVersion]
            let data = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            // The plist lives in the `Contents` directory the entry point sits
            // under, however deep below it the entry point is.
            let entryPath = entry.path
            let contentsRange = try #require(entryPath.range(of: "/Contents/"))
            let contentsPath = String(entryPath[..<contentsRange.lowerBound]) + "/Contents"
            try data.write(to: URL(fileURLWithPath: contentsPath)
                .appendingPathComponent("Info.plist"))
        }
        return entry
    }

    private static func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Bundled: plist drives the answer

    @Test("short version equal to build version reports the single string")
    func shortEqualsBuildReportsSingleString() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: "3.4", buildVersion: "3.4")

        #expect(VersionResolver.versionString(forExecutableAt: entry) == "3.4")
    }

    @Test("differing build version reports short version with build in parens")
    func differingBuildReportsShortInParens() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: "1.2", buildVersion: "345")

        #expect(VersionResolver.versionString(forExecutableAt: entry) == "1.2 (345)")
    }

    @Test("unsymlinked entry point at Contents/MacOS depth resolves too")
    func contentsMacOSDepthResolves() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(
            root: root, shortVersion: "9.9", buildVersion: "9.9",
            entryRelativePath: "Fake.app/Contents/MacOS/switchyard")

        #expect(VersionResolver.versionString(forExecutableAt: entry) == "9.9")
    }

    @Test("summary is the CLI name, a space, and the resolved version")
    func summaryPrefixesCliName() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: "5.6", buildVersion: "5.6")

        #expect(VersionResolver.cliVersionSummary(forExecutableAt: entry) == "switchyard 5.6")
    }

    // MARK: - Bundled through the installer's symlink

    @Test("symlinked entry point walks through the link into the bundle")
    func symlinkedEntryPointResolvesThroughTheLink() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: "5.6", buildVersion: "5.6")

        // The installed shape: the install-path entry point → …/Contents/Resources/bin/switchyard.
        let fakeBin = root.appendingPathComponent("link-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let link = fakeBin.appendingPathComponent("switchyard")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: entry)

        // Sanity: the link really is a link, or the test below proves nothing.
        // `destinationOfSymbolicLink` throws when the path is not a symlink,
        // so a plain directory here fails the test outright.
        let linked = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(!linked.isEmpty)

        #expect(VersionResolver.versionString(forExecutableAt: link) == "5.6")
    }

    // MARK: - Unbundled: the package version is the fallback

    @Test("executable in a plain directory falls back to the package version")
    func plainDirectoryFallsBackToPackageVersion() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(
            root: root, shortVersion: nil,
            entryRelativePath: "plain/switchyard")

        #expect(VersionResolver.versionString(forExecutableAt: entry) == YardKit.version)
    }

    @Test("a Contents directory without Info.plist falls back to the package version")
    func contentsWithoutPlistFallsBackToPackageVersion() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: nil)

        #expect(VersionResolver.versionString(forExecutableAt: entry) == YardKit.version)
    }

    @Test("a plist without a short-version key falls back to the package version")
    func plistWithoutShortVersionFallsBackToPackageVersion() throws {
        let root = Self.makeFixtureRoot()
        defer { Self.cleanup(root) }
        let entry = try Self.makeBundle(root: root, shortVersion: nil)

        // A plist that carries only the build number has nothing to report.
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "345"], format: .xml, options: 0)
        let contents = root.appendingPathComponent("Fake.app/Contents", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: contents.appendingPathComponent("Info.plist").path) == false)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        #expect(VersionResolver.versionString(forExecutableAt: entry) == YardKit.version)
    }
}
