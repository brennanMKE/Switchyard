// HelpRenderer.swift

import Foundation

/// Renders a `CommandSpec` into human-readable help text.
///
/// Pure function: no I/O, no printing, no argument parsing. Given a spec it returns
/// the exact same `String` every time so callers can assert against the output.
public nonisolated func renderHelp(for spec: CommandSpec) -> String {
    var lines: [String] = []

    // Header.
    let desc: String?
    if !spec.summary.isEmpty {
        desc = spec.summary
    } else {
        desc = nil
    }

    if let desc {
        lines.append("\(spec.name) — \(desc)")
    } else {
        lines.append(spec.name)
    }

    // Flags.
    if !spec.flags.isEmpty {
        lines.append("")
        lines.append("Options:")
        for flag in spec.flags.sorted(by: { $0.long < $1.long }) {
            let flagString = renderFlagLine(flag)
            lines.append("    \(flagString)\t\(flag.help)")
        }
    }

    // Exit codes.
    if !spec.exitCodes.isEmpty {
        lines.append("")
        lines.append("Exit codes:")
        for exitCode in spec.exitCodes.sorted(by: { $0.code < $1.code }) {
            lines.append("    \(exitCode.code)\t\(exitCode.meaning)")
        }
    }

    return lines.joined(separator: "\n") + "\n"
}

// MARK: - Private helpers

private func renderFlagLine(_ flag: FlagSpec) -> String {
    if let short = flag.short {
        return "-\(short), --\(flag.long)"
    } else if let argument = flag.argument {
        return "--\(flag.long) <\(argument)>"
    } else {
        return "--\(flag.long)"
    }
}
