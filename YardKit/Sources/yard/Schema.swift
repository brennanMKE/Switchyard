// Schema.swift - Response schema metadata for the yard CLI.

import Foundation

public typealias Field = SchemaField

public struct SchemaField: Sendable, Equatable {
    public let name: String
    public var required: Bool

    init(_ n: String) {
        self.name = n
        required = false
    }

    init(_ name: String, _ req: Bool) {
        self.name = name
        required = req
    }

    static func opt(_ n: String) -> SchemaField { return SchemaField(n, false) }
    static func req(_ n: String) -> SchemaField { return SchemaField(n, true) }

    var dict: [String: Any] { ["name": name, "required": required as NSNumber] }

    var type: String {
        if name.hasSuffix("Count") || name.hasSuffix("ed") || name == "staleEntries"
           || name == "unreachableEntries" || name == "entriesAffected" || name == "fileCount"
           || name == "successRate" { return "number" }
        if name.hasSuffix("Id") || name.hasSuffix("ID") { return "string" }
        if name == "schemaVersion" { return "number" }
        if name == "ok" { return "boolean" }
        if name.hasPrefix("path") || name.hasPrefix("ref") || name == "branch" { return "string" }
        return "object"
    }
}

public struct ExitCode: Sendable, Equatable {
    public let code: Int32
    public let description: String

    init(_ c: Int32, _ d: String) {
        self.code = c
        self.description = d
    }

    static func success() -> ExitCode { return ExitCode(0, "Success") }
}

public struct Flag: Sendable, Equatable {
    public let name: String
    public var required: Bool

    init(_ n: String) { self.name = n; required = false }
    init(_ name: String, _ req: Bool) { self.name = name; required = req }

    static func opt(_ n: String) -> Flag { return Flag(n, false) }
    static func req(_ n: String) -> Flag { return Flag(n, true) }

    var dict: [String: Any] { ["name": name, "required": required as NSNumber] }

    static let json_ = Flag("--json", false)
}

public struct CommandSchema: Sendable, Equatable {
    public let successFields: [Field]

    init() { self.successFields = [] }
    init(fields: Field...) { self.successFields = fields }

    init(_ names: String...) { successFields = names.map(Field.init) }

    var dict: [String: Any] { ["successFields": successFields.map(\.dict)] }
}
