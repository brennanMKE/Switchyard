// RunEngineFallbackTests.swift

import Foundation
import Testing
@testable import YardCommands
@testable import YardKit
import YardGit

/// #0337: `yard-engine`'s `main.swift` composes
/// `runEngineCommand(arguments:workingDirectory:) ?? runYard(arguments:)`.
/// That composition lives in an executable target's `main.swift`, which
/// SwiftPM will not let a test target `@testable import`, so these tests
/// reproduce the exact composition here and assert on its result instead.
///
/// #0343: both tests build their own `FixtureRepository` rather than reading
/// the test process's `FileManager.default.currentDirectoryPath`, which is
/// only a git worktree under `swift test` in a checkout -- not in a
/// `git archive HEAD` export, which is how mutation-testing review works.
@Test func compositionFallsThroughToRunYardWhenEngineReturnsNil() throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let workingDirectory = repo.url.path

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
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    let workingDirectory = repo.url.path

    // "whereami" IS a case in runEngineCommand's switch, and workingDirectory
    // is a real git repository built by the fixture, so this must come back
    // non-nil -- runYard, which has no "whereami" case, must never run.
    let engineResult = runEngineCommand(arguments: ["whereami"], workingDirectory: workingDirectory)
    let composed = try #require(engineResult)

    #expect(composed.exitCode == .success)
    #expect(composed.stdout.contains("\"schemaVersion\":1"))
    // runYard's "unknown subcommand" usage envelope is the tell that the
    // fallback fired when it should not have.
    #expect(!composed.stdout.contains("Unknown subcommand"))
}
