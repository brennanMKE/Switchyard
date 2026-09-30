// CommitComposer.swift
//
// #0565-#0567: what the Changes view's message editor reads from the
// repository (guide §11 decision 45). `@concurrent` for the reason every
// loader in `RepositoryLoader.swift` carries it: each blocks in `git`
// subprocesses, which must not run on the main actor.

import YardGit

/// #0565: `commit.template`'s text, comments stripped, or `nil`.
@concurrent
public func loadCommitTemplate(at path: String) async throws -> String? {
    try CommitTemplate.read(at: path)
}

/// #0566: who the Co-Author menu offers.
@concurrent
public func loadCoAuthors(at path: String) async throws -> [CoAuthors.Person] {
    try CoAuthors.recent(at: path)
}

/// #0566: `message` with `trailer` added where git puts it.
@concurrent
public func addingTrailer(_ trailer: String, to message: String, at path: String) async throws -> String {
    try MessageTrailers.adding(trailer, to: message, at: path)
}

/// #0567: the messages Recent Messages offers, newest first.
@concurrent
public func loadRecentMessages(at path: String) async throws -> [String] {
    try RecentMessages.list(at: path)
}

/// #0567: a Recent Messages item's title: the message's first line, cut to
/// `recentMessageTitleLength` characters with an ellipsis.
public nonisolated let recentMessageTitleLength = 60

public nonisolated func recentMessageTitle(_ message: String) -> String {
    let subject = message.prefix { $0 != "\n" }
    guard subject.count > recentMessageTitleLength else { return String(subject) }
    return subject.prefix(recentMessageTitleLength - 1) + "…"
}
