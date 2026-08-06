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

        let files = try FileManager.default
            .contentsOfDirectory(at: engine, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no Swift sources found at \(engine.path)")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                #expect(
                    !trimmed.hasPrefix("import YardKit"),
                    "\(file.lastPathComponent) imports YardKit — the engine must not depend on the XPC layer"
                )
            }
        }
    }
}
