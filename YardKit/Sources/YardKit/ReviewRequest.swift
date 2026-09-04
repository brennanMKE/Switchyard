// ReviewRequest.swift — the review wire (#0055)
//
// The Codable types both sides of the review exchange share: the CLI encodes
// a `ReviewRequest` and sends it over `AppServiceProtocol.performReview`;
// the app replies JSON-encoded `ReviewOutcome` bytes, which either carry the
// human's `ReviewReply` or name — as a typed value, never a decision-shaped
// lie — why no reply came.
//
// Wire rules this file follows, from the established conventions:
// - #0130: structs declare explicit `CodingKeys`, so a property rename can
//   never silently change the wire key. `ReviewDecision`'s case name IS the
//   wire key (a String raw value, pinned byte-for-byte by ReviewWireTests).
// - #0129 Decision 4: absent means absent. Optional properties are omitted
//   from the wire when nil — synthesized `Codable` does this — and are never
//   encoded as `null`.
//
// `NSXPCInterface` cannot carry a Swift struct across the boundary, so these
// types travel as JSON in the protocol method's `Data` parameters — the same
// reason `perform` carries envelope bytes rather than a typed envelope.

import Foundation

/// What a CLI asks the app to review, and how long it will wait.
public struct ReviewRequest: Codable, Equatable, Sendable {

    /// The repository's git common dir — the repository identity the app keys
    /// tabs on (#0079). The CLI cannot resolve this (it does not link the
    /// engine), so it sends an empty string here and passes its working
    /// directory as `performReview`'s own parameter; the app-side body
    /// (`runReviewRequest`, YardCommands) resolves the repository and fills
    /// this in before the request is registered or shown to the human.
    public var commonDir: String

    /// What to diff: the staged changes, or a commit range.
    public var selector: ReviewSelector

    /// How long the CLI waits for the human, in seconds. The app arms the
    /// pending review with the same duration, so the typed timeout normally
    /// arrives before the CLI's own backstop (`--timeout` + 5 s).
    public var timeoutSeconds: Int

    public init(commonDir: String, selector: ReviewSelector, timeoutSeconds: Int) {
        self.commonDir = commonDir
        self.selector = selector
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case commonDir
        case selector
        case timeoutSeconds
    }
}

/// The range-or-`--staged` half of a review request, encoded so the two forms
/// cannot be confused: an object with exactly one key. A bare string would be
/// ambiguous — `git rev-list staged` is a legal branch name.
public enum ReviewSelector: Codable, Equatable, Sendable {

    /// `--staged`: diff HEAD against the index.
    case staged

    /// A commit range, e.g. `main..HEAD`.
    case range(String)

    private enum CodingKeys: String, CodingKey {
        case staged
        case range
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.staged) {
            self = .staged
        } else if let range = try container.decodeIfPresent(String.self, forKey: .range) {
            self = .range(range)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected exactly one of \"staged\" or \"range\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .staged:
            try container.encode(true, forKey: .staged)
        case .range(let value):
            try container.encode(value, forKey: .range)
        }
    }
}

/// The human's decision. Closed — a future decision is a wire change, not a
/// free-text value. The case name IS the wire key (#0130).
public enum ReviewDecision: String, Codable, Sendable, CaseIterable {
    case approve
    case reject
    case amend
}

/// One per-hunk or per-line comment the human attached to the diff.
public struct ReviewComment: Codable, Equatable, Sendable {

    /// The file the comment is on, repository-relative.
    public var path: String

    /// The hunk the comment is on, as the diff names it.
    public var hunkID: String

    /// The file line the comment attaches to, when the comment is per-line
    /// rather than per-hunk. Absent means absent — never `null`.
    public var line: Int?

    /// What the human wrote.
    public var text: String

    public init(path: String, hunkID: String, line: Int? = nil, text: String) {
        self.path = path
        self.hunkID = hunkID
        self.line = line
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case hunkID
        case line
        case text
    }
}

/// The human's answer: the decision, what they typed alongside it, their
/// structured comments, and — for `amend` — the edited patch.
public struct ReviewReply: Codable, Equatable, Sendable {

    public var decision: ReviewDecision

    /// The free text the human typed alongside the decision, when they typed
    /// anything. Absent means absent — never `null`.
    public var message: String?

    /// Per-hunk and per-line comments, possibly empty.
    public var comments: [ReviewComment]

    /// The patch the human edited, for the `amend` decision. Absent means
    /// absent — never `null`.
    public var editedPatch: String?

    public init(
        decision: ReviewDecision,
        message: String? = nil,
        comments: [ReviewComment] = [],
        editedPatch: String? = nil
    ) {
        self.decision = decision
        self.message = message
        self.comments = comments
        self.editedPatch = editedPatch
    }

    private enum CodingKeys: String, CodingKey {
        case decision
        case message
        case comments
        case editedPatch
    }
}

/// What the app resolved a pending review to — the wire form of the pending
/// store's outcome. `timedOut` and `superseded` are typed values precisely so
/// an unanswered or replaced wait is never encoded as a decision: conflating
/// "app died" (or "nobody answered") with "human rejected" would be a serious
/// bug, because an agent would treat a crash or a timeout as a considered
/// decision.
public enum ReviewOutcome: Codable, Equatable, Sendable {

    /// The human decided; the reply is their answer.
    case decided(ReviewReply)

    /// The pending review's own timeout fired before the human decided.
    case timedOut

    /// A newer review request for the same repository replaced this one.
    case superseded

    private enum CodingKeys: String, CodingKey {
        case decided
        case timedOut
        case superseded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.decided) {
            self = .decided(try container.decode(ReviewReply.self, forKey: .decided))
        } else if container.contains(.timedOut) {
            self = .timedOut
        } else if container.contains(.superseded) {
            self = .superseded
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected one of \"decided\", \"timedOut\", \"superseded\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .decided(let reply):
            try container.encode(reply, forKey: .decided)
        case .timedOut:
            try container.encode(true, forKey: .timedOut)
        case .superseded:
            try container.encode(true, forKey: .superseded)
        }
    }
}
