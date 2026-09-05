// ResolveRequest.swift — the resolve wire (#0057)
//
// The Codable types both sides of the resolve exchange share: the CLI encodes
// a `ResolveRequest` and sends it over `AppServiceProtocol.performResolve`;
// the app replies JSON-encoded `ResolveOutcome` bytes, which carry either the
// human's `ResolveReply` or — as a typed value, never a decision-shaped lie —
// why no reply came.
//
// Wire rules this file follows, from the established conventions:
// - #0130: structs declare explicit `CodingKeys`, so a property rename can
//   never silently change the wire key. `ConflictKind` and `PathChoice`'s
//   case names ARE their wire keys (String raw values, pinned byte-for-byte
//   by ResolveWireTests).
// - #0129 Decision 4: absent means absent. Optional properties are omitted
//   from the wire when nil — synthesized `Codable` does this — and are never
//   encoded as `null`.
//
// `NSXPCInterface` cannot carry a Swift struct across the boundary, so these
// types travel as JSON in the protocol method's `Data` parameters — the same
// reason `perform` carries envelope bytes rather than a typed envelope.

import Foundation

/// What a CLI asks the app to resolve, and how long it will wait.
public struct ResolveRequest: Codable, Equatable, Sendable {

    /// The repository's git common dir — the repository identity the app keys
    /// tabs on (#0079). The CLI cannot resolve this (it does not link the
    /// engine), so it sends an empty string here and passes its working
    /// directory as `performResolve`'s own parameter; the app-side body
    /// (`runResolveRequest`, YardCommands) resolves the repository and fills
    /// this in before the request is registered or shown to the human.
    public var commonDir: String

    /// The path to resolve, or nil for every conflicted path in the
    /// repository. A pathspec matches its path exactly, or any path under the
    /// directory it names — see ``matches(path:)``. Absent means absent on
    /// the wire — never `null` (#0129 Decision 4).
    public var pathspec: String?

    /// How long the CLI waits for the human, in seconds. The app arms the
    /// pending resolve with the same duration, so the typed timeout normally
    /// arrives before the CLI's own backstop (`--timeout` + 5 s).
    public var timeoutSeconds: Int

    public init(commonDir: String, pathspec: String? = nil, timeoutSeconds: Int) {
        self.commonDir = commonDir
        self.pathspec = pathspec
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case commonDir
        case pathspec
        case timeoutSeconds
    }

    /// Whether `path` is inside this request's scope: every conflicted path
    /// when no pathspec was given, otherwise the pathspec itself or anything
    /// under the directory it names. A pathspec naming `dir` therefore covers
    /// `dir/file.txt` but not `dirfile.txt` — the `/` in the prefix rule is
    /// what keeps a directory scope from swallowing a similarly-prefixed
    /// sibling file.
    public func matches(path: String) -> Bool {
        guard let pathspec, !pathspec.isEmpty else { return true }
        return path == pathspec || path.hasPrefix(pathspec + "/")
    }
}

/// How the two sides collided at a resolved path — the porcelain XY pair of
/// the conflicted index entry (#0017). The raw values are the porcelain
/// strings themselves, so the wire record is readable next to `git status
/// --porcelain=v2` output and `ConflictedFile.Kind`'s vocabulary transfers by
/// raw value. Closed: these seven are everything git emits (there is no
/// rename kind — a rename conflict surfaces as `DD`/`AU`/`UA` records at the
/// paths involved).
public enum ConflictKind: String, Codable, Sendable, CaseIterable {
    case bothModified = "UU"
    case bothAdded = "AA"
    case bothDeleted = "DD"
    case addedByUs = "AU"
    case addedByThem = "UA"
    case deletedByUs = "DU"
    case deletedByThem = "UD"
}

/// What the human chose for one conflicted path — the per-card vocabulary the
/// design's table pins. Closed: a future choice is a wire change, not a
/// free-text value.
public enum PathChoice: String, Codable, Sendable, CaseIterable {
    /// Take ours' blob content (a content or add/add conflict).
    case useOurs
    /// Take theirs' blob content (a content or add/add conflict).
    case useTheirs
    /// The human edited the merged text; `PathResolution.editedContent`
    /// carries what they saved.
    case editedContent
    /// Keep the deletion (delete/modify). The working file is removed and the
    /// deletion staged.
    case keepDeletion
    /// Keep the surviving side's content (delete/modify).
    case keepModification
    /// Take ours' path and content (a rename conflict, porcelain `AU` at
    /// ours' new path).
    case renameTakeOurs
    /// Take theirs' path and content (a rename conflict, porcelain `UA` at
    /// theirs' new path).
    case renameTakeTheirs
}

/// One conflicted path's resolution, as the design's Submit carries it: the
/// path, the porcelain kind, what was chosen, the edited content when the
/// human edited, and the optional note to the agent. This shape is the record
/// #0065 (rerere) later consumes — keep it complete.
public struct PathResolution: Codable, Equatable, Sendable {

    /// The conflicted path, repository-relative.
    public var path: String

    /// How the two sides collided — the porcelain XY pair.
    public var kind: ConflictKind

    /// What the human chose.
    public var choice: PathChoice

    /// The text the human saved, for the `editedContent` choice. Absent for
    /// every other choice — never `null` (#0129 Decision 4).
    public var editedContent: String?

    /// The human's free-text note to the agent, when they wrote one. Absent
    /// means absent — never `null`.
    public var note: String?

    public init(
        path: String,
        kind: ConflictKind,
        choice: PathChoice,
        editedContent: String? = nil,
        note: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.choice = choice
        self.editedContent = editedContent
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case choice
        case editedContent
        case note
    }
}

/// The human's answer at Submit time. Exactly one of its two shapes is
/// present on the wire — an object with exactly one key, the same rule
/// `ReviewSelector` follows, so "submitted resolutions" and "cancelled" can
/// never be confused (an empty resolutions array means *submitted with no
/// card staged*, which is a different fact from *cancelled*).
public enum ResolveReply: Codable, Equatable, Sendable {

    /// The per-path resolutions the human staged and is submitting. Possibly
    /// empty — Submit with nothing staged is a legitimate answer, and the
    /// conflicts-remaining check (exit 8) is what reports its consequence.
    case resolutions([PathResolution])

    /// The human cancelled the sheet. Nothing staged, nothing touched, exit
    /// 7 — a considered human decision, the same vocabulary as `ask`'s
    /// decline and `review`'s reject.
    case cancelled

    private enum CodingKeys: String, CodingKey {
        case resolutions
        case cancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let resolutions = try container.decodeIfPresent([PathResolution].self, forKey: .resolutions) {
            self = .resolutions(resolutions)
        } else if container.contains(.cancelled) {
            self = .cancelled
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected exactly one of \"resolutions\" or \"cancelled\""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .resolutions(let resolutions):
            try container.encode(resolutions, forKey: .resolutions)
        case .cancelled:
            try container.encode(true, forKey: .cancelled)
        }
    }
}

/// What the app resolved a pending resolve to — the wire form of the pending
/// store's outcome, shaped like `ReviewOutcome`. `timedOut` and `superseded`
/// are typed values precisely so an unanswered or replaced wait is never
/// encoded as a human decision. A cancellation is NOT a separate case: cancel
/// is a decided outcome — the human pressed the sheet's discard button — and
/// rides `.decided(.cancelled)`, the way a rejected review rides
/// `.decided` with a reject decision. The arm maps it to exit 7.
public enum ResolveOutcome: Codable, Equatable, Sendable {

    /// The human answered; the reply is their answer — resolutions or a
    /// cancellation.
    case decided(ResolveReply)

    /// The pending resolve's own timeout fired before the human decided.
    case timedOut

    /// A newer resolve request for the same repository replaced this one —
    /// the review semantics, not `ask`'s queue (#0057 design).
    case superseded

    private enum CodingKeys: String, CodingKey {
        case decided
        case timedOut
        case superseded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.decided) {
            self = .decided(try container.decode(ResolveReply.self, forKey: .decided))
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
