// AskRequest.swift — the ask wire (#0056)
//
// The Codable types both sides of the ask exchange share: the CLI encodes
// an `AskRequest` and sends it over `AppServiceProtocol.performAsk`; the
// app replies JSON-encoded `AskOutcome` bytes, which either carry the
// human's `AskReply` or name — as a typed value, never a decision-shaped
// lie — why no reply came.
//
// `ask` is `review` (#0055) minus the diff, with a QUEUE instead of
// supersede: a second ask for a repository that already has one pending
// queues rather than replacing it, so `AskOutcome` has no `superseded`
// case — a queued wait is never resolved by another request, only by the
// human, its own timeout, or the connection dying.
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

/// What a CLI asks the app to put before the human, and how long it will wait.
public struct AskRequest: Codable, Equatable, Sendable {

    /// The repository's git common dir — the repository identity the app keys
    /// tabs on (#0079). The CLI cannot resolve this (it does not link the
    /// engine), so it sends an empty string here and passes its working
    /// directory as `performAsk`'s own parameter; the app-side body
    /// (`runAskRequest`, YardCommands) resolves the repository and fills
    /// this in before the request is registered or shown to the human.
    public var commonDir: String

    /// The question, rendered to the human verbatim — never as markup or a
    /// link, because it comes from an agent and is untrusted input.
    public var question: String

    /// The answer options, in the order they are presented. An index into
    /// this array is what the reply carries, so reordering options between
    /// the ask and the reply would be a bug the reply could not survive —
    /// the array is fixed at registration time.
    public var options: [String]

    /// How long the CLI waits for the human, in seconds. The app arms the
    /// pending ask with the same duration — but only once the ask reaches
    /// the head of its repository's queue (see `PendingAskStore`), so the
    /// typed timeout normally arrives before the CLI's own backstop
    /// (`--timeout` + 5 s) for the ask that is actually being presented.
    public var timeoutSeconds: Int

    public init(commonDir: String, question: String, options: [String], timeoutSeconds: Int) {
        self.commonDir = commonDir
        self.question = question
        self.options = options
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case commonDir
        case question
        case options
        case timeoutSeconds
    }
}

/// The human's answer. The chosen option travels as its INDEX plus its text
/// — the index is what survives option reordering and is unambiguous; the
/// text is what an agent reads without re-fetching the request. Declining is
/// a decided reply with declined semantics (the CLI exits 7), never a
/// timeout: the human was present and answered "no".
public struct AskReply: Codable, Equatable, Sendable {

    /// The chosen option's index into the request's `options`. Absent when
    /// the human declined — there is no chosen option then.
    public var optionIndex: Int?

    /// The chosen option's text, echoed from `options[optionIndex]`. Absent
    /// when the human declined.
    public var optionText: String?

    /// The free text the human typed alongside the answer or the decline,
    /// when they typed anything. Absent means absent — never `null`.
    public var message: String?

    /// True when the human declined to answer. Absent (false) when they
    /// picked an option. A declined reply still resolves the queue — the
    /// next ask for the repository, if any, is presented.
    public var declined: Bool?

    /// The reply for a picked option. `message` is nil when the human typed
    /// nothing.
    public static func chosen(index: Int, text: String, message: String? = nil) -> AskReply {
        AskReply(optionIndex: index, optionText: text, message: message, declined: nil)
    }

    /// The reply for a decline, with or without an explanation.
    public static func declined(message: String? = nil) -> AskReply {
        AskReply(optionIndex: nil, optionText: nil, message: message, declined: true)
    }

    public init(
        optionIndex: Int?,
        optionText: String?,
        message: String?,
        declined: Bool?
    ) {
        self.optionIndex = optionIndex
        self.optionText = optionText
        self.message = message
        self.declined = declined
    }

    private enum CodingKeys: String, CodingKey {
        case optionIndex
        case optionText
        case message
        case declined
    }
}

/// What the app resolved a pending ask to — the wire form of the pending
/// store's outcome. `timedOut` is a typed value precisely so an unanswered
/// wait is never encoded as a decision: conflating "nobody answered" with
/// "the human said no" would be a serious bug, because an agent would treat
/// a timeout as the human's actual word. There is no `superseded`: asks for
/// the same repository queue instead of replacing each other (#0056).
public enum AskOutcome: Codable, Equatable, Sendable {

    /// The human decided — picked an option or declined; the reply is
    /// their answer, and `declined` on it is what the CLI maps to exit 7.
    case decided(AskReply)

    /// The pending ask's own timeout fired before the human decided.
    case timedOut

    private enum CodingKeys: String, CodingKey {
        case decided
        case timedOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.decided) {
            self = .decided(try container.decode(AskReply.self, forKey: .decided))
        } else if container.contains(.timedOut) {
            self = .timedOut
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected one of \"decided\" or \"timedOut\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .decided(let reply):
            try container.encode(reply, forKey: .decided)
        case .timedOut:
            try container.encode(true, forKey: .timedOut)
        }
    }
}
