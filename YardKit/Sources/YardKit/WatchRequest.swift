// WatchRequest.swift — the watch wire (#0058)
//
// The Codable types both sides of the watch exchange share, plus the client
// protocol the CLI EXPORTS. Watch is the one M4 command with a real
// long-lived session: the CLI connects, exports a `WatchClientProtocol`
// object, and calls `AppServiceProtocol.performWatch` — and from then on the
// app PUSHES events to the client (NSXPCConnection's reverse direction: the
// client side exports, the server side calls the proxy it was handed), while
// the method's reply block stays pending until the session ends.
//
// Wire rules this file follows, from the established conventions:
// - #0130: structs declare explicit `CodingKeys`, so a property rename can
//   never silently change the wire key.
// - #0129 Decision 4: absent means absent. Optional properties are omitted
//   from the wire when nil — synthesized `Codable` does this — and are
//   never encoded as `null`.
//
// `NSXPCInterface` cannot carry a Swift struct across the boundary, so these
// types travel as JSON in the protocol method's `Data` parameters — the same
// reason `performReview` carries envelope bytes rather than a typed request.

import Foundation

/// What a CLI asks the app to stream, and for how long.
///
/// `repositoryPath` selects the stream's scope: nil is the all-repositories
/// selector, a path is that one repository (matched against the event's
/// repository path exactly in this round — normalization is deliberately not
/// here yet). `timeoutSeconds` nil means "until detached": the session runs
/// until the CLI detaches (Ctrl-C or exit), the app ends it, or the app
/// quits. A value arms the app-side session store's own timer — the typed
/// `.timedOut` end — so the CLI's wait has a peer-side bound even if its own
/// deadline machinery were lost.
public struct WatchRequest: Codable, Equatable, Sendable {

    /// The repository root path to watch, or nil to watch every repository
    /// the app knows about.
    public var repositoryPath: String?

    /// Seconds until the app ends the session with `.timedOut`, or nil to
    /// run until detached.
    public var timeoutSeconds: Int?

    public init(repositoryPath: String?, timeoutSeconds: Int?) {
        self.repositoryPath = repositoryPath
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case repositoryPath
        case timeoutSeconds
    }
}

/// One JSON value, as the watch event's payload needs it.
///
/// The payload of a `journal_observed` event is a `JournalObserved.Metadata`
/// JSON object, and `YardKit` does not link `YardGit` (layering) — so the
/// payload travels as plain JSON rather than a typed engine struct. This
/// enum carries it losslessly: the event's wire form embeds the payload as a
/// nested JSON object (never an escaped string — the stream's contract is
/// "each line parses as JSON", and a consumer must not have to
/// double-decode), and a consumer that wants fields reads them back typed.
///
/// `Int` before `Double` in decoding because integral JSON numbers must
/// survive as integers (`sequence`-like fields, counts); a fractional number
/// fails the `Int` cast and lands on `Double`. `Bool` before both because
/// JSONDecoder refuses to decode `true` as a number, so the bool case is
/// unambiguous wherever it is tried first.
public enum WatchJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([WatchJSON])
    case object([String: WatchJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WatchJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: WatchJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "value is not a JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Bridges JSONSerialization output — the form arbitrary JSON bytes
    /// decode to — into a typed object payload. Fails when the bytes are not
    /// JSON or their top level is not an object: a watch event's payload is
    /// an object by contract, and a non-object payload would encode an event
    /// the wire shape does not describe.
    public static func object(fromJSON data: Data) throws -> [String: WatchJSON] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw WatchWireError.invalidJSON
        }
        guard let dictionary = root as? [String: Any] else {
            throw WatchWireError.payloadNotAnObject
        }
        return try bridgedObject(dictionary)
    }

    private static func bridgedObject(_ dictionary: [String: Any]) throws -> [String: WatchJSON] {
        var result: [String: WatchJSON] = [:]
        for (key, value) in dictionary {
            result[key] = try bridged(value)
        }
        return result
    }

    private static func bridged(_ value: Any) throws -> WatchJSON {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // NSNumber bridges Bool, Int, and Double alike; CFBoolean is the
            // only reliable discriminator (a `Bool` cast would also accept
            // 0 and 1, corrupting int payloads into bools).
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let integer = Int(exactly: number) {
                return .int(integer)
            }
            return .double(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map { try bridged($0) })
        case let dictionary as [String: Any]:
            return .object(try bridgedObject(dictionary))
        default:
            throw WatchWireError.unbridgableValue
        }
    }
}

/// Why a watch payload could not be built from bytes.
public enum WatchWireError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The bytes are not JSON at all.
    case invalidJSON
    case payloadNotAnObject
    case unbridgableValue

    public var description: String {
        switch self {
        case .invalidJSON:
            "watch event payload is not valid JSON"
        case .payloadNotAnObject:
            "watch event payload must be a JSON object"
        case .unbridgableValue:
            "watch event payload contained a value JSON cannot carry"
        }
    }
}

/// One streamed event.
///
/// `sequence` is the ordering and no-drop contract: the app-side session
/// store numbers every event per session, starting at 1, monotonic without
/// gaps — a consumer asserting `1...N` in arrival order proves both
/// properties end to end. `kind` names the source; `payload` is the
/// source-specific JSON object (`journal_observed` carries the
/// `JournalObserved.Metadata` shape, `app_event` is the app-side synthetic
/// kind the tests and app activity inject).
public struct WatchEvent: Codable, Equatable, Sendable {

    /// What produced the event. Raw values are the wire spellings.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A journal-observed entry — the hook layer's record of a foreign
        /// ref transaction or rewrite (#0042/#0153). The payload is the
        /// entry's `JournalObserved.Metadata` JSON.
        case journalObserved = "journal_observed"
        /// App-side activity. FSEvents is NOT in this round; it is a source
        /// this command can grow later.
        case appEvent = "app_event"
    }

    /// Per-session monotonic sequence number, starting at 1.
    public var sequence: Int

    /// The event's source.
    public var kind: Kind

    /// The source-specific JSON object.
    public var payload: [String: WatchJSON]

    public init(sequence: Int, kind: Kind, payload: [String: WatchJSON]) {
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case kind
        case payload
    }
}

/// Why the app ended a watch session. Tagged like `AskOutcome` — each reason
/// is its own key, so a session end is never bytes-shaped like another
/// reason.
public enum WatchEndReason: Codable, Equatable, Sendable {

    /// The CLI detached (its connection went away). The app drops the
    /// session without further pushes; nothing over the wire carries this to
    /// a dead peer, but the store's await resolves with it so the session
    /// body completes.
    case detached

    /// The session's own timeout expired — the CLI's `--timeout` as armed
    /// app-side. A clean end: the CLI exits 0, never an error.
    case timedOut

    /// The app is going away and terminated the session. The CLI exits 5 —
    /// the stream ended by app decision, never a detach.
    case appShutdown

    private enum CodingKeys: String, CodingKey {
        case detached
        case timedOut
        case appShutdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.detached) {
            self = .detached
        } else if container.contains(.timedOut) {
            self = .timedOut
        } else if container.contains(.appShutdown) {
            self = .appShutdown
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected one of \"detached\", \"timedOut\", \"appShutdown\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .detached:
            try container.encode(true, forKey: .detached)
        case .timedOut:
            try container.encode(true, forKey: .timedOut)
        case .appShutdown:
            try container.encode(true, forKey: .appShutdown)
        }
    }
}

/// What the app pushes to on a watch session — the object the CLI EXPORTS.
///
/// This is the reverse direction of every other call in
/// `AppServiceProtocol`: there, the CLI holds a proxy to the app's exported
/// `AppService` and calls it; here, the CLI sets
/// `NSXPCConnection.exportedInterface`/`exportedObject` on its own
/// connection and the app, inside `performWatch(request:client:reply:)`,
/// receives a proxy typed as this protocol and calls ITS methods to push.
/// Both methods are one-way (no reply blocks): events flow at the app's
/// pace, and the session's end is carried by the `performWatch` reply.
@objc public protocol WatchClientProtocol: NSObjectProtocol {

    /// One streamed event, JSON-encoded `WatchEvent` bytes. The CLI writes
    /// the bytes to stdout as one newline-delimited line, as it arrives.
    func event(_ data: Data)

    /// The session ended; the bytes are JSON-encoded `WatchEndReason` — the
    /// same reason the `performWatch` reply carries. The app calls this
    /// before replying, so a client that only listens (no reply await) also
    /// learns the end.
    func sessionEnded(reason: Data)
}
