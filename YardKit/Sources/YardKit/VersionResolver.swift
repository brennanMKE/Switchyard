// VersionResolver.swift

import Foundation

/// Resolves the version the CLI reports, from the host bundle the executable
/// actually lives in, so a bug report names the build it came from (#0219).
///
/// The installed entry point (`ServiceNames.cliInstallPath`) is a symlink into the
/// app bundle (`…/Contents/Resources/bin/switchyard`), so symlinks are resolved
/// FIRST: without that the upward walk starts from `/usr/local/bin` and finds
/// no `Info.plist` at all.
///
/// The executable URL is a parameter, not a `Bundle.main` read inside this
/// type — that is what makes both branches testable with a fake bundle layout.
public enum VersionResolver {

    /// The summary line the CLI prints: `"switchyard <version>"`.
    public static func cliVersionSummary(forExecutableAt executableURL: URL) -> String {
        "\(ServiceNames.cliName) \(versionString(forExecutableAt: executableURL))"
    }

    /// The bare version value: the host bundle's `CFBundleShortVersionString`,
    /// with `CFBundleVersion` appended in parentheses when the two differ.
    ///
    /// Outside a bundle — running from `.build/debug/switchyard`, as every
    /// test and every `swift build` invocation does — there is no plist to
    /// find, and the answer is the package version `YardKit.version`: never a
    /// crash, never an empty string. The same fallback covers a `Contents`
    /// directory whose plist is missing or carries no short-version key.
    public static func versionString(forExecutableAt executableURL: URL) -> String {
        // Symlinks resolved first (see the type comment): the walk below must
        // start from the real binary inside the bundle, not from the link.
        let resolved = executableURL.resolvingSymlinksInPath()

        var directory = resolved.path
        while directory != "/" && !directory.isEmpty {
            let ns = directory as NSString
            guard ns.lastPathComponent == "Contents" else {
                directory = ns.deletingLastPathComponent
                continue
            }
            // A `Contents` directory is the bundle's; the plist lives beside it.
            // Nothing further up can help, so any failure here falls back.
            guard let info = readInfoPlist(atContentsPath: directory),
                  let short = info["CFBundleShortVersionString"] as? String else {
                return YardKit.version
            }
            if let build = info["CFBundleVersion"] as? String, build != short {
                return "\(short) (\(build))"
            }
            return short
        }
        return YardKit.version
    }

    private static func readInfoPlist(atContentsPath contentsPath: String) -> [String: Any]? {
        let plistPath = (contentsPath as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                  as? [String: Any] else {
            return nil
        }
        return info
    }
}
