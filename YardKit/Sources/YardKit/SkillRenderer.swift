// SkillRenderer.swift

import Foundation

/// Renders the agent skill, `skills/switchyard/SKILL.md`, from the command
/// registry plus the hand-written prose in `SkillProse`. Guide §8 and §11
/// decision 31: the reference half is generated from `CommandRegistry.all` —
/// the same data `--help` and `schema` read — so it cannot drift from the
/// binary; the judgment half is hand-written in `SkillProse.swift`.
///
/// Pure function: no I/O. `SkillGoldenTests` holds the committed file to this
/// output byte for byte, and `switchyard skill` (#0067) prints it.
public nonisolated func renderSkill() -> String {
    var out = SkillProse.frontMatter
    out += "\n"
    out += SkillProse.introduction
    out += "\n"
    out += SkillProse.workflows
    out += "\n"
    out += skillGeneratedBeginMarker + "\n\n"
    out += "## Command reference\n\n"
    out += "Every command prints one JSON envelope on stdout: "
    out += "`{\"schemaVersion\":1,\"ok\":true,\"result\":…}` on success, "
    out += "`{\"schemaVersion\":1,\"ok\":false,\"error\":{\"code\":…,\"message\":…,\"hint\":…}}` on failure. "
    out += "`--json` is accepted anywhere and changes nothing. "
    out += "`\(ServiceNames.cliName) schema` prints the full JSON Schema for every command.\n"
    for spec in CommandRegistry.all {
        out += "\n" + renderSkillSection(for: spec)
    }
    out += "\n" + skillGeneratedEndMarker + "\n"
    return out
}

/// The markers around the generated half. Nothing between them is edited by
/// hand; `SkillGoldenTests` fails on any difference.
let skillGeneratedBeginMarker =
    "<!-- BEGIN GENERATED from CommandRegistry.all — edit YardKit/Sources/YardKit/CommandRegistry.swift, then run scripts/generate-skill.sh -->"
let skillGeneratedEndMarker = "<!-- END GENERATED -->"

/// One command's section: heading, summary, usage, flags, exit codes, result fields.
nonisolated func renderSkillSection(for spec: CommandSpec) -> String {
    let invocation = spec.name == ServiceNames.cliName
        ? ServiceNames.cliName
        : "\(ServiceNames.cliName) \(spec.name)"
    var lines: [String] = ["### `\(invocation)`", "", spec.summary]

    if !spec.usage.isEmpty {
        lines += ["", "Usage: `\(ServiceNames.cliName) \(spec.usage)`"]
    }

    if !spec.flags.isEmpty {
        lines += ["", "| Flag | Meaning |", "|---|---|"]
        for flag in spec.flags.sorted(by: { $0.long < $1.long }) {
            var name = "--\(flag.long)"
            if let argument = flag.argument { name += " <\(argument)>" }
            if let short = flag.short { name = "-\(short), " + name }
            lines.append("| `\(name)` | \(tableCell(flag.help)) |")
        }
    }

    lines += ["", "| Exit | Meaning |", "|---|---|"]
    for exitCode in spec.exitCodes.sorted(by: { $0.code < $1.code }) {
        lines.append("| \(exitCode.code) | \(tableCell(exitCode.meaning)) |")
    }

    if let payload = spec.payload {
        lines += ["", "| Result field | Type | Meaning |", "|---|---|---|"]
        for field in payload.fields.sorted(by: { $0.name < $1.name }) {
            var type = field.type.rawValue
            if !field.enumCases.isEmpty { type += " (" + field.enumCases.sorted().joined(separator: ", ") + ")" }
            if field.optional { type += ", optional" }
            lines.append("| `\(field.name)` | \(tableCell(type)) | \(tableCell(field.description)) |")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// A markdown table cell: no raw newline, no unescaped pipe.
private nonisolated func tableCell(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "|", with: "\\|")
}
