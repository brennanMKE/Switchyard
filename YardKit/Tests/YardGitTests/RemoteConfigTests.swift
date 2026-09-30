// RemoteConfigTests.swift — listing, validating, adding and re-pointing remotes (#0527)
//
// NO NETWORK. Every remote is a bare repository in a temporary directory,
// or a URL nothing ever contacts (`example.invalid`).

import Foundation
import Testing
@testable import YardGit

/// Names measured against `git remote add` on git 2.54.0: git accepted
/// exactly those `git check-ref-format refs/remotes/<name>/test` accepts.
private let measuredNames = [
    "origin", "a/b", "a.b", "@", "HEAD", "é", "a@b", "a,b", "a;b", "a#b", "a%b", "a{b", "a}b",
    "a\"b", "a'b", "a+b", "a=b", "a!b", "a&b", "A", "origin.", "a/@", "a.",
    "a//b", "a b", "a\tb", "a?b", "a*b", "a[b", "a\\b", "a@{b", "/a", "a/", "a/.b", "a/b.lock",
    "a..b", "a:", "a~b", "a^", ".a", "..", ".", "a..", "a.lock/b", "x.lock", "a\u{7F}b", "",
]

@Test func nameProblemAgreesWithGitCheckRefFormat() throws {
    for name in measuredNames {
        let git = try GitProcess().capture(["check-ref-format", "refs/remotes/\(name)/test"])
        #expect((RemoteConfig.nameProblem(name) == nil) == (git.exitCode == 0),
                "“\(name)”: nameProblem says \(RemoteConfig.nameProblem(name) ?? "fine"), git exits \(git.exitCode)")
    }
}

@Test func aLeadingDashIsRefusedThoughGitAcceptsIt() throws {
    #expect(try GitProcess().capture(["check-ref-format", "refs/remotes/-x/test"]).exitCode == 0)
    #expect(RemoteConfig.nameProblem("-x") == "A remote name can’t start with “-”.")
}

@Test func urlProblemRefusesEmptyControlCharactersAndALeadingDash() {
    #expect(RemoteConfig.urlProblem("") == "Enter a URL.")
    #expect(RemoteConfig.urlProblem("a\nb") == "A URL can’t contain line breaks or control characters.")
    #expect(RemoteConfig.urlProblem("-oProxyCommand=x") == "A URL can’t start with “-”.")
    for url in ["file:///srv/x.git", "/srv/x.git", "git@example.invalid:a/b.git",
                "https://example.invalid/a b.git", "../sibling"] {
        #expect(RemoteConfig.urlProblem(url) == nil, "\(url)")
    }
}

@Test func parseVerboseReadsFetchPushAndAURLlessRemote() {
    let remotes = RemoteConfig.parseVerbose([
        "origin\t/srv/up.git (fetch)",
        "origin\t/srv/up.git (push)",
        "gh\thttps://example.invalid/a.git (fetch)",
        "gh\tgit@example.invalid:a.git (push)",
        "gh\tssh://mirror.invalid/a.git (push)",
        "bare\t",
        "tail of a URL with a newline (fetch)",
    ])
    #expect(remotes == [
        .init(name: "bare", fetchURL: nil, pushURLs: []),
        .init(name: "gh", fetchURL: "https://example.invalid/a.git",
              pushURLs: ["git@example.invalid:a.git", "ssh://mirror.invalid/a.git"]),
        .init(name: "origin", fetchURL: "/srv/up.git", pushURLs: ["/srv/up.git"]),
    ])
    #expect(!remotes[2].pushDiffers)
    #expect(remotes[1].pushDiffers)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func listReportsEveryRemoteSortedWithItsURLs(format: FixtureRepository.RefFormat) async throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    #expect(try await RemoteConfig.list(at: repo.url.path).isEmpty)

    let bare = try repo.addUpstream()
    defer { try? FileManager.default.removeItem(at: bare) }
    try await GitProcess().run(["remote", "add", "gh", "https://example.invalid/a.git"], workingDirectory: repo.url.path)
    try await GitProcess().run(["remote", "set-url", "--add", "--push", "gh", "git@example.invalid:a.git"],
                         workingDirectory: repo.url.path)

    #expect(try await RemoteConfig.list(at: repo.url.path) == [
        .init(name: "gh", fetchURL: "https://example.invalid/a.git", pushURLs: ["git@example.invalid:a.git"]),
        .init(name: "origin", fetchURL: bare.path, pushURLs: [bare.path]),
    ])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func addCreatesTheRemoteTrimmedAndWritesNoJournalEntry(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let ctx = try WorktreeContext.resolve(path: repo.url.path)
    try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
    let entries = try JournalAnchor.list(in: ctx).count

    try RemoteConfig.add(name: "backup", url: "  file:///srv/backup.git \t", at: repo.url.path)

    #expect(try RemoteConfig.list(at: repo.url.path) == [
        .init(name: "backup", fetchURL: "file:///srv/backup.git", pushURLs: ["file:///srv/backup.git"]),
    ])
    #expect(try JournalAnchor.list(in: ctx).count == entries, "adding a remote is not journaled")
}

@Test func addRefusesATakenNameAnInvalidNameAndABadURLBeforeGitRuns() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let path = repo.url.path
    try RemoteConfig.add(name: "origin", url: "/srv/a.git", at: path)

    #expect(throws: RemoteConfig.Refusal.nameInUse("origin")) {
        try RemoteConfig.add(name: "origin", url: "/srv/b.git", at: path)
    }
    #expect(throws: RemoteConfig.Refusal.invalidName("a b", reason: "A remote name can’t contain spaces.")) {
        try RemoteConfig.add(name: "a b", url: "/srv/b.git", at: path)
    }
    #expect(throws: RemoteConfig.Refusal.invalidURL(reason: "Enter a URL.")) {
        try RemoteConfig.add(name: "second", url: "   ", at: path)
    }
    #expect(throws: RemoteConfig.Refusal.nestedName("origin/x", existing: "origin")) {
        try RemoteConfig.add(name: "origin/x", url: "/srv/b.git", at: path)
    }
    #expect(try RemoteConfig.list(at: path).map(\.name) == ["origin"])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func setURLChangesTheFetchURLAndKeepsASeparatePushURL(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let path = repo.url.path
    let ctx = try WorktreeContext.resolve(path: path)
    try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
    try RemoteConfig.add(name: "gh", url: "https://example.invalid/a.git", at: path)
    try GitProcess().run(["remote", "set-url", "--add", "--push", "gh", "git@example.invalid:a.git"],
                         workingDirectory: path)
    let entries = try JournalAnchor.list(in: ctx).count

    try RemoteConfig.setURL("https://example.invalid/b.git", forRemote: "gh", at: path)

    #expect(try RemoteConfig.list(at: path) == [
        .init(name: "gh", fetchURL: "https://example.invalid/b.git", pushURLs: ["git@example.invalid:a.git"]),
    ])
    #expect(try RemoteConfig.configuredURL(of: "gh", at: path) == "https://example.invalid/b.git")
    #expect(try JournalAnchor.list(in: ctx).count == entries, "changing a URL is not journaled")
    #expect(throws: RemoteConfig.Refusal.unknownRemote("nope")) {
        try RemoteConfig.setURL("/srv/x.git", forRemote: "nope", at: path)
    }
}

@Test func configuredURLIsTheURLBeforeInsteadOfRewriting() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base", files: ["a.txt": "one\n"])])
    let path = repo.url.path
    try GitProcess().run(["config", "url.file:///srv/.insteadOf", "short:"], workingDirectory: path)
    try RemoteConfig.add(name: "s", url: "short:up.git", at: path)

    #expect(try RemoteConfig.configuredURL(of: "s", at: path) == "short:up.git")
    #expect(try RemoteConfig.list(at: path).first?.fetchURL == "file:///srv/up.git")
}
