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
