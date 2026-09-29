// SkillGoldenTests.swift — the drift gate for skills/switchyard/SKILL.md (#0066)

import Foundation
import Testing
@testable import YardKit

/// `skills/switchyard/SKILL.md` at the repository root, resolved from this
/// file's compile-time path: `YardKit/Tests/YardKitTests/SkillGoldenTests.swift`
/// → up four → repository root.
private let skillFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // YardKitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // YardKit (package root)
    .deletingLastPathComponent()   // repository root
    .appendingPathComponent("skills/switchyard/SKILL.md")

/// Registry names plus the flags every command accepts (`--json`, #0420).
private let globalFlags: Set<String> = ["json"]

@Suite("Agent skill")
struct SkillGoldenTests {

    /// The drift gate. `SKILL_REGENERATE=1` rewrites the file first; that is
    /// what `scripts/generate-skill.sh` sets.
    @Test("the committed SKILL.md byte-matches renderSkill()")
    func committedSkillMatchesRenderer() throws {
        let rendered = renderSkill()
        if ProcessInfo.processInfo.environment["SKILL_REGENERATE"] == "1" {
            try FileManager.default.createDirectory(
                at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.write(to: skillFile, atomically: true, encoding: .utf8)
        }
        let committed = try String(contentsOf: skillFile, encoding: .utf8)
        #expect(committed == rendered,
                "skills/switchyard/SKILL.md is stale. Edit CommandRegistry.swift or SkillProse.swift, never SKILL.md, then run scripts/generate-skill.sh.")
    }

    /// Independent of the golden file, so a regenerate cannot launder a
    /// renderer that drops content: every command, flag and exit code in the
    /// registry is in the rendered text, inside the generated markers.
    @Test("every registered command, flag and exit code appears in the generated half")
    func everyCommandFlagAndExitCodeAppears() throws {
        let rendered = renderSkill()
        let begin = try #require(rendered.range(of: skillGeneratedBeginMarker))
        let end = try #require(rendered.range(of: skillGeneratedEndMarker))
        #expect(begin.upperBound < end.lowerBound)
        let generated = String(rendered[begin.upperBound..<end.lowerBound])

        #expect(!CommandRegistry.all.isEmpty, "an empty registry would make this test vacuous")
        for spec in CommandRegistry.all {
            let section = renderSkillSection(for: spec)
            #expect(generated.contains(section), "\(spec.name)'s section is missing")
            let heading = spec.name == ServiceNames.cliName
                ? "### `\(ServiceNames.cliName)`"
                : "### `\(ServiceNames.cliName) \(spec.name)`"
            #expect(section.hasPrefix(heading + "\n"), "\(spec.name): heading is \(section.prefix(60))")
            for flag in spec.flags {
                #expect(section.contains("`--\(flag.long)") || section.contains(", --\(flag.long)"),
                        "\(spec.name): --\(flag.long) is missing")
            }
            for exitCode in spec.exitCodes {
                #expect(section.contains("\n| \(exitCode.code) | "),
                        "\(spec.name): exit \(exitCode.code) is missing")
            }
            for field in spec.payload?.fields ?? [] {
                #expect(section.contains("| `\(field.name)` |"), "\(spec.name): field \(field.name) is missing")
            }
        }
    }

    @Test("the generated half has exactly one section per registered command")
    func noSectionForAnUnregisteredCommand() throws {
        let headings = renderSkill().split(separator: "\n").filter { $0.hasPrefix("### `\(ServiceNames.cliName)") }
        #expect(headings.count == CommandRegistry.all.count,
                "headings: \(headings.count), registry: \(CommandRegistry.all.count)")
    }

    /// #0102 renamed the binary; a stale `yard <command>` in any registry
    /// string would teach an agent a command that does not exist.
    @Test("the skill never names the retired yard binary")
    func noRetiredBinaryName() {
        let rendered = renderSkill()
        #expect(rendered.range(of: #"(^|[^A-Za-z-])yard [a-z]"#, options: .regularExpression) == nil)
    }

    @Test("the file opens with name and description front matter")
    func frontMatterNamesTheSkill() {
        let lines = renderSkill().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        #expect(lines.dropFirst().first == "name: \(ServiceNames.cliName)")
        let description = lines.dropFirst(2).first ?? ""
        #expect(description.hasPrefix("description: "))
        // OpenCode's limit (1–1024 characters) is the tighter of the two
        // loaders'; Claude Code's is 1536.
        #expect(description.dropFirst("description: ".count).count <= 1024)
        #expect(lines.dropFirst(3).first == "---")
    }

    /// The hand-written prose may not invent a command or flag. Every line of
    /// SkillProse that invokes `switchyard <command>` must name a registered
    /// command, and every `--flag` on that line must be one of its flags.
    @Test("every switchyard invocation in the hand-written prose names a real command and real flags")
    func proseNamesOnlyRealCommandsAndFlags() {
        let prose = SkillProse.introduction + SkillProse.workflows
        let invocations = proseInvocations(in: prose)
        #expect(invocations.count >= 5, "the prose guard found only \(invocations.count) invocations")
        for line in invocations {
            let tokens = line.split(separator: " ").map(String.init)
            let twoWord = tokens.count > 2 ? "\(tokens[1]) \(tokens[2])" : ""
            guard let spec = CommandRegistry.lookup(name: twoWord)
                    ?? CommandRegistry.lookup(name: tokens.count > 1 ? tokens[1] : "") else {
                Issue.record("prose invokes an unregistered command: \(line)")
                continue
            }
            let known = Set(spec.flags.map(\.long)).union(globalFlags)
            for token in tokens where token.hasPrefix("--") {
                #expect(known.contains(String(token.dropFirst(2))),
                        "prose passes \(token) to \(spec.name), which has no such flag: \(line)")
            }
        }
    }
}

/// Lines of `text` that start (after indentation) with `switchyard `: the
/// fenced-code examples. Inline backticked `switchyard x` mentions are
/// extracted too, up to the closing backtick.
func proseInvocations(in text: String) -> [String] {
    var found: [String] = []
    let prefix = "\(ServiceNames.cliName) "
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(prefix) { found.append(line); continue }
        var rest = Substring(line)
        while let open = rest.range(of: "`" + prefix) {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "`") else { break }
            found.append(prefix + after[..<close])
            rest = after[after.index(after: close)...]
        }
    }
    return found
}
