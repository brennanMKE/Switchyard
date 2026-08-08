// RefSnapshotSerialization.swift — the refs blob: a RefSnapshot as bytes (#0165)

import Foundation

/// The serialized form of a `RefSnapshot` — the bytes stored as the `refs`
/// blob in every journal snapshot commit (`JournalAnchor.refsTreeEntryName`),
/// and read back by restore. The format is wire contract: #0030's rebuild
/// recovers it from refs alone with `git cat-file blob <anchor-ref>:refs`,
/// so its shape may only change behind a new version number.
///
/// A line format rather than JSON, deliberately:
///
/// - `git cat-file blob` output is directly readable by a human inspecting a
///   snapshot, in the same `<oid> SP <refname>` shape `for-each-ref` prints.
/// - Ref names cannot contain space, NUL, or newline (git-check-ref-format),
///   so single-space separation parses unambiguously with no quoting layer.
/// - The bytes are deterministic for a given snapshot: entries serialize in
///   array order, which capture produces refname-sorted.
///
/// The format, one line each, every line `LF`-terminated:
///
/// ```
/// switchyard-refs 1
/// head symbolic refs/heads/main      (or: head detached <oid>)
/// <oid> <refname>                    (zero or more, in snapshot order)
/// ```
extension RefSnapshot {

    /// First line of every serialized snapshot: format name and version.
    /// A reader refuses anything else — a future version 2 must be a new
    /// header, never a silent reinterpretation of these bytes.
    public static let serializationHeader = "switchyard-refs 1"

    public enum SerializationError: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// The bytes are not UTF-8. No git ref state produces this; it means
        /// the blob is not a refs blob at all.
        case notUTF8
        /// Empty, or missing the final newline every line carries — the
        /// shape a partially written blob would have.
        case truncated
        /// The first line is not `serializationHeader` — either a foreign
        /// blob or a version this build does not read.
        case unsupportedHeader(String)
        /// The second line does not parse as `head symbolic <target>` or
        /// `head detached <oid>`.
        case malformedHead(String)
        /// A ref line does not parse as `<oid> SP <refname>`.
        case malformedRef(String)

        public var description: String {
            switch self {
            case .notUTF8:
                "serialized ref snapshot is not UTF-8"
            case .truncated:
                "serialized ref snapshot is empty or missing its final newline"
            case let .unsupportedHeader(line):
                "unsupported ref snapshot header: \(line)"
            case let .malformedHead(line):
                "unparseable ref snapshot head line: \(line)"
            case let .malformedRef(line):
                "unparseable ref snapshot ref line: \(line)"
            }
        }
    }

    // MARK: - Writing

    /// The snapshot as bytes, ready for `git hash-object -w --stdin`.
    public func serialized() -> Data {
        var text = Self.serializationHeader + "\n"
        switch head {
        case let .symbolic(target):
            text += "head symbolic \(target)\n"
        case let .detached(oid):
            text += "head detached \(oid)\n"
        }
        for entry in refs {
            text += "\(entry.oid) \(entry.name)\n"
        }
        return Data(text.utf8)
    }

    // MARK: - Reading

    /// Parses bytes `serialized()` wrote. Strict on purpose: a refs blob a
    /// restore is about to apply is the wrong place to guess, so anything
    /// unexpected is a thrown `SerializationError`, never a skipped line —
    /// silently dropping a ref here is silent data loss on restore.
    public init(serialized data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SerializationError.notUTF8
        }
        guard text.hasSuffix("\n") else {
            throw SerializationError.truncated
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeLast() // the empty piece after the final newline

        guard lines.first == Self.serializationHeader else {
            throw SerializationError.unsupportedHeader(lines.first ?? "")
        }
        guard lines.count >= 2 else {
            throw SerializationError.malformedHead("")
        }
        let headFields = lines[1].split(separator: " ", omittingEmptySubsequences: false)
        guard headFields.count == 3, headFields[0] == "head", !headFields[2].isEmpty else {
            throw SerializationError.malformedHead(lines[1])
        }
        let head: Head
        switch headFields[1] {
        case "symbolic":
            head = .symbolic(target: String(headFields[2]))
        case "detached":
            head = .detached(oid: String(headFields[2]))
        default:
            throw SerializationError.malformedHead(lines[1])
        }

        var refs: [Entry] = []
        for line in lines.dropFirst(2) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw SerializationError.malformedRef(line)
            }
            refs.append(Entry(name: String(fields[1]), oid: String(fields[0])))
        }
        self.init(head: head, refs: refs)
    }
}

// MARK: - §6 exit class (#0141)

/// A blob that does not parse is repository-state damage — guide §6 code 6,
/// the same class as every other unreadable piece of this repository.
extension RefSnapshot.SerializationError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
