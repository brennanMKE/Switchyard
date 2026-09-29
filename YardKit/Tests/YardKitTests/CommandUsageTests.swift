// CommandUsageTests.swift — every registered command carries its synopsis (#0449)

import Foundation
import Testing
@testable import YardKit

/// The positionals each command's own parser accepts, read from the parsers
/// and confirmed by running `yard-engine`/`switchyard` with missing and extra
/// arguments on 2026-09-29 (issues/0449.md, Given 3). The table is the
/// independent source: a usage that drops one of these fails the test below.
private let positionalPlaceholders: [String: [String]] = [
    "log": ["<range>"],
    "verify": ["<revision>"],
    "split": ["<commit>", "<hunkID>"],
    "reword": ["<commit>"],
    "drop": ["<commit>"],
    "reorder": ["<commit>"],
    "revert": ["<commit>"],
    "cherry-pick": ["<commit>"],
    "merge": ["<branch>"],
    "rewrite-diff": ["<journal-entry-id>"],
    "review": ["<range>"],
    "ask": ["<question>"],
    "resolve": ["<pathspec>"],
    "watch": ["<repository-path>"],
    "tag": ["<name>", "<commit>"],
    "branch": ["<name>", "<start>", "<old>", "<new>", "<upstream>"],
    "rebase-onto": ["<commit>"],
    "set-tip": ["<commit>"],
    "stage": ["<path>"],
    "unstage": ["<path>"],
    "discard": ["<path>"],
]

/// Every `--flag` token in a usage string.
private func usageFlags(in usage: String) -> Set<String> {
    let pattern = /--([a-z][a-z-]*)/
    return Set(usage.matches(of: pattern).map { String($0.output.1) })
}

@Suite("Command usage")
struct CommandUsageTests {

    @Test("every registered command has a non-empty usage that starts with its name")
    func everyCommandHasAUsage() {
        #expect(CommandRegistry.all.count >= 30, "an empty registry would make this test vacuous")
        for spec in CommandRegistry.all {
            #expect(!spec.usage.isEmpty, "\(spec.name) has an empty usage")
            if spec.name != ServiceNames.cliName {
                #expect(spec.usage == spec.name || spec.usage.hasPrefix(spec.name + " "),
                        "\(spec.name)'s usage must start with its name: '\(spec.usage)'")
            }
        }
    }

    @Test("every command that takes positionals names each of them in its usage")
    func positionalsAppearInUsage() throws {
        #expect(positionalPlaceholders.count == 21)
        for (name, placeholders) in positionalPlaceholders {
            let spec = try #require(CommandRegistry.lookup(name: name), "\(name) is not registered")
            for placeholder in placeholders {
                #expect(spec.usage.contains(placeholder),
                        "\(name)'s usage '\(spec.usage)' does not name \(placeholder)")
            }
        }
    }

    @Test("a usage names exactly its command's flags, each with its argument")
    func usageAndFlagsAgree() {
        for spec in CommandRegistry.all {
            #expect(usageFlags(in: spec.usage) == Set(spec.flags.map(\.long)),
                    "\(spec.name): usage flags \(usageFlags(in: spec.usage).sorted()) != spec flags \(spec.flags.map(\.long).sorted())")
            for flag in spec.flags {
                let rendered = flag.argument.map { "--\(flag.long) <\($0)>" } ?? "--\(flag.long)"
                #expect(spec.usage.contains(rendered),
                        "\(spec.name): usage '\(spec.usage)' does not contain '\(rendered)'")
            }
        }
    }

    @Test("--help prints the usage line")
    func helpPrintsUsage() throws {
        let reword = try #require(CommandRegistry.lookup(name: "reword"))
        #expect(renderHelp(for: reword).contains(
            "\nUsage: \(ServiceNames.cliName) reword <commit> --message <message> [--sign | --no-sign]\n"))
        let top = renderHelp(for: CommandRegistry.switchyardSpec)
        #expect(top.contains("\nUsage: \(ServiceNames.cliName) [--help | --version | <command> [<arguments>]]\n"))
        let bare = CommandSpec(name: "bare", summary: "", flags: [], exitCodes: [], schemaName: "")
        #expect(!renderHelp(for: bare).contains("Usage:"), "an empty usage prints no Usage line")
    }

    @Test("every skill section carries its command's usage line")
    func skillSectionsCarryUsage() {
        for spec in CommandRegistry.all {
            #expect(renderSkillSection(for: spec).contains(
                        "\nUsage: `\(ServiceNames.cliName) \(spec.usage)`\n"),
                    "\(spec.name)'s skill section has no usage line")
        }
    }
}
