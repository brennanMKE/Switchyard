// YardEngineBinaryTests.swift — the decision 37 verbs through a real
// process: the `yard-engine` harness, which runs the exact composition the
// app's XPC `perform` runs (`runEngineCommand ?? runYard`) in-process. The
// shipping `switchyard` binary cannot be driven here without launching the
// app, which tests never do.

import Foundation
import Testing
import YardGit

private final class BundleAnchor {}

/// `.build/<config>/yard-engine`, beside the test bundle.
private var yardEngine: URL {
    Bundle(for: BundleAnchor.self).bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("yard-engine")
}

/// Runs `yard-engine` in `directory`, returning its exit status and stdout.
private func runYardEngine(_ arguments: [String], in directory: URL) throws -> (status: Int32, json: [String: Any]) {
    let process = Process()
    process.executableURL = yardEngine
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let object = try JSONSerialization.jsonObject(with: data)
    return (process.terminationStatus, try #require(object as? [String: Any], "stdout: \(String(decoding: data, as: UTF8.self))"))
}

@Suite("yard-engine binary: working-tree verbs")
struct YardEngineBinaryTests {

    @Test func theHarnessIsBuilt() {
        #expect(FileManager.default.isExecutableFile(atPath: yardEngine.path),
                "yard-engine not found at \(yardEngine.path)")
    }

    /// stage from a subdirectory, commit with --json, then undo — each a
    /// JSON envelope on stdout with the documented exit status.
    @Test func stageCommitUndoThroughTheBinary() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.writeUntracked(["sub/d.txt": "d\n"])
        let head = try repo.revParse("HEAD")

        let stage = try runYardEngine(["stage", "sub/d.txt"], in: repo.url.appendingPathComponent("sub"))
        #expect(stage.status == 0)
        #expect(stage.json["ok"] as? Bool == true)

        let commit = try runYardEngine(["commit", "--message", "d", "--json"], in: repo.url)
        #expect(commit.status == 0)
        let oid = try #require((commit.json["result"] as? [String: Any])?["oid"] as? String)
        #expect(oid == (try repo.revParse("HEAD")))

        let undo = try runYardEngine(["undo"], in: repo.url)
        #expect(undo.status == 0)
        #expect(try repo.revParse("HEAD") == head)

        let usage = try runYardEngine(["commit"], in: repo.url)
        #expect(usage.status == 1)
        #expect(usage.json["ok"] as? Bool == false)
    }
}
