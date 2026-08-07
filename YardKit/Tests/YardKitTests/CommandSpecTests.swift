// CommandSpecTests.swift — round-trips and equality for CommandSpec and its parts.

import Testing
@testable import YardKit

@Test func commandSpec_roundTripsFields() {
    let flags: [FlagSpec] = [
        FlagSpec(long: "verbose", short: "v", help: "Enable verbose output"),
        FlagSpec(long: "output", short: "o", argument: "PATH", help: "Output file path")
    ]
    let exitCodes: [ExitCodeSpec] = [
        ExitCodeSpec(code: 0, meaning: "Success"),
        ExitCodeSpec(code: 1, meaning: "Failure"),
    ]

    let spec = CommandSpec(
        name: "log",
        summary: "Show commit history",
        flags: flags,
        exitCodes: exitCodes,
        schemaName: "LogResponse"
    )

    #expect(spec.name == "log")
    #expect(spec.summary == "Show commit history")
    #expect(spec.flags.count == 2)
    #expect(spec.flags[0].long == "verbose")
    #expect(spec.flags[0].short == "v")
    #expect(spec.flags[0].argument == nil)
    #expect(spec.flags[1].long == "output")
    #expect(spec.flags[1].argument == "PATH")
    #expect(spec.exitCodes.count == 2)
    #expect(spec.exitCodes[0].code == 0)
    #expect(spec.exitCodes[1].meaning == "Failure")
    #expect(spec.schemaName == "LogResponse")
}

@Test func commandSpec_equalityWithIdenticalCopy() {
    let flags: [FlagSpec] = [
        FlagSpec(long: "all", short: "a", help: "Show all commits")
    ]
    let exitCodes: [ExitCodeSpec] = [
        ExitCodeSpec(code: 0, meaning: "Success"),
    ]

    let a = CommandSpec(name: "status", summary: "Show working tree status", flags: flags, exitCodes: exitCodes, schemaName: "StatusResponse")
    let b = CommandSpec(name: "status", summary: "Show working tree status", flags: flags, exitCodes: exitCodes, schemaName: "StatusResponse")

    #expect(a == b)
}

@Test func flagSpec_equalityWithIdenticalCopy() {
    let a = FlagSpec(long: "verbose", short: "v", argument: nil, help: "Verbose")
    let b = FlagSpec(long: "verbose", short: "v", argument: nil, help: "Verbose")
    #expect(a == b)

    let c = FlagSpec(long: "output", short: nil, argument: "PATH", help: "Path")
    let d = FlagSpec(long: "output", short: nil, argument: "PATH", help: "Path")
    #expect(c == d)
}

@Test func exitCodeSpec_equalityWithIdenticalCopy() {
    let a = ExitCodeSpec(code: 0, meaning: "Success")
    let b = ExitCodeSpec(code: 0, meaning: "Success")
    #expect(a == b)
}
