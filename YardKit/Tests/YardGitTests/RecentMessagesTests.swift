// RecentMessagesTests.swift — the messages Recent Messages offers (#0561)

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private func git(_ arguments: [String], in repo: FixtureRepository) throws {
    try GitProcess().run(arguments, workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func recentMessagesKeepUndoneAndAmendedCommitsNewestFirst(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try git(["commit", "-q", "--allow-empty", "-m", "second", "-m", "Body of second."], in: repo)
    try git(["commit", "-q", "--allow-empty", "--amend", "-m", "second amended"], in: repo)
    try git(["reset", "-q", "--soft", "HEAD~1"], in: repo)            // an undone commit
    try git(["commit", "-q", "--allow-empty", "-m", "third"], in: repo)
    try git(["checkout", "-q", "-b", "side"], in: repo)                // not a commit entry
    try git(["commit", "-q", "--allow-empty", "-m", "base"], in: repo) // repeats an older message

    let messages = try RecentMessages.list(at: repo.url.path, extraEnvironment: hermetic)

    #expect(messages == ["base", "third", "second amended", "second\n\nBody of second."])
}

@Test func recentMessagesOfAnUnbornBranchAreNone() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    #expect(try RecentMessages.list(at: repo.url.path, extraEnvironment: hermetic).isEmpty)
}

@Test func recentMessagesStopAtTheLimit() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("one"), .init("two"), .init("three")])
    #expect(try RecentMessages.list(at: repo.url.path, limit: 2, extraEnvironment: hermetic)
        == ["three", "two"])
}

@Test func recentMessagesParserTakesOnlyCommitEntries() {
    let reflog = [
        "checkout: moving from a to b\0tip\n",
        "commit (merge): Merge x\0Merge x\n",
        "cherry-pick: picked\0picked\n",
        "commit (initial): first\0first\n\n",
    ].joined(separator: "\u{1E}\n") + "\u{1E}\n"
    #expect(RecentMessages.parse(reflog, limit: 10) == ["Merge x", "first"])
}
