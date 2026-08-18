// SchemaEmitter.swift

import Foundation

/// Renders a `CommandSpec` into a JSON Schema description of that command's response envelope.
///
/// Pure function: no I/O, no printing. Given a spec it returns pretty-printed JSON with sorted
/// keys so the output is byte-stable across runs — callers can diff it, commit it alongside
/// docs/contracts/, and assert on its shape.
public nonisolated func renderSchema(for spec: CommandSpec) throws -> String {
    let payload: [String: Any] = [
        "command": spec.name,
        "envelope": envelopeShapes(schemaName: spec.schemaName, payload: spec.payload),
        "exitCodes": spec.exitCodes.sorted(by: { $0.code < $1.code }).map { exitCode in
            return ["code": exitCode.code, "meaning": exitCode.meaning] as [String: Any]
        },
        "flags": spec.flags.sorted(by: { $0.long < $1.long }).map { flag in
            var f: [String: Any] = [
                "argument": flag.argument.map { $0 as Any } ?? NSNull(),
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

    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw SchemaError.encodingFailed
    }
    return text
}

/// The two response shapes every command shares: the success envelope and the
/// failure envelope. Emitted into each command's schema so one schema file
/// describes that command's full stdout contract on its own. The key sets
/// declared here are asserted against a real encoded `Envelope` and
/// `EnvelopeFail` in `SchemaGoldenTests` — the schema cannot describe an
/// envelope the code does not emit.
///
/// `result` renders one of two ways (#0194): when `payload` is `nil`, the
/// historical self-reference `{"optional": true, "schema": schemaName}` —
/// correct for a command with no payload to describe, like `noop`. When
/// `payload` is supplied, `{"optional": true, "fields": [...]}` with one
/// rendered entry per `PayloadField`, sorted by field name for byte-stable
/// output.
nonisolated func envelopeShapes(schemaName: String, payload: PayloadShape?) -> [String: Any] {
    var success: [String: Any] = ["ok": true, "schemaVersion": EnvelopeSchema.v1.rawValue]
    if let payload {
        success["result"] = [
            "optional": true,
            "fields": payload.fields.sorted(by: { $0.name < $1.name }).map(renderPayloadField),
        ]
    } else {
        success["result"] = ["optional": true, "schema": schemaName]
    }

    return [
        "failure": [
            "error": [
                "code": [
                    "enum": EnvelopeErrorCode.allCases.map(\.rawValue).sorted(),
                    "type": "string",
                ],
                "hint": ["optional": true, "type": "string"],
                "message": ["type": "string"],
            ],
            "ok": false,
            "schemaVersion": EnvelopeSchema.v1.rawValue,
        ],
        "success": success,
    ]
}

/// Renders one `PayloadField` the way `error.code` is already rendered above:
/// a closed enum is `type: "string"` plus a non-empty `enum` key, not a
/// distinct JSON type.
private nonisolated func renderPayloadField(_ field: PayloadField) -> [String: Any] {
    var rendered: [String: Any] = [
        "name": field.name,
        "type": field.type.rawValue,
        "optional": field.optional,
        "description": field.description,
    ]
    if !field.enumCases.isEmpty {
        rendered["enum"] = field.enumCases.sorted()
    }
    return rendered
}

private enum SchemaError: Error { case encodingFailed }
