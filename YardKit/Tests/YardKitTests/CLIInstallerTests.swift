// CLIInstallerTests.swift
//
// Tests for the CLIInstaller state machine (#0051). Everything runs against a
// fixture staged under the package's build/ directory — never /usr/local/bin,
// never the real ~/.local/bin, never as root, and every symlink the tests
// create lives inside the fixture. The privileged install step itself is
// #0222's; these tests cover the pure half that decides what it should do.

import Darwin
import Foundation
import Testing
@testable import YardKit

/// A staged bundle plus an empty destination directory, both under one
/// temporary root inside the package's build/ directory, removed when the
/// test's scope ends.
struct InstallerFixture: ~Copyable {
    let root: URL
    let bundle: URL
    let destinationDirectory: URL
    let legacyDirectory: URL

    var bundledCLI: URL {
        CLIInstaller.bundledCLI(inBundle: bundle)
    }

    var destination: URL {
        destinationDirectory.appending(path: ServiceNames.cliName, directoryHint: .notDirectory)
    }

    var legacyDestination: URL {
        legacyDirectory.appending(path: ServiceNames.cliName, directoryHint: .notDirectory)
    }

    init() throws {
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
        root = packageRoot
            .appending(path: "build/installer-fixtures/\(UUID().uuidString)", directoryHint: .isDirectory)
        bundle = root.appending(path: "Switchyard.app", directoryHint: .isDirectory)
        destinationDirectory = root.appending(path: "bin", directoryHint: .isDirectory)
        legacyDirectory = root.appending(path: "legacy-bin", directoryHint: .isDirectory)

        try fm.createDirectory(
            at: bundledCLI.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bundledCLI)
    }

    func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    func removeExecutableBits(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The four states, each constructed on disk against the staged fixture.
struct CLIInstallerStateTests {

    @Test func anEmptyDestinationReadsAsNotInstalled() throws {
        let fixture = try InstallerFixture()
        #expect(
            CLIInstaller.inspect(fixture.destination, expecting: fixture.bundledCLI)
                == .notInstalled
        )
    }

    @Test func aLinkIntoTheStagedBundleReadsAsInstalledHere() throws {
        let fixture = try InstallerFixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.destination, withDestinationURL: fixture.bundledCLI
        )
        #expect(
            CLIInstaller.inspect(fixture.destination, expecting: fixture.bundledCLI)
                == .installedHere
        )
    }

    @Test func aLinkSomewhereElseReportsWhereItPoints() throws {
        let fixture = try InstallerFixture()
        let other = fixture.root
            .appending(path: "Other.app/Contents/Resources/bin/switchyard", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: other)
        #expect(
            CLIInstaller.inspect(fixture.destination, expecting: fixture.bundledCLI)
                == .installedElsewhere(other.path)
        )
    }

    /// The case `fileExists(atPath:)` gets wrong, because it follows symlinks
    /// and so reports false for a link whose target is gone — reading as
    /// "nothing installed" while a broken command sits on `PATH`.
    @Test func aDanglingLinkIsStillALinkNotAnEmptyDestination() throws {
        let fixture = try InstallerFixture()
        let missing = fixture.root
            .appending(path: "Deleted.app/Contents/Resources/bin/switchyard", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: missing)

        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(
            CLIInstaller.inspect(fixture.destination, expecting: fixture.bundledCLI)
                == .installedElsewhere(missing.path)
        )
    }

    @Test func aRegularFileAtTheDestinationIsBlockedByFile() throws {
        let fixture = try InstallerFixture()
        try Data("not a symlink".utf8).write(to: fixture.destination)
        #expect(
            CLIInstaller.inspect(fixture.destination, expecting: fixture.bundledCLI)
                == .blockedByFile
        )
    }

    /// The embedded path is `Contents/` + `ServiceNames.cliBundleRelativePath`,
    /// derived from the constant so a rename cannot half-land.
    @Test func bundledCLILandsInsideContentsUsingTheServiceConstant() throws {
        let fixture = try InstallerFixture()
        #expect(
            fixture.bundledCLI.path
                == fixture.bundle.appending(path: "Contents/Resources/bin/switchyard").path
        )
        #expect(
            fixture.bundledCLI.path
                .hasSuffix("Contents/\(ServiceNames.cliBundleRelativePath)")
        )
    }

    // MARK: - Durability

    /// Pure string logic: the paths are constructed, nothing on disk is read.
    @Test func derivedDataAndBuildProductsBundlesAreNotDurable() {
        #expect(
            !CLIInstaller.isBundleDurable(URL(filePath: [
                "/Users/dev/Library/Developer/Xcode/DerivedData",
                "Switchyard-diamonds/Switchyard.app",
            ].joined(separator: "/")))
        )
        #expect(
            !CLIInstaller.isBundleDurable(URL(filePath: [
                "/Users/dev/Projects/Switchyard", "Build/Products/Debug/Switchyard.app",
            ].joined(separator: "/")))
        )
    }

    @Test func anApplicationsBundleIsDurable() {
        #expect(CLIInstaller.isBundleDurable(URL(filePath: "/Applications/Switchyard.app")))
    }

    @Test func theRefusalReportNamesTheBundleAndDestination() {
        let bundle = URL(filePath: "/Users/dev/DerivedData/Switchyard-diamonds/Switchyard.app")
        let report = CLIInstaller.buildDirectoryRefusalReport(
            bundle: bundle,
            destination: URL(filePath: ServiceNames.cliInstallPath)
        )
        #expect(report.severity == .warning)
        #expect(report.detail.contains(bundle.path))
        #expect(report.detail.contains(ServiceNames.cliInstallPath))
    }

    // MARK: - Privilege

    @Test func writableDestinationNeedsNoAuthentication() throws {
        let fixture = try InstallerFixture()
        #expect(!CLIInstaller.requiresAuthentication(forDestinationDirectory: fixture.destinationDirectory))
    }

    /// A `root:wheel`-style destination is the case that makes the real
    /// `/usr/local/bin` prompt. Skipped when the suite runs as root, which no
    /// execute bit can stop.
    @Test func unwritableDestinationRequiresAuthentication() throws {
        try #require(geteuid() != 0, "the execute bit cannot stop root")
        let fixture = try InstallerFixture()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: fixture.destinationDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.destinationDirectory.path
            )
        }
        #expect(CLIInstaller.requiresAuthentication(forDestinationDirectory: fixture.destinationDirectory))
    }
}

/// The escaping helper is the shell-injection boundary, so the exact output is
/// asserted rather than a property the wrong answer might also satisfy.
struct CLIInstallerQuotingTests {

    @Test func wrapsAnOrdinaryPathInSingleQuotes() {
        #expect(CLIInstaller.shellQuoted("/usr/local/bin") == "'/usr/local/bin'")
    }

    @Test func aSpaceInAPathCannotSplitTheCommand() {
        #expect(
            CLIInstaller.shellQuoted("/Users/Jane Doe/Applications/Switchyard.app")
                == "'/Users/Jane Doe/Applications/Switchyard.app'"
        )
    }

    /// The case that would otherwise end the quoted string early and let the
    /// rest of a crafted path run as shell.
    @Test func anEmbeddedSingleQuoteIsClosedEscapedAndReopened() {
        #expect(
            CLIInstaller.shellQuoted("/Users/Jane's Mac/switchyard")
                == #"'/Users/Jane'\''s Mac/switchyard'"#
        )
    }
}

/// The two reports that keep a correct install from looking like it did
/// nothing: a `PATH` entry earlier than the destination, and a leftover link
/// at the legacy location.
struct CLIInstallerShadowTests {

    @Test func anEarlierPathEntryHoldingTheCLIIsReported() throws {
        let fixture = try InstallerFixture()
        let shadowBin = fixture.root.appending(path: "shadow-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shadowBin, withIntermediateDirectories: true)
        let shadow = shadowBin.appending(path: ServiceNames.cliName, directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: shadow)
        try fixture.makeExecutable(shadow)

        let path = [shadowBin.path, fixture.destinationDirectory.path].joined(separator: ":")
        let report = try #require(
            CLIInstaller.pathShadowReport(
                environmentPath: path, destinationDirectory: fixture.destinationDirectory
            )
        )
        #expect(report.severity == .warning)
        #expect(report.detail.contains(shadow.path))
    }

    @Test func theDestinationItselfIsNotReportedAsAShadow() throws {
        let fixture = try InstallerFixture()
        try Data("#!/bin/sh\n".utf8).write(to: fixture.destination)
        try fixture.makeExecutable(fixture.destination)

        let path = ["/usr/bin", "/bin", fixture.destinationDirectory.path].joined(separator: ":")
        #expect(
            CLIInstaller.pathShadowReport(
                environmentPath: path, destinationDirectory: fixture.destinationDirectory
            ) == nil
        )
    }

    @Test func aCopyAfterTheDestinationOnPathIsNotReported() throws {
        let fixture = try InstallerFixture()
        let laterBin = fixture.root.appending(path: "later-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: laterBin, withIntermediateDirectories: true)
        let later = laterBin.appending(path: ServiceNames.cliName, directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: later)
        try fixture.makeExecutable(later)

        // The destination's own entry comes first, so nothing later shadows it.
        let path = [fixture.destinationDirectory.path, laterBin.path].joined(separator: ":")
        #expect(
            CLIInstaller.pathShadowReport(
                environmentPath: path, destinationDirectory: fixture.destinationDirectory
            ) == nil
        )
    }

    @Test func aNonExecutableMatchIsNotReported() throws {
        let fixture = try InstallerFixture()
        let shadowBin = fixture.root.appending(path: "shadow-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shadowBin, withIntermediateDirectories: true)
        let shadow = shadowBin.appending(path: ServiceNames.cliName, directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: shadow)
        try fixture.removeExecutableBits(shadow)

        let path = [shadowBin.path, fixture.destinationDirectory.path].joined(separator: ":")
        #expect(
            CLIInstaller.pathShadowReport(
                environmentPath: path, destinationDirectory: fixture.destinationDirectory
            ) == nil
        )
    }

    // MARK: - Legacy sweep

    @Test func aLegacyLinkIntoTheStagedBundleIsReported() throws {
        let fixture = try InstallerFixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.legacyDestination, withDestinationURL: fixture.bundledCLI
        )
        let report = try #require(
            CLIInstaller.legacySweepReport(
                bundledCLI: fixture.bundledCLI, legacyDestination: fixture.legacyDestination
            )
        )
        #expect(report.severity == .warning)
        #expect(report.detail.contains(fixture.legacyDestination.path))
    }

    @Test func aLegacyLinkIntoAnotherSwitchyardCopyIsStillReported() throws {
        let fixture = try InstallerFixture()
        let otherCopy = fixture.root
            .appending(path: "Backup/Switchyard.app/Contents/Resources/bin/switchyard", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(
            at: fixture.legacyDestination, withDestinationURL: otherCopy
        )
        let report = try #require(
            CLIInstaller.legacySweepReport(
                bundledCLI: fixture.bundledCLI, legacyDestination: fixture.legacyDestination
            )
        )
        #expect(report.severity == .warning)
    }

    @Test func aLegacyLinkToSomethingElseIsSilent() throws {
        let fixture = try InstallerFixture()
        let unrelated = fixture.root.appending(path: "somebody-elses-tool", directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(
            at: fixture.legacyDestination, withDestinationURL: unrelated
        )
        #expect(
            CLIInstaller.legacySweepReport(
                bundledCLI: fixture.bundledCLI, legacyDestination: fixture.legacyDestination
            ) == nil
        )
    }

    @Test func noLegacyLinkIsSilent() throws {
        let fixture = try InstallerFixture()
        #expect(
            CLIInstaller.legacySweepReport(
                bundledCLI: fixture.bundledCLI, legacyDestination: fixture.legacyDestination
            ) == nil
        )
    }
}
