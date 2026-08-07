// ServiceNames.swift

import Foundation

/// The single source of truth for every identifier in the project.
///
/// These strings end up in the app target, the broker agent, the CLI, the
/// installer, the launchd plist, and the hook handler. A mismatch between any
/// two of them produces a failure that looks like "XPC is broken", so nothing
/// outside this file hardcodes any of them.
public enum ServiceNames {

    // MARK: - Identity

    /// User-facing app name.
    public static let appName = "Switchyard"

    /// App bundle identifier. Must match `PRODUCT_BUNDLE_IDENTIFIER` in the
    /// Xcode project — asserted by a test.
    public static let bundleIdentifier = "co.sstools.Switchyard"

    /// Unified-logging subsystem. Read with
    /// `/usr/bin/log stream --predicate 'subsystem == "co.sstools.Switchyard"'`
    /// — note `log` is a zsh builtin, so the absolute path matters.
    public static let logSubsystem = "co.sstools.Switchyard"

    // MARK: - XPC

    /// Mach service name the broker publishes. launchd owns this name; a
    /// plain double-clicked app cannot publish it, which is why the broker
    /// exists at all.
    public static let machServiceName = "co.sstools.Switchyard.broker"

    /// Filename of the launch agent's plist inside
    /// `Contents/Library/LaunchAgents/`.
    public static let agentPlistName = "co.sstools.Switchyard.broker.plist"

    /// Broker executable name inside `Contents/MacOS/`.
    public static let brokerExecutableName = "BrokerAgent"

    // MARK: - CLI

    /// CLI binary name.
    public static let cliName = "switchyard"

    /// Where the CLI is symlinked for real use. On the default macOS `PATH`,
    /// so nothing needs editing — and root-owned, so installing prompts.
    public static let cliInstallPath = "/usr/local/bin/switchyard"

    /// Path to the CLI inside the app bundle, relative to `Contents/`.
    public static let cliBundleRelativePath = "Resources/bin/switchyard"

    /// URL scheme for one-shot, fire-and-forget requests.
    public static let urlScheme = "switchyard"

    // MARK: - Storage

    /// Ref namespace anchoring journal snapshots so `gc` cannot reclaim them.
    /// Deliberately outside `refs/heads` and `refs/tags` so entries never
    /// appear in branch listings and are never pushed by a default refspec.
    public static let journalRefPrefix = "refs/switchyard/journal/"

    /// Per-repository directory, relative to `$GIT_COMMON_DIR`.
    public static let repoStateDirectoryName = "switchyard"

    /// Per-repository journal metadata file, relative to `$GIT_COMMON_DIR`.
    public static let journalMetadataRelativePath = "switchyard/journal.json"

    /// Cross-repository state: the repository registry, recent operations,
    /// agent sessions, UI state.
    ///
    /// Honors `XDG_STATE_HOME`, falling back to `~/.local/state`. That beats
    /// `~/Library/Application Support` because `yard` runs in shells, CI, and
    /// agent sandboxes where the Library path is awkward or absent.
    ///
    /// - Important: This only agrees between the app and the CLI while the app
    ///   stays unsandboxed. A sandboxed app resolves the same path inside its
    ///   container and diverges silently. See guide §11, open question 4.
    public static func stateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        let base: URL
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("state", isDirectory: true)
        }
        return base.appendingPathComponent("switchyard", isDirectory: true)
    }
}
