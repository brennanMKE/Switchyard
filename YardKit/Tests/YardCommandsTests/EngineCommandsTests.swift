// EngineCommandsTests.swift

import Testing
@testable import YardCommands

/// #0223 does not add any engine arms yet — `runEngineCommand` must return
/// `nil` for everything, which is the contract #0124 builds the first real
/// arm against.
@Test func runEngineCommandReturnsNilForNoop() {
    let result = runEngineCommand(arguments: ["noop"], workingDirectory: "/tmp")
    #expect(result == nil)
}

@Test func runEngineCommandReturnsNilForUnknownCommand() {
    let result = runEngineCommand(arguments: ["definitely-not-a-command"], workingDirectory: "/tmp")
    #expect(result == nil)
}
