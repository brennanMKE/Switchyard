// ServiceNamesTests.swift

import Foundation
import Testing
@testable import YardKit

struct ServiceNamesTests {

    /// Locates the repository root from this file, so the tests work wherever
    /// the package is checked out.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - State directory

    @Test func stateDirectoryHonorsXDGStateHome() {
        let url = ServiceNames.stateDirectory(
            environment: ["XDG_STATE_HOME": "/tmp/xdg"],
            homeDirectory: "/Users/nobody"
        )
        #expect(url.path == "/tmp/xdg/switchyard")
    }

    @Test func stateDirectoryFallsBackToLocalState() {
        let url = ServiceNames.stateDirectory(
            environment: [:],
            homeDirectory: "/Users/nobody"
        )
        #expect(url.path == "/Users/nobody/.local/state/switchyard")
    }

    /// An empty variable is not a set variable — otherwise `XDG_STATE_HOME=`
    /// in a CI environment silently resolves the state directory to
    /// `/switchyard`.
    @Test func emptyXDGStateHomeFallsBack() {
        let url = ServiceNames.stateDirectory(
            environment: ["XDG_STATE_HOME": ""],
            homeDirectory: "/Users/nobody"
        )
        #expect(url.path == "/Users/nobody/.local/state/switchyard")
    }

    // MARK: - Agreement with the Xcode project

    /// The bundle identifier appears in both `ServiceNames` and
    /// `project.pbxproj`. If they drift, `SMAppService` registration and the
    /// XPC handshake fail in ways that look like a broken transport.
    @Test func bundleIdentifierMatchesXcodeProject() throws {
        let pbxproj = repoRoot.appendingPathComponent("Switchyard.xcodeproj/project.pbxproj")
        let source = try String(contentsOf: pbxproj, encoding: .utf8)
        #expect(
            source.contains("PRODUCT_BUNDLE_IDENTIFIER = \(ServiceNames.bundleIdentifier);"),
            "project.pbxproj does not declare PRODUCT_BUNDLE_IDENTIFIER = \(ServiceNames.bundleIdentifier)"
        )
    }

    /// The Mach service name, agent plist name, and log subsystem are all
    /// derived from the bundle identifier in the guide. Keeping that
    /// relationship asserted means a rename cannot half-land.
    @Test func derivedNamesShareTheBundleIdentifier() {
        #expect(ServiceNames.machServiceName == "\(ServiceNames.bundleIdentifier).broker")
        #expect(ServiceNames.agentPlistName == "\(ServiceNames.machServiceName).plist")
        #expect(ServiceNames.logSubsystem == ServiceNames.bundleIdentifier)
    }

    @Test func cliInstallPathEndsWithTheCLIName() {
        #expect(ServiceNames.cliInstallPath.hasSuffix("/\(ServiceNames.cliName)"))
        #expect(ServiceNames.cliBundleRelativePath.hasSuffix("/\(ServiceNames.cliName)"))
    }

    @Test func journalRefPrefixIsOutsideHeadsAndTags() {
        #expect(ServiceNames.journalRefPrefix.hasPrefix("refs/switchyard/"))
        #expect(!ServiceNames.journalRefPrefix.hasPrefix("refs/heads/"))
        #expect(!ServiceNames.journalRefPrefix.hasPrefix("refs/tags/"))
        #expect(ServiceNames.journalRefPrefix.hasSuffix("/"))
    }

    // MARK: - Single source of truth

    /// Nothing outside `ServiceNames.swift` may hardcode these strings. This
    /// is the test that keeps the "single source of truth" claim true as the
    /// codebase grows, rather than true only on the day it was written.
    @Test func noOtherSwiftSourceHardcodesTheIdentifiers() throws {
        let forbidden = [ServiceNames.bundleIdentifier, ServiceNames.journalRefPrefix, ServiceNames.cliInstallPath]
        let fm = FileManager.default
        var offenders: [String] = []

        for root in ["YardKit/Sources", "YardKit/Tests", "Switchyard", "BrokerAgent"] {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                // The definitions live here, and this test names them literally.
                if url.lastPathComponent == "ServiceNames.swift" { continue }
                if url.lastPathComponent == "ServiceNamesTests.swift" { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                for needle in forbidden where source.contains(needle) {
                    offenders.append("\(url.lastPathComponent) contains \"\(needle)\"")
                }
            }
        }
        #expect(offenders.isEmpty, "hardcoded identifiers outside ServiceNames: \(offenders)")
    }
}
