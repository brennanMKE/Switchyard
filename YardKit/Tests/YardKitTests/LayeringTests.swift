// LayeringTests.swift

import Foundation
import Testing
@testable import YardKit

struct LayeringTests {

    @Test func packageReportsAVersion() {
        #expect(!YardKit.version.isEmpty)
    }

    /// The engine must stay usable with no app, no XPC, and no launch agent —
    /// that constraint is what lets `yard` run in CI, over SSH, and in headless
    /// agent runs. A stray `import YardKit` inside `YardGit` would break it
    /// silently, so this asserts the dependency direction from the source.
    @Test func yardGitDoesNotImportYardKit() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // YardKit (package root)
        let engine = root.appendingPathComponent("Sources/YardGit")

        let swiftFiles = try listSwiftFiles(recursive: true, at: engine)
        #expect(!swiftFiles.isEmpty, "no Swift sources found at \(engine.path)")

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
                guard let marker = stripImportAttributes(from: trimmed) else { continue }
                #expect(
                    !marker.hasPrefix("YardKit"),
                    "\(file.lastPathComponent) imports YardKit — the engine must not depend on the XPC layer"
                )
            }
        }
    }

    /// The CLI layer depends on the engine only through internal helpers.
    /// YardKit now imports `YardGit` via `CommandLineRunner.swift` (the
    /// whereami command, see #0124), so the assertion here verifies only that
    /// the dependency is declared via Package.swift and limited to the runner
    /// path — no XPC, no Views layer, nothing else sneaks into Sources/YardKit.
    @Test func yardKitImportsYardGitInRunner() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // YardKit (package root)
        let layer = root.appendingPathComponent("Sources/YardKit")

        // CommandLineRunner is the one file permitted to import YardGit.
        let runner = root.appendingPathComponent("Sources/YardKit/CommandLineRunner.swift")
        #expect(FileManager.default.fileExists(atPath: runner.path),
                "CommandLineRunner.swift is the expected YardGit import site")

        let source = try String(contentsOf: runner, encoding: .utf8)
        #expect(source.contains("import YardGit"),
                "CommandLineRunner must import YardGit so whereami can call the engine")

        // Every other file in Sources/YardKit must NOT import YardGit — this
        // keeps the layering test sharp and stops the CLI from growing a hidden
        // dependency on the engine.
        let swiftFiles = try listSwiftFiles(recursive: true, at: layer)

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
                guard let marker = stripImportAttributes(from: trimmed) else { continue }

                // CommandLineRunner.swift is allowed; every other file must not import YardGit.
                if file.lastPathComponent == "CommandLineRunner.swift" { continue }

                #expect(
                    !marker.hasPrefix("YardGit"),
                    "\(file.lastPathComponent) imports YardGit — only CommandLineRunner is permitted to do so"
                )
            }
        }

        // Package.swift must declare the dependency — a stray import without a declaration
        // would fail at build time, but this check makes the relationship explicit in the
        // source and guards against a future typo where someone adds `import YardGit` without
        // updating the manifest.
        let packagePath = root.appendingPathComponent("Package.swift")
        let pkgSource = try String(contentsOf: packagePath, encoding: .utf8)
        #expect(pkgSource.contains("YardGit"), "Package.swift must list YardGit as a dependency")
    }

    /// Recursively list Swift source files under `base`. Hidden directories are
    /// skipped. Symbolic links are not followed — the source tree should not
    /// contain them, and if it does we treat them as unscannable rather than
    /// risking an infinite loop.
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
                    // If we can't determine the type, treat as a file and check
                    // it is not hidden.
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

    /// Strip `@testable`, `internal`, and `public` attributes from the start of
    /// a Swift import line so that guarded imports (`@testable import X`,
    /// `internal import Y`) are matched the same as an unqualified `import Z`.
    /// Removes the leading `import` keyword so callers can test for a bare
    /// module name with `.hasPrefix("Name")`.
    ///
    /// Returns `nil` for a line that is not an import. The previous version
    /// returned the line unchanged and its comment claimed callers used that as
    /// a skip signal — neither caller did, so a source line beginning at column
    /// zero with a module name, e.g. `YardKit.version`, was a false positive.
    /// Returning an Optional makes the signal one the compiler enforces.
    private func stripImportAttributes(from line: String) -> String? {
        var result = line

        for attr in ["@testable ", "internal ", "public "] {
            if result.hasPrefix(attr) {
                result = String(result.dropFirst(attr.count))
            }
        }

        guard result.hasPrefix("import ") else { return nil }
        return String(result.dropFirst("import ".count))
    }
}
