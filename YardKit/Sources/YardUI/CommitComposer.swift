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
