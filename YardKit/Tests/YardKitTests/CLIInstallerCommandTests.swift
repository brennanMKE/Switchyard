// CLIInstallerCommandTests.swift
//
// Tests for the privileged ACT half of the installer (#0222): the exact
// shell strings the app will run as root, the AppleScript error-number
// classifier, and the durability refusal that gates the install action.
// Nothing here executes a command or touches anything outside the package's
// build/ fixture tree — the strings are returned, not run, which is the
// whole design.

import Foundation
import Testing
@testable import YardKit

struct CLIInstallerCommandTests {

    // MARK: - installCommand

    @Test func installCommandWithLegacySweepsItBeforeCreatingTheLink() throws {
        let fixture = try InstallerFixture()
        let command = CLIInstaller.installCommand(
            bundledCLI: fixture.bundledCLI,
            destination: fixture.destination,
            legacyDestination: fixture.legacyDestination
        )
        // Hand-apostrophised expected string — independent of shellQuoted, so
        // dropping the quoting from the implementation cannot pass this test.
        #expect(
            command
                == "mkdir -p '\(fixture.destinationDirectory.path)'"
                    + " && rm -f '\(fixture.legacyDestination.path)'"
                    + " && ln -sfn '\(fixture.bundledCLI.path)' '\(fixture.destination.path)'"
        )
        // The sweep must precede the link: the legacy location sits earlier
        // on PATH, and the string's order is what puts the removal first.
        let sweepEnd = try #require(command.range(of: "rm -f")?.upperBound)
        let linkStart = try #require(command.range(of: "ln -sfn")?.lowerBound)
        #expect(sweepEnd < linkStart)
    }

    @Test func installCommandWithoutLegacyOmitsTheSweepEntirely() throws {
        let fixture = try InstallerFixture()
        let command = CLIInstaller.installCommand(
            bundledCLI: fixture.bundledCLI,
            destination: fixture.destination,
            legacyDestination: nil
        )
        #expect(
            command
                == "mkdir -p '\(fixture.destinationDirectory.path)'"
                    + " && ln -sfn '\(fixture.bundledCLI.path)' '\(fixture.destination.path)'"
        )
    }

    @Test func installCommandShellQuotesSpacesAndEmbeddedSingleQuotes() {
        // A home directory with a space and an apostrophe — the injection
        // boundary. The embedded quote must come back as the '\'' escape, or
        // the command string closes early and the remainder runs as shell.
        // The destination comes from ServiceNames: this file hardcodes only
        // the adversarial paths, never the install location.
        let bundled = URL(
            fileURLWithPath:
                "/Users/Ja'mes Mac/Applications/Switchyard.app/Contents/Resources/bin/switchyard"
        )
        let destination = URL(
            filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory
        )
        let legacy = URL(fileURLWithPath: "/Users/Ja'mes/.local/bin/switchyard")

        let command = CLIInstaller.installCommand(
            bundledCLI: bundled, destination: destination, legacyDestination: legacy
        )
        #expect(
            command
                == "mkdir -p '\(destination.deletingLastPathComponent().path)'"
                    + " && rm -f '/Users/Ja'\\''mes/.local/bin/switchyard'"
                    + " && ln -sfn '/Users/Ja'\\''mes Mac/Applications/Switchyard.app"
                        + "/Contents/Resources/bin/switchyard' '\(destination.path)'"
        )
    }

    // MARK: - uninstallCommand

    @Test func uninstallCommandRemovesBothLinksLegacyFirst() throws {
        let fixture = try InstallerFixture()
        let command = CLIInstaller.uninstallCommand(
            destination: fixture.destination,
            legacyDestination: fixture.legacyDestination
        )
        #expect(
            command
                == "rm -f '\(fixture.legacyDestination.path)' '\(fixture.destination.path)'"
        )
    }

    @Test func uninstallCommandWithoutLegacyRemovesOnlyTheDestination() {
        let command = CLIInstaller.uninstallCommand(
            destination: URL(fileURLWithPath: ServiceNames.cliInstallPath),
            legacyDestination: nil
        )
        #expect(command == "rm -f '\(ServiceNames.cliInstallPath)'")
    }

    // MARK: - The AppleScript error-number classifier

    @Test func aCancelledAuthenticationDialogIsNotAFailure() {
        // -128 is userCanceledErr: a user decision, never an error.
        #expect(CLIInstaller.authOutcome(fromAppleScriptError: -128) == .cancelled)
        // Even when macOS attaches a message, a cancel stays a cancel.
        #expect(
            CLIInstaller.authOutcome(fromAppleScriptError: -128, message: "User canceled.")
                == .cancelled
        )
    }

    @Test func anyOtherAppleScriptErrorIsAFailureCarryingTheMessage() {
        #expect(
            CLIInstaller.authOutcome(fromAppleScriptError: 1, message: "command not found")
                == .failed("command not found")
        )
        // No message from macOS: the failure still names the error number.
        #expect(
            CLIInstaller.authOutcome(fromAppleScriptError: 1708)
                == .failed("AppleScript error 1708")
        )
    }

    // MARK: - The durability precondition

    @Test func aBuildDirectoryBundleRefusesTheInstallWithTheRefusalReport() throws {
        let derived = URL(
            fileURLWithPath:
                "/Users/me/Library/Developer/Xcode/DerivedData/Switchyard-abc"
                    + "/Build/Products/Debug/Switchyard.app"
        )
        let destination = URL(
            filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory
        )
        let report = try #require(
            CLIInstaller.installPreconditionReport(bundle: derived, destination: destination)
        )
        #expect(
            report
                == CLIInstaller.buildDirectoryRefusalReport(
                    bundle: derived, destination: destination
                )
        )
        #expect(report.severity == .warning)
        #expect(report.detail.contains(derived.path))
    }

    @Test func aNormalApplicationBundlePassesTheInstallPrecondition() throws {
        let fixture = try InstallerFixture()
        #expect(
            CLIInstaller.installPreconditionReport(
                bundle: fixture.bundle, destination: fixture.destination
            ) == nil
        )
    }
}
