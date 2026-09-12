// CLIInstaller.swift
//
// Ported from ../../RemoteControl/BridgeKit/Sources/BridgeKit/CLIInstaller.swift
// (MIT, same author — see CLAUDE.md and issue #0051). Copyright the original
// author; substantial portions retained here under the same MIT terms as
// this project.
//
// The durability refusals (`CLIInstallerError` and the two report shapes
// built from it) are adapted from Batty's
// BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift (MIT, Copyright
// 2026 Brennan Stehling — Batty #0275 translocation, #0279 the derived
// app name; ported for issue #0353). This notice is retained for those
// adapted portions.

import Foundation

/// The install-state machine for the `switchyard` command line tool.
///
/// The tool is embedded in the app bundle at
/// `Contents/` + `ServiceNames.cliBundleRelativePath`, and installed by
/// symlinking `ServiceNames.cliInstallPath` back into it. A symlink, not a
/// copy: the CLI always matches the installed app, and reinstalling
/// self-heals after the app moves.
///
/// This type lives in the package rather than the app target, and
/// deliberately presents no UI: every entry point returns a value — a
/// ``State`` or a ``Report`` — that the app renders. That is what keeps the
/// state machine testable: it is pure logic over a filesystem the caller
/// hands it, and the interesting cases (a link pointing elsewhere, a dangling
/// link, a real file in the way) are all reachable in a test without an app
/// or an authentication dialog.
///
/// This is the pure half of the installer (issue #0051). The privileged
/// action itself — the `ln -sfn`, the uninstall, and the File-menu item — is
/// issue #0222, which composes these pieces and acts on what they report.
public enum CLIInstaller {

    // MARK: - State

    /// What is at the install destination.
    public enum State: Equatable, Sendable {
        /// Nothing at the destination.
        case notInstalled
        /// A link pointing at *this* app bundle's CLI.
        case installedHere
        /// A link pointing somewhere else — another copy of the app, or a
        /// stale build directory. Carries the resolved target so the UI can
        /// say where.
        case installedElsewhere(String)
        /// Something exists at the destination that is not a symlink. Never
        /// clobbered: it could be a real binary the user put there.
        case blockedByFile
    }

    // MARK: - Reports

    /// Something worth telling the user, for the app to present however it
    /// presents things. Returning this rather than running an `NSAlert` here
    /// is what lets a test exercise every decision the installer makes.
    public struct Report: Equatable, Sendable {
        public enum Severity: Equatable, Sendable {
            case informational
            case warning
        }

        public let severity: Severity
        public let title: String
        public let detail: String

        public init(severity: Severity, title: String, detail: String) {
            self.severity = severity
            self.title = title
            self.detail = detail
        }
    }

    // MARK: - Paths

    /// The CLI inside `bundle`, placed by the build's embed step at
    /// `Contents/` + `ServiceNames.cliBundleRelativePath`.
    public static func bundledCLI(inBundle bundle: URL) -> URL {
        bundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: ServiceNames.cliBundleRelativePath, directoryHint: .notDirectory)
    }

    /// Where an earlier Switchyard build put its CLI. Kept only so a link
    /// left there can be reported — and, in #0222, swept: it sits earlier on
    /// many machines' `PATH` than `ServiceNames.cliInstallPath`, so leaving
    /// it would shadow a correct install and make the action look broken.
    public static let legacyDestination: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/bin/switchyard", directoryHint: .notDirectory)

    // MARK: - Inspection

    /// Classifies whatever is at `path`.
    ///
    /// `attributesOfItem` does not follow symlinks, which is what makes it
    /// usable for telling a link apart from a real file at the destination.
    /// `fileExists(atPath:)` *does* follow, so it reports false for a dangling
    /// link — exactly the state left behind when the target app is deleted,
    /// and the case that would otherwise read as "nothing installed" while a
    /// broken command sat on `PATH`.
    public static func inspect(_ path: URL, expecting target: URL) -> State {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: path.path) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .blockedByFile
        }
        guard let resolved = try? fm.destinationOfSymbolicLink(atPath: path.path) else {
            return .notInstalled
        }
        return resolved == target.path ? .installedHere : .installedElsewhere(resolved)
    }

    // MARK: - Durability

    /// Whether installing from this bundle would produce a durable link.
    ///
    /// A build-directory bundle is the case that matters: launching from Xcode
    /// runs the DerivedData copy, and a symlink into it breaks on the next
    /// clean build. So is a Gatekeeper-translocated bundle (#0353): an app run
    /// straight from `~/Downloads` is mounted read-only under
    /// `/AppTranslocation/`, and that mount disappears on relaunch — Batty
    /// #0275 refuses it for the same reason. Creating either link silently is
    /// worse than declining, because the failure surfaces much later as
    /// `switchyard: command not found`. The install action must REFUSE when
    /// this is false — not warn and continue.
    public static func isBundleDurable(_ bundle: URL) -> Bool {
        let path = bundle.path
        return !path.contains("/DerivedData/")
            && !path.contains("/Build/Products/")
            && !path.contains("/AppTranslocation/")
    }

    /// Whether Gatekeeper translocated this bundle: a quarantined app
    /// launched without first being moved to `/Applications` runs from a
    /// read-only `/private/var/folders/…/AppTranslocation/<uuid>/d/` mount
    /// that macOS reclaims on relaunch or reboot. Separate from
    /// ``isBundleDurable`` because the two refusals carry different advice —
    /// only a translocated instance stays broken after the app is moved; it
    /// must also be relaunched (see ``CLIInstallerError``).
    public static func isBundleTranslocated(_ bundle: URL) -> Bool {
        bundle.path.contains("/AppTranslocation/")
    }

    /// The report the install action returns when ``isBundleDurable`` is
    /// false for a build directory: a refusal, so a doomed link is never
    /// created. The remedy names the app — derived from the bundle path,
    /// never hardcoded — and includes the relaunch, so a user acting on it
    /// is not left running the stale copy the refusal was about.
    public static func buildDirectoryRefusalReport(bundle: URL, destination: URL) -> Report {
        refusalReport(.bundleNotDurable(bundle.path), destination: destination)
    }

    /// The translocation sibling of ``buildDirectoryRefusalReport`` — a
    /// distinct refusal because the advice differs: moving the app is not
    /// enough, because a translocated instance stays translocated until it
    /// is relaunched from its new location, and a user told only to move it
    /// would retry inside the same refusal (issue #0353; Batty #0275).
    public static func translocationRefusalReport(bundle: URL, destination: URL) -> Report {
        refusalReport(.bundleTranslocated(bundle.path), destination: destination)
    }

    /// Assembles either durability refusal: the destination context the
    /// alert needs, then the error case's own message.
    private static func refusalReport(
        _ error: CLIInstallerError,
        destination: URL
    ) -> Report {
        Report(
            severity: .warning,
            title: error.title,
            detail: """
                Installing would link \(destination.path) into:

                \(error.bundlePath)

                \(error.whyDoomed) \(error.remedy)
                """
        )
    }

    // MARK: - Privilege

    /// True when the destination needs an admin prompt: on a stock macOS the
    /// directory holding `ServiceNames.cliInstallPath` is `root:wheel`.
    /// Reported here; acted on in #0222.
    public static func requiresAuthentication(forDestinationDirectory directory: URL) -> Bool {
        !FileManager.default.isWritableFile(atPath: directory.path)
    }

    /// Single-quote wrapping, so a path with spaces or quotes cannot break out
    /// of the shell command the privileged step constructs.
    public nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The act (#0222)

    /// How a privileged step ended. ``cancelled`` is the user declining the
    /// authentication dialog — a decision the app presents nothing about,
    /// never an error; ``failed`` carries the AppleScript error message for
    /// the app to alert on.
    public enum AuthOutcome: Equatable, Sendable {
        case cancelled
        case failed(String)
    }

    /// Classifies an `NSAppleScript` error dictionary's `errorNumber`.
    ///
    /// `-128` is `userCanceledErr` — the number macOS reports when the user
    /// dismisses the administrator dialog (read from RemoteControl's
    /// BridgeKit installer, not guessed). Everything else is a real failure:
    /// the app alerts on ``failed`` and presents nothing on ``cancelled``.
    ///
    /// - Parameters:
    ///   - number: `NSAppleScript.errorNumber` from the error dictionary.
    ///   - message: `NSAppleScript.errorMessage` from the same dictionary;
    ///     a failure with no message still names the error number.
    public static func authOutcome(
        fromAppleScriptError number: Int,
        message: String? = nil
    ) -> AuthOutcome {
        if number == -128 { return .cancelled }
        return .failed(message ?? "AppleScript error \(number)")
    }

    /// The exact privileged shell command that installs the tool.
    ///
    /// Returned, never run: the package links no AppKit and presents no
    /// dialogs, so the app executes this string through its in-process
    /// `NSAppleScript` runner. `mkdir -p` because `/usr/local/bin` does not
    /// exist on a clean macOS, and `ln -sfn` so an existing link is replaced
    /// atomically rather than dereferenced. Every path goes through
    /// ``shellQuoted`` — this string is the shell-injection boundary.
    ///
    /// When `legacyDestination` is non-nil, `rm -f` clears it FIRST, in the
    /// same privileged step: the legacy location sits earlier on `PATH`, so
    /// leaving it would shadow the install that just succeeded. The decision
    /// is the caller's — pass the legacy location only when
    /// ``legacySweepReport(bundledCLI:legacyDestination:)`` reported it as
    /// ours, so a link to somebody else's tool is never removed.
    public static func installCommand(
        bundledCLI: URL,
        destination: URL,
        legacyDestination: URL?
    ) -> String {
        let directory = destination.deletingLastPathComponent().path
        var segments = ["mkdir -p \(shellQuoted(directory))"]
        if let legacyDestination {
            segments.append("rm -f \(shellQuoted(legacyDestination.path))")
        }
        segments.append(
            "ln -sfn \(shellQuoted(bundledCLI.path)) \(shellQuoted(destination.path))"
        )
        return segments.joined(separator: " && ")
    }

    /// The exact privileged shell command that uninstalls the tool: `rm -f`
    /// of the destination and — when `legacyDestination` is non-nil — of the
    /// legacy link in the same step, legacy first, so uninstall genuinely
    /// leaves nothing of ours behind. Same rule as ``installCommand``: only
    /// pass the legacy location when ``legacySweepReport`` reported it ours.
    public static func uninstallCommand(
        destination: URL,
        legacyDestination: URL?
    ) -> String {
        let paths = [legacyDestination?.path, destination.path].compactMap(\.self)
        return "rm -f " + paths.map { shellQuoted($0) }.joined(separator: " ")
    }

    /// The install action's precondition: the report to present — the reason
    /// no command is ever built — when this bundle would not produce a
    /// durable link. `nil` clears the install to proceed. A translocated
    /// bundle gets ``translocationRefusalReport``, whose remedy differs from
    /// ``buildDirectoryRefusalReport``'s.
    public static func installPreconditionReport(
        bundle: URL,
        destination: URL
    ) -> Report? {
        guard isBundleDurable(bundle) else {
            return isBundleTranslocated(bundle)
                ? translocationRefusalReport(bundle: bundle, destination: destination)
                : buildDirectoryRefusalReport(bundle: bundle, destination: destination)
        }
        return nil
    }

    // MARK: - Shadowing

    /// Reports a `switchyard` executable on `PATH` that would shadow the
    /// install destination.
    ///
    /// Entries are scanned in order and the scan stops at the destination
    /// directory's own entry: a copy found *before* it wins when the user
    /// types `switchyard`, which is what makes a correct install look like it
    /// did nothing. When the destination's entry comes first, nothing can
    /// shadow it. When the destination is not on `PATH` at all, any executable
    /// `switchyard` on `PATH` is reported, since that is what the shell will
    /// run instead of this install.
    ///
    /// - Parameters:
    ///   - environmentPath: the `PATH` to scan. Injected so tests can stage
    ///     entries; defaults to the process environment.
    ///   - destinationDirectory: where the install puts the link.
    public static func pathShadowReport(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        destinationDirectory: URL
    ) -> Report? {
        guard let environmentPath else { return nil }
        let destination = destinationDirectory.standardizedFileURL.path
        for entry in environmentPath.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = URL(fileURLWithPath: String(entry), isDirectory: true).standardizedFileURL
            if directory.path == destination {
                return nil   // the destination's own entry: nothing earlier shadows
            }
            let candidate = directory.appending(
                path: ServiceNames.cliName, directoryHint: .notDirectory
            )
            if isExecutableCommand(candidate) {
                return Report(
                    severity: .warning,
                    title: "Another switchyard command shadows this install.",
                    detail: """
                        An executable named \(ServiceNames.cliName) already exists at \
                        \(candidate.path), and typing switchyard will run that copy \
                        instead of \(destination). Remove it or reorder PATH.
                        """
                )
            }
        }
        return nil
    }

    /// The legacy-sweep DECISION: report a leftover link at
    /// ``legacyDestination`` when it is Switchyard's own, so the privileged
    /// step (#0222) removes it first, in the same elevated command. A link to
    /// somebody else's tool is never reported.
    ///
    /// - Parameters:
    ///   - bundledCLI: the CLI this install would point at.
    ///   - legacyDestination: the location to sweep. Injected so tests can
    ///     stage it; defaults to `~/.local/bin/switchyard`.
    public static func legacySweepReport(
        bundledCLI: URL,
        legacyDestination: URL = CLIInstaller.legacyDestination
    ) -> Report? {
        switch inspect(legacyDestination, expecting: bundledCLI) {
        case .installedHere:
            return shadowingLegacyReport(at: legacyDestination)
        case .installedElsewhere(let target) where target.contains("/Switchyard.app/"):
            // A legacy link pointing at *another* Switchyard copy is still
            // ours, and still shadows.
            return shadowingLegacyReport(at: legacyDestination)
        default:
            return nil
        }
    }

    private static func shadowingLegacyReport(at path: URL) -> Report {
        Report(
            severity: .warning,
            title: "A leftover switchyard link shadows this install.",
            detail: """
                \(path.path) is a link into a Switchyard bundle, and the directory it \
                sits in typically precedes \(ServiceNames.cliInstallPath) on PATH. \
                Installing removes it first, in the same step that creates the new link.
                """
        )
    }

    /// A file that exists, is not a directory, and carries the execute bit for
    /// this process. `isExecutableFile` alone is true for any searchable
    /// directory, which would let a directory named `switchyard` be reported.
    private static func isExecutableCommand(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory
        else { return false }
        return fm.isExecutableFile(atPath: url.path)
    }
}

/// Why the install action refuses a bundle whose link would not be durable.
/// Two cases, because the advice differs: a bundle in a build directory must
/// be moved and the running copy relaunched, while a Gatekeeper-translocated
/// bundle must be moved AND relaunched — a translocated instance stays
/// translocated until relaunch, so the build-directory wording alone would
/// send that user back into the same refusal (issue #0353).
///
/// Adapted from Batty's `CLIInstallerError`
/// (`BattyKit/Sources/BattyKit/Settings/CLIInstaller.swift`, MIT,
/// Copyright 2026 Brennan Stehling — Batty #0275 translocation, #0279 the
/// derived app name); this notice is retained for the adapted portions.
public enum CLIInstallerError: Error, LocalizedError, Equatable, Sendable {
    /// The bundle sits in Xcode's DerivedData or a `Build/Products`
    /// folder: a symlink into it dies on the next clean build.
    case bundleNotDurable(String)
    /// Gatekeeper translocated the bundle to a read-only
    /// `/AppTranslocation/` mount — it was launched from somewhere like
    /// `~/Downloads` without first being moved to `/Applications`.
    case bundleTranslocated(String)

    /// The bundle path the case carries.
    public var bundlePath: String {
        switch self {
        case .bundleNotDurable(let path), .bundleTranslocated(let path): path
        }
    }

    /// The app name the remedy addresses — the bundle path's last path
    /// component, never hardcoded (#0279's rule in Batty).
    public var appName: String {
        (bundlePath as NSString).lastPathComponent
    }

    /// The alert's headline: what is wrong, with the app named.
    public var title: String {
        switch self {
        case .bundleNotDurable:
            "\(appName) is running from a build directory."
        case .bundleTranslocated:
            "\(appName) is running from a temporary location."
        }
    }

    /// Why a symlink into this bundle is doomed.
    public var whyDoomed: String {
        switch self {
        case .bundleNotDurable:
            "That path is deleted whenever the build folder is cleaned, which would leave a broken command."
        case .bundleTranslocated:
            "That mount is read-only and disappears when the app relaunches, which would leave a broken command."
        }
    }

    /// The remedy. Distinct per case because the advice differs: a
    /// translocated instance stays translocated until it is relaunched, so
    /// "move the app" alone would land the next attempt in the same
    /// refusal.
    public var remedy: String {
        switch self {
        case .bundleNotDurable:
            "Move \(appName) to /Applications, relaunch, then install."
        case .bundleTranslocated:
            """
            Drag \(appName) to /Applications, then relaunch it before \
            installing — a translocated copy stays translocated until it \
            is relaunched from its new location.
            """
        }
    }

    public var errorDescription: String? {
        "\(title) \(whyDoomed) \(remedy)"
    }
}
