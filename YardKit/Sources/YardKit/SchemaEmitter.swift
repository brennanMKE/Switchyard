// SchemaEmitter.swift

import Foundation

/// Renders a `CommandSpec` into a JSON Schema description of that command's response envelope.
///
/// Pure function: no I/O, no printing. Given a spec it returns pretty-printed JSON with sorted
/// keys so the output is byte-stable across runs — callers can diff it, commit it alongside
/// docs/contracts/, and assert on its shape.
public nonisolated func renderSchema(for spec: CommandSpec) -> String {
    let payload: [String: Any] = [
        "command": spec.name,
        "exitCodes": spec.exitCodes.sorted(by: { $0.code < $1.code }).map { exitCode in
            return ["code": exitCode.code, "meaning": exitCode.meaning] as [String: Any]
        },
        "flags": spec.flags.sorted(by: { $0.long < $1.long }).map { flag in
            var f: [String: Any] = [
                "argument": flag.argument as Any,
                "help": flag.help,
                "long": flag.long,
            ]
            if let short = flag.short {
                f["short"] = String(short) as Any
            } else {
                f["short"] = NSNull()
            }
            return f as [String: Any]
        },
        "schemaName": spec.schemaName,
        "schemaVersion": EnvelopeSchema.v1.rawValue,
        "summary": spec.summary,
    ]

    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}
