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

    /// The CLI must not pull the engine into its binary. YardKit's dependency
    /// chain is `YardKit → nothing` and the executable depends on YardKit only,
    /// so a stray `import YardGit` inside Sources/YardKit/ is the failure
    /// mode this asserts against from the source.
    @Test func yardKitDoesNotImportYardGit() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // YardKitTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // YardKit (package root)
        let layer = root.appendingPathComponent("Sources/YardKit")

        let swiftFiles = try listSwiftFiles(recursive: true, at: layer)
        #expect(!swiftFiles.isEmpty, "no Swift sources found at \(layer.path)")

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
                guard let marker = stripImportAttributes(from: trimmed) else { continue }
                #expect(
                    !marker.hasPrefix("YardGit"),
                    "\(file.lastPathComponent) imports YardGit — the CLI must not depend on the engine"
                )
            }
        }
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
