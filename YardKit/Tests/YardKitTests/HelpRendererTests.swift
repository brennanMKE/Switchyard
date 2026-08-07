// HelpRendererTests.swift

import XCTest
@testable import YardKit

final class HelpRendererTests: XCTestCase {

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

    func testRenderHelpContainsFlagsAndExitCodes() {
        let rendered = renderHelp(for: Self.sampleSpec)

        for flag in Self.sampleSpec.flags {
            XCTAssertTrue(
                rendered.contains("--\(flag.long)"),
                "Expected flag --\(flag.long) to appear in rendered help:\n\(rendered)"
            )
        }

        for exitCode in Self.sampleSpec.exitCodes {
            XCTAssertTrue(
                rendered.contains("\(exitCode.code)"),
                "Expected exit code \(exitCode.code) to appear in rendered help:\n\(rendered)"
            )
        }
    }

    // MARK: - Deterministic output.

    func testRenderHelpIsDeterministic() {
        let a = renderHelp(for: Self.sampleSpec)
        let b = renderHelp(for: Self.sampleSpec)

        XCTAssertEqual(a, b, "Rendering the same spec twice must produce identical output")
    }

    // MARK: - Flag formatting.

    func testRenderHelpShortLongFlag() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "version", short: nil, argument: nil, help: "Show version")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        XCTAssertTrue(rendered.contains("--version"))
    }

    func testRenderHelpShortAndLongFlag() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "verbose", short: "v", argument: nil, help: "Be verbose")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        XCTAssertTrue(rendered.contains("-v, --verbose"))
    }

    func testRenderHelpFlagWithArgument() {
        let spec = CommandSpec(
            name: "git", summary: "",
            flags: [FlagSpec(long: "target", short: nil, argument: "PATH", help: "Output destination")],
            exitCodes: [],
            schemaName: ""
        )
        let rendered = renderHelp(for: spec)
        XCTAssertTrue(rendered.contains("--target <PATH>"))
    }

    // MARK: - Header and exit-code sections.

    func testRenderHelpHeaderAndExitCodes() {
        let rendered = renderHelp(for: Self.sampleSpec)

        XCTAssertTrue(rendered.contains("status"))
        XCTAssertTrue(rendered.contains("Show the working tree status"))
        XCTAssertTrue(rendered.contains("Options:"))
        XCTAssertTrue(rendered.contains("Exit codes:"))
    }

    func testRenderHelpEmptySpec() {
        let spec = CommandSpec(
            name: "noop", summary: "", flags: [], exitCodes: [], schemaName: ""
        )
        let rendered = renderHelp(for: spec)

        XCTAssertTrue(rendered.hasPrefix("noop"))
        XCTAssertFalse(rendered.contains("Options:"))
        XCTAssertFalse(rendered.contains("Exit codes:"))
    }

    // MARK: - Pure function behaviour.

    func testRenderHelpIsNonisolated() {
        // This call site verifies that `renderHelp(for:)` is callable without
        // awaiting — i.e. it really is declared nonisolated, as the issue requires.
        let result = renderHelp(for: Self.sampleSpec)
        XCTAssertTrue(!result.isEmpty)
    }
}
