// XPCSendableTests.swift
//
// A standing source-level guard for issue #0053. Every closure Objective-C
// invokes off the caller's queue — `remoteObjectProxyWithErrorHandler`,
// `interruptionHandler`, `invalidationHandler`, the `reply:` blocks in the
// `@objc` XPC protocols — must carry `@Sendable`, and every class hosting an
// `exportedObject`-bearing `shouldAcceptNewConnection` must be declared
// `nonisolated`.
//
// Why the guard reads source instead of types: under the app target's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a closure literal written
// without `@Sendable` silently inherits main-actor isolation. XPC then calls
// it on its own queue and the process dies with SIGTRAP in
// `_swift_task_checkIsolatedSwift` — no compiler warning, invisible to a
// passing build and to the happy path. No `#if` can observe closure
// isolation, so the source is scanned, the way LayeringTests scans import
// lines.
//
// The runtime half of #0053 — kill-app-mid-request, interruptionHandler and
// invalidationHandler against live processes — is owned by #0054's manual
// script and is deliberately not faked here.

import Foundation
import Testing

struct XPCSendableTests {

    // MARK: - Roots

    /// YardKitTests → Tests → YardKit (the package root). Same walk as
    /// LayeringTests. The package-side scan below asserts this root really
    /// contains `Sources/YardKit`, which pins the walk every other root in
    /// this file is derived from: the repository root is one more deletion
    /// away, so a wrong walk-up fails loudly in the package scan rather
    /// than vacuously here.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
    }

    /// The repository root above the package: the directory holding the app
    /// target (`Switchyard/`) and the broker agent (`BrokerAgent/`), both
    /// OUTSIDE the SwiftPM package.
    private var repoRoot: URL {
        packageRoot.deletingLastPathComponent()
    }

    // MARK: - File walking (LayeringTests idiom, copied)

    /// Recursively list Swift source files under `base`. Hidden directories
    /// are skipped. Symbolic links are not followed — the source tree should
    /// not contain them, and if it does we treat them as unscannable rather
    /// than risking an infinite loop.
    private func listSwiftFiles(recursive: Bool, at base: URL) throws -> [URL] {
        var results: [URL] = []

        if recursive, let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey]) {

            while let url = enumerator.nextObject() as? URL {
                if let isDir = try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]).isDirectory {
                    if isDir, url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                    } else if !isDir, url.pathExtension == "swift" {
                        results.append(url)
                    }
                } else if url.pathExtension == "swift" {
                    // If we can't determine the type, treat as a file and
                    // check it is not hidden.
                    results.append(url)
                }
            }
        } else {
            let contents = try FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey])

            for url in contents {
                let isDir = try url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]).isDirectory ?? false
                if !isDir, url.pathExtension == "swift" {
                    results.append(url)
                }
            }
        }

        return results
    }

    // MARK: - The matcher

    /// Lines opening a closure that Foundation types as a plain, non-
    /// `@Sendable` function type. A closure literal written at one of these
    /// sites inherits the enclosing actor isolation — MainActor under the
    /// app target's default — unless it is marked `@Sendable`, and then
    /// traps when XPC calls it off that actor.
    private static let closureTriggers = [
        "remoteObjectProxyWithErrorHandler",
        "interruptionHandler",
        "invalidationHandler",
    ]

    /// Every isolation violation found in `lines`.
    ///
    /// Two rules per code line (comments and blanks skipped, as in
    /// LayeringTests):
    ///
    /// * A closure trigger, or a `reply:` closure literal, must carry
    ///   `@Sendable` on its own line or the next one. The repo convention is
    ///   `{ @Sendable [weak self] ... in` on the trigger line;
    ///   `AppConnection.swift` instead opens the brace on the trigger line
    ///   and writes `@Sendable error in` on the next, so the window is two
    ///   lines.
    /// * A `shouldAcceptNewConnection` that sets `exportedObject` must be
    ///   hosted by a class declared `nonisolated`. A delegate method is not
    ///   a closure literal, and XPC reaches it on its own queue, so
    ///   `nonisolated` is the method-level equivalent of the annotation.
    func isolationViolations(lines: [String], fileName: String) -> [String] {
        var violations: [String] = []

        for (offset, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard isCode(trimmed) else { continue }

            let isClosureTrigger = Self.closureTriggers.contains { trimmed.contains($0) }
            if isClosureTrigger || trimmed.contains("reply:") {
                var window = trimmed
                if offset + 1 < lines.count {
                    window += " " + lines[offset + 1]
                }
                if !window.contains("@Sendable") {
                    violations.append(
                        "\(fileName):\(offset + 1) XPC callback closure needs @Sendable on this line or the next: \(trimmed)")
                }
            }

            if trimmed.contains("shouldAcceptNewConnection") {
                violations.append(
                    contentsOf: delegateViolations(around: offset, lines: lines, fileName: fileName))
            }
        }

        return violations
    }

    /// The `shouldAcceptNewConnection` rule: only an acceptance path that
    /// actually exports an object is a hazard — the exported object's
    /// methods are what XPC invokes off-queue — so `exportedObject` must
    /// appear within the next few lines before the class hosting the method
    /// is required to be `nonisolated`.
    private func delegateViolations(around offset: Int, lines: [String], fileName: String) -> [String] {
        guard offset < lines.count - 1 else { return [] }

        let bodyEnd = min(offset + 15, lines.count - 1)
        let exportsAnObject = lines[(offset + 1)...bodyEnd].contains { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return isCode(trimmed) && trimmed.contains("exportedObject")
        }
        guard exportsAnObject else { return [] }

        guard offset > 0 else {
            return [
                "\(fileName):\(offset + 1) no class declaration found above this "
                    + "exportedObject-bearing shouldAcceptNewConnection",
            ]
        }

        var hostingClass: String?
        for back in stride(from: offset - 1, through: max(offset - 30, 0), by: -1) {
            let trimmed = lines[back].trimmingCharacters(in: .whitespaces)
            guard isCode(trimmed) else { continue }
            if trimmed.contains("class ") {
                hostingClass = trimmed
                break
            }
        }

        guard let hostingClass else {
            return [
                "\(fileName):\(offset + 1) no class declaration found within 30 lines above this "
                    + "exportedObject-bearing shouldAcceptNewConnection",
            ]
        }
        if hostingClass.contains("nonisolated") { return [] }
        return [
            "\(fileName):\(offset + 1) the class hosting an exportedObject-bearing "
                + "shouldAcceptNewConnection must be declared nonisolated: \(hostingClass)",
        ]
    }

    /// A line is code when it is neither blank nor a comment. `///` doc
    /// lines are caught by the same prefix — AppXPCServer.swift mentions
    /// `shouldAcceptNewConnection` and `exportedObject` in prose, and those
    /// mentions must not be scanned.
    private func isCode(_ trimmedLine: String) -> Bool {
        !trimmedLine.isEmpty && !trimmedLine.hasPrefix("//")
    }

    // MARK: - The matcher is live

    /// Rule 7: a matcher that never matches anything passes forever, which
    /// turns a guard into a decoration. Each snippet below is a real shape
    /// from the tree with the safety annotation removed, and each must be
    /// reported as exactly one violation.
    @Test func matcherFlagsEveryTriggerKindMissingItsAnnotation() {
        let snippets: [String: String] = [
            "remoteObjectProxyWithErrorHandler":
                """
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    Task { @MainActor in self?.recover() }
                }
                """,
            "interruptionHandler":
                """
                connection.interruptionHandler = { [weak self] in
                    self?.registerWithBroker()
                }
                """,
            "invalidationHandler":
                """
                connection.invalidationHandler = { [service] in
                    service.clearIfRegistered()
                }
                """,
            "reply: closure literal":
                """
                func appPing(reply: @escaping (String) -> Void) {
                    reply("ok")
                }
                """,
            "exportedObject-bearing shouldAcceptNewConnection":
                """
                final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
                    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                        connection.exportedInterface = XPCInterfaces.appService
                        connection.exportedObject = AppService()
                        connection.resume()
                        return true
                    }
                }
                """,
        ]
        // A new trigger kind must arrive with its own known-bad snippet.
        #expect(snippets.count == 5, "the trigger set changed — add the missing known-bad snippet here")

        for (name, snippet) in snippets {
            let violations = isolationViolations(
                lines: snippet.components(separatedBy: .newlines),
                fileName: "known-bad \(name)")
            #expect(
                violations.count == 1,
                "expected exactly one violation for a known-bad \(name) snippet, got \(violations)")
        }
    }

    /// The mirror of the known-bad test: every annotated shape the tree
    /// actually uses must produce zero violations, or the guard is a false
    /// positive generator.
    @Test func matcherAcceptsEveryAnnotatedShapeInTheTree() {
        let snippets: [String: String] = [
            "error handler annotated on the opening-brace line":
                """
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                    Task { @MainActor in self?.recover() }
                }
                """,
            "error handler annotated on the line after the brace (AppConnection shape)":
                """
                let proxy = self.connection.remoteObjectProxyWithErrorHandler {
                    @Sendable error in
                    once.finish(.failure(error))
                }
                """,
            "interruption handler annotated on the opening-brace line":
                """
                connection.interruptionHandler = { @Sendable [weak self] in
                    Task { @MainActor [weak self] in self?.registerWithBroker() }
                }
                """,
            "reply closure declared @escaping @Sendable":
                """
                func appPing(reply: @escaping @Sendable (String) -> Void) {
                    reply("ok")
                }
                """,
            "nonisolated delegate hosting an exportedObject":
                """
                nonisolated final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
                    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                        connection.exportedObject = AppService()
                        connection.resume()
                        return true
                    }
                }
                """,
        ]
        #expect(snippets.count == 5, "the accepted-shape set changed — add the missing snippet here")

        for (name, snippet) in snippets {
            let violations = isolationViolations(
                lines: snippet.components(separatedBy: .newlines),
                fileName: name)
            #expect(
                violations.isEmpty,
                "the matcher flagged an accepted shape (\(name)): \(violations)")
        }
    }

    // MARK: - The audit

    /// The package half of the audit: `Sources/YardKit`, inside the package.
    @Test func everyXPCCallbackSiteInYardKitCarriesSendable() throws {
        let sources = packageRoot.appendingPathComponent("Sources/YardKit")
        let files = try listSwiftFiles(recursive: true, at: sources)
        #expect(!files.isEmpty, "no Swift sources found at \(sources.path)")

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            violations.append(
                contentsOf: isolationViolations(
                    lines: source.components(separatedBy: .newlines),
                    fileName: file.lastPathComponent))
        }
        #expect(
            violations.isEmpty,
            "XPC callback sites missing @Sendable / nonisolated:\n\(violations.joined(separator: "\n"))")
    }

    /// The app-and-broker half of the audit: `Switchyard/` and
    /// `BrokerAgent/`, both OUTSIDE the package.
    ///
    /// Behaviour choice, stated for #0053: each directory is tolerated
    /// individually when absent, because this package is a self-contained
    /// SwiftPM tree that must stay testable even if the app checkout is not
    /// above it. That tolerance is bounded, not silent: `Switchyard.xcodeproj`
    /// is the anchor distinguishing "this repository" from a standalone
    /// package checkout. When the anchor is present, both directories must
    /// have been scanned — a renamed or moved app target fails loudly rather
    /// than being skipped into vacuity — and whenever a directory does
    /// exist, its scanned file count is asserted non-empty. In this
    /// repository the anchor is present and both directories are scanned.
    @Test func everyXPCCallbackSiteInAppAndBrokerCarriesSendable() throws {
        let repoIsThisOne = FileManager.default.fileExists(
            atPath: repoRoot.appendingPathComponent("Switchyard.xcodeproj").path)

        var scannedDirectories: [String] = []
        var violations: [String] = []

        for name in ["Switchyard", "BrokerAgent"] {
            let base = repoRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }

            let files = try listSwiftFiles(recursive: true, at: base)
            #expect(!files.isEmpty, "no Swift sources found at \(base.path)")
            scannedDirectories.append(name)

            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                violations.append(
                    contentsOf: isolationViolations(
                        lines: source.components(separatedBy: .newlines),
                        fileName: "\(name)/\(file.lastPathComponent)"))
            }
        }

        if repoIsThisOne {
            // In this repository both directories exist and both must have
            // been scanned and asserted non-empty above.
            #expect(
                scannedDirectories.count == 2,
                "expected to scan Switchyard and BrokerAgent, scanned \(scannedDirectories)")
        } else {
            // Standalone package checkout: the app-side half is skipped by
            // design. Still no silent pass — a directory that exists without
            // the project anchor means the anchor is stale and the tolerance
            // decision needs revisiting.
            #expect(
                scannedDirectories.isEmpty,
                "an app repo directory was found but Switchyard.xcodeproj is not — the anchor is stale")
        }

        #expect(
            violations.isEmpty,
            "XPC callback sites missing @Sendable / nonisolated:\n\(violations.joined(separator: "\n"))")
    }
}
