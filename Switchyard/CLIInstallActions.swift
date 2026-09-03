// CLIInstallActions.swift
//
// #0222: the privileged half of the CLI install. The package's CLIInstaller
// RETURNS the exact shell command and classifies outcomes; this file is the
// app target code that ACTS — the in-process NSAppleScript runner and the
// install/uninstall flows behind the File menu items.
//
// The runner lives here, not in the package, because `NSAppleScript` needs
// AppKit and the YardKit target is deliberately Foundation-only; the pure
// classifier it feeds (`CLIInstaller.authOutcome`) stays testable in the
// package. The shape, the in-process rationale, and the -128 discrimination
// follow RemoteControl's BridgeKit installer and its docs §4–§5 (MIT, same
// author), reimplemented rather than copied.

import AppKit
import YardKit

/// The install/uninstall actions behind File ▸ Install / Uninstall Command
/// Line Tool. Every decision is made by `CLIInstaller` (the package's state
/// machine); this type only carries its values into the dialog, the command,
/// and the alert.
@MainActor
enum CLIInstallActions {

    // MARK: - The runner

    /// Runs `command` as root through the system's own authentication
    /// dialog, and returns how the run ended.
    ///
    /// In-process `NSAppleScript`, never a child `osascript`: in-process,
    /// macOS brands the dialog with Switchyard's icon and name instead of
    /// Script Editor's, and the password is collected by the system — it
    /// never passes through this app. `reason` is the dialog's
    /// `with prompt` text; without it the dialog asks for a password while
    /// explaining nothing.
    ///
    /// NSAppleScript must run on the main thread and blocks synchronously
    /// through the dialog — which is why nothing here offers a spinner; one
    /// could never render.
    ///
    /// - Returns: `nil` when the command succeeded; `.cancelled` when the
    ///   user dismissed the dialog (a user decision — present nothing);
    ///   `.failed(_)` with the AppleScript error message otherwise.
    static func runWithAdministratorPrivileges(
        command: String,
        reason: String
    ) -> CLIInstaller.AuthOutcome? {
        let escaped = appleScriptQuoted(command)
        let escapedReason = appleScriptQuoted(reason)
        let source = "do shell script \"\(escaped)\" "
            + "with prompt \"\(escapedReason)\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not create the authentication script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return nil }
        let number = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = errorInfo[NSAppleScript.errorMessage] as? String
        return CLIInstaller.authOutcome(fromAppleScriptError: number, message: message)
    }

    /// Escapes for interpolation into an AppleScript string literal.
    private static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - The acts

    /// File ▸ Install Command Line Tool… — decides, builds the privileged
    /// command, runs it, and returns the one report to present, or `nil`
    /// when there is nothing to say. A cancelled authentication dialog is a
    /// user decision: it surfaces as nothing, never an alert.
    @discardableResult
    static func install() -> CLIInstaller.Report? {
        let bundle = Bundle.main.bundleURL
        let bundledCLI = CLIInstaller.bundledCLI(inBundle: bundle)
        let destination = URL(
            filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory
        )

        // Refuse first: a link into a build directory is doomed on the next
        // clean, and the state machine declines before any dialog appears.
        if let refusal = CLIInstaller.installPreconditionReport(
            bundle: bundle, destination: destination
        ) {
            return refusal
        }

        // A real file at the destination is never clobbered — `ln -sfn`
        // would replace it, so the state machine's answer decides.
        let state = CLIInstaller.inspect(destination, expecting: bundledCLI)
        if case .blockedByFile = state {
            return CLIInstaller.Report(
                severity: .warning,
                title: "Something else is already at \(ServiceNames.cliInstallPath).",
                detail: "It is a regular file, not a symlink, so it was left alone. "
                    + "Remove it yourself and try again."
            )
        }

        // The legacy-sweep DECISION (#0051): when the state machine reports
        // the legacy link as ours, it is cleared first, in the same
        // privileged step. A foreign link is never reported — never removed.
        let legacy = CLIInstaller.legacySweepReport(
            bundledCLI: bundledCLI,
            legacyDestination: CLIInstaller.legacyDestination
        ) != nil ? CLIInstaller.legacyDestination : nil

        return present(
            outcome: runWithAdministratorPrivileges(
                command: CLIInstaller.installCommand(
                    bundledCLI: bundledCLI,
                    destination: destination,
                    legacyDestination: legacy
                ),
                reason: "Switchyard needs administrator access to create a symlink "
                    + "in \(destination.deletingLastPathComponent().path)."
            ),
            success: CLIInstaller.Report(
                severity: .informational,
                title: "Command line tool installed.",
                detail: """
                    \(ServiceNames.cliInstallPath) now points into this app.

                    Open a new terminal and run:  switchyard --help
                    """
            ),
            failureTitle: "Could not install the command line tool."
        )
    }

    /// File ▸ Uninstall Command Line Tool — removes the link and sweeps the
    /// legacy one, leaving nothing of ours behind. `nil` means present
    /// nothing: a cancelled dialog, or nothing installed to begin with.
    @discardableResult
    static func uninstall() -> CLIInstaller.Report? {
        let bundle = Bundle.main.bundleURL
        let bundledCLI = CLIInstaller.bundledCLI(inBundle: bundle)
        let destination = URL(
            filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory
        )

        let state = CLIInstaller.inspect(destination, expecting: bundledCLI)
        if case .blockedByFile = state {
            return CLIInstaller.Report(
                severity: .warning,
                title: "Nothing was removed.",
                detail: "\(ServiceNames.cliInstallPath) is a regular file, "
                    + "not a symlink this app created."
            )
        }

        let legacy = CLIInstaller.legacySweepReport(
            bundledCLI: bundledCLI,
            legacyDestination: CLIInstaller.legacyDestination
        ) != nil ? CLIInstaller.legacyDestination : nil
        if case .notInstalled = state, legacy == nil { return nil }

        return present(
            outcome: runWithAdministratorPrivileges(
                command: CLIInstaller.uninstallCommand(
                    destination: destination,
                    legacyDestination: legacy
                ),
                reason: "Switchyard needs administrator access to remove the symlink "
                    + "from \(destination.deletingLastPathComponent().path)."
            ),
            success: CLIInstaller.Report(
                severity: .informational,
                title: "Command line tool removed.",
                detail: "\(ServiceNames.cliInstallPath) has been deleted."
            ),
            failureTitle: "Could not remove the command line tool."
        )
    }

    /// Classifies the runner's outcome into the report to present: a
    /// cancelled dialog becomes `nil` (the alert is skipped and nothing
    /// appears), a failure becomes a warning carrying the AppleScript
    /// message, and success becomes the act's own report.
    private static func present(
        outcome: CLIInstaller.AuthOutcome?,
        success: CLIInstaller.Report,
        failureTitle: String
    ) -> CLIInstaller.Report? {
        // `nil` from the runner is the command's success.
        guard let outcome else { return success }
        switch outcome {
        case .cancelled:
            return nil
        case .failed(let message):
            return CLIInstaller.Report(
                severity: .warning, title: failureTitle, detail: message
            )
        }
    }

    // MARK: - Presentation

    /// The one place a `CLIInstaller.Report` becomes UI: a modal alert,
    /// styled by severity — the same split #0084's `RepositoryOpener` uses
    /// for open refusals. The installer presents nothing itself; `nil`
    /// (a cancelled dialog) presents nothing here either.
    static func present(_ report: CLIInstaller.Report?) {
        guard let report else { return }
        let alert = NSAlert()
        alert.alertStyle = report.severity == .warning ? .warning : .informational
        alert.messageText = report.title
        alert.informativeText = report.detail
        alert.runModal()
    }

    // MARK: - Menu state

    /// Whether Install can act, computed at command-body evaluation — one
    /// `stat`. State can change outside the app, and a stale flag is
    /// harmless: the action re-inspects when clicked. An install from *this*
    /// bundle is already correct, so it is the only state the item refuses.
    static var canInstall: Bool {
        currentState != .installedHere
    }

    /// Whether Uninstall can act. `blockedByFile` stays enabled on purpose:
    /// the action answers with a "nothing was removed" warning rather than
    /// silently ignoring a file it must not touch.
    static var canUninstall: Bool {
        currentState != .notInstalled
    }

    private static var currentState: CLIInstaller.State {
        let bundle = Bundle.main.bundleURL
        return CLIInstaller.inspect(
            URL(filePath: ServiceNames.cliInstallPath, directoryHint: .notDirectory),
            expecting: CLIInstaller.bundledCLI(inBundle: bundle)
        )
    }
}
