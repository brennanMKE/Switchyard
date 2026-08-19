// RunEngineFallbackTests.swift

import Foundation
import Testing
@testable import YardCommands
@testable import YardKit

/// #0337: `yard-engine`'s `main.swift` composes
/// `runEngineCommand(arguments:workingDirectory:) ?? runYard(arguments:)`.
/// That composition lives in an executable target's `main.swift`, which
/// SwiftPM will not let a test target `@testable import`, so these tests
/// reproduce the exact composition here and assert on its result instead.
@Test func compositionFallsThroughToRunYardWhenEngineReturnsNil() {
    let workingDirectory = FileManager.default.currentDirectoryPath

    // "noop" is not a case in runEngineCommand's switch, so it must return
    // nil -- the fall-through this test is checking for. (Unlike "--help",
    // "noop" answers through runYard's JSON envelope path rather than its
    // plain-text help renderer, so the schemaVersion assertion below is
    // actually exercising the fallen-through payload.)
    let engineResult = runEngineCommand(arguments: ["noop"], workingDirectory: workingDirectory)
    #expect(engineResult == nil)

    let composed = engineResult ?? runYard(arguments: ["noop"])
    #expect(composed.exitCode == .success)
    #expect(composed.stdout.contains("\"schemaVersion\":1"))
}

@Test func compositionDoesNotFallThroughForKnownEngineCommand() throws {
    let workingDirectory = FileManager.default.currentDirectoryPath

    // "whereami" IS a case in runEngineCommand's switch, and this process's
    // working directory is a real git worktree, so this must come back
    // non-nil -- runYard, which has no "whereami" case, must never run.
    let engineResult = runEngineCommand(arguments: ["whereami"], workingDirectory: workingDirectory)
    let composed = try #require(engineResult)

    #expect(composed.exitCode == .success)
    #expect(composed.stdout.contains("\"schemaVersion\":1"))
    // runYard's "unknown subcommand" usage envelope is the tell that the
    // fallback fired when it should not have.
    #expect(!composed.stdout.contains("Unknown subcommand"))
}
