// HelpRendererTests.swift

import Testing
@testable import YardKit

@Suite("HelpRenderer")
struct HelpRendererTests {

    /// A small spec that exercises every rendering path.
    private static let sampleSpec = CommandSpec(
        name: "status",
        summary: "Show the working tree status",
        flags: [
            FlagSpec(long: "short", short: "s", argument: nil, help: "Use the shorter output format"),
            FlagSpec(long: "branch", short: nil, argument: nil, help: "Show branch information"),
            FlagSpec(long: "path", short: nil, argument: "PATH", help: "Show only the specified path"),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "Success"),
            ExitCodeSpec(code: 1, meaning: "Unmerged files exist in the index"),
            ExitCodeSpec(code: 2, meaning: "Another operation is already in progress"),
        ],
        schemaName: "StatusResponse"
    )

    // MARK: - Every flag long name and exit code number appears in the rendered output.

    @Test("Every flag long name and every exit code number from a hand-built spec appears in the rendered text")
    func testRenderHelpContainsFlagsAndExitCodes() {
        let rendered = renderHelp(for: Self.sampleSpec)

        #expect(Self.sampleSpec.flags.count >= 3, "loop must iterate real cases")
        for flag in Self.sampleSpec.flags {
            #expect(rendered.contains("--\(flag.long)"), "Expected flag --\(flag.long) to appear in rendered help:\n\(rendered)")
        }

        for exitCode in Self.sampleSpec.exitCodes {
            #expect(rendered.contains("\(exitCode.code)"), "Expected exit code \(exitCode.code) to appear in rendered help:\n\(rendered)")
        }
    }

    // MARK: - Deterministic output.

    @Test("Rendering the same spec twice produces identical strings")
    func testRenderHelpIsDeterministic() {
        let a = renderHelp(for: Self.sampleSpec)
        let b = renderHelp(for: Self.sampleSpec)

        #expect(a == b, "Rendering the same spec twice must produce identical output")
    }

    // MARK: - Flag formatting (all four combinations).

    @Test("Flag with only a long name renders as --long")
    func testRenderHelpLongOnly() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "version", short: nil, argument: nil, help: "Show version")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        #expect(rendered.contains("--version"))
    }

    @Test("Flag with short and long name but no argument renders as -s, --long")
    func testRenderHelpShortAndLong() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "verbose", short: "v", argument: nil, help: "Be verbose")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        #expect(rendered.contains("-v, --verbose"))
    }

    @Test("Flag with long name and argument but no short name renders as --long <ARG>")
    func testRenderHelpLongAndArgument() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "target", short: nil, argument: "PATH", help: "Output destination")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        #expect(rendered.contains("--target <PATH>"))
    }

    @Test("Flag with short name, long name, and argument renders as -s, --long <ARG>")
    func testRenderHelpShortAndLongAndArgument() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "output", short: "o", argument: "PATH", help: "Output destination")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        #expect(rendered.contains("-o, --output <PATH>"))
    }

    // MARK: - Header and exit-code sections.

    @Test("Header includes command name, summary, Options: section, and Exit codes: section")
    func testRenderHelpHeaderAndExitCodes() {
        let rendered = renderHelp(for: Self.sampleSpec)

        #expect(rendered.contains("status"))
        #expect(rendered.contains("Show the working tree status"))
        #expect(rendered.contains("Options:"))
        #expect(rendered.contains("Exit codes:"))
    }

    @Test("Empty spec renders the command name without Options or Exit codes sections")
    func testRenderHelpEmptySpec() {
        let spec = CommandSpec(
            name: "noop", summary: "", flags: [], exitCodes: [], schemaName: ""
        )
        let rendered = renderHelp(for: spec)

        #expect(rendered.hasPrefix("noop"))
        #expect(!rendered.contains("Options:"))
        #expect(!rendered.contains("Exit codes:"))
    }

    // MARK: - Pure function behaviour.

    @Test("renderHelp is callable without awaiting (nonisolated)")
    func testRenderHelpIsNonisolated() {
        let result = renderHelp(for: Self.sampleSpec)
        #expect(!result.isEmpty)
    }
}
