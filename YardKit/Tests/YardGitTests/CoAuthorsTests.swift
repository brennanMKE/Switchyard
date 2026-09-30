// CoAuthorsTests.swift — who the Co-Author menu offers (#0559)
//
// NO NETWORK, NO SIGNING KEY: FixtureRepository sets commit.gpgsign=false
// and the hermetic environment blanks global and system config.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

/// An empty commit by `name <email>`.
private func commit(_ message: String, by name: String, _ email: String, in repo: FixtureRepository) throws {
    try GitProcess().run(
        ["-c", "user.name=\(name)", "-c", "user.email=\(email)",
         "commit", "-q", "--allow-empty", "-m", message],
        workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func coAuthorsAreRecentAuthorsAndCreditedPeopleNewestFirstWithoutMe(
    format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try commit("by ann", by: "Ann Lee", "ann@example.com", in: repo)
    try commit("paired\n\nCo-authored-by: Bob Quinn <bob@example.com>\nCo-authored-by: Ann Lee <ANN@example.com>",
               by: "Fixture", "fixture@example.invalid", in: repo)
    try commit("by cy", by: "Cy Dee", "cy@example.com", in: repo)

    let people = try CoAuthors.recent(at: repo.url.path, extraEnvironment: hermetic)

    #expect(people == [
        CoAuthors.Person(name: "Cy Dee", email: "cy@example.com"),
        CoAuthors.Person(name: "Bob Quinn", email: "bob@example.com"),
        CoAuthors.Person(name: "Ann Lee", email: "ANN@example.com"),
    ])
}

@Test func coAuthorsOfAnUnbornBranchAreNone() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    #expect(try CoAuthors.recent(at: repo.url.path, extraEnvironment: hermetic).isEmpty)
}

@Test func coAuthorsStopAtTheLimit() throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([.init("base")])
    for n in 1...3 { try commit("c\(n)", by: "P\(n)", "p\(n)@example.com", in: repo) }

    let people = try CoAuthors.recent(at: repo.url.path, limit: 2, extraEnvironment: hermetic)

    #expect(people.map(\.name) == ["P3", "P2"])
}

@Test func coAuthorParserSkipsValuesThatAreNotNameAndEmail() {
    let log = "Ann\0ann@x.io\0no email here\u{01}<only@x.io>\u{01}Bob <bob@x.io>\u{1E}\n"
    #expect(CoAuthors.parse(log, excluding: "", limit: 20) == [
        CoAuthors.Person(name: "Ann", email: "ann@x.io"),
        CoAuthors.Person(name: "Bob", email: "bob@x.io"),
    ])
}

@Test func aPersonsTrailerNamesThemAsCoAuthor() {
    let ann = CoAuthors.Person(name: "Ann Lee", email: "ann@example.com")
    #expect(ann.identity == "Ann Lee <ann@example.com>")
    #expect(ann.trailer == "Co-authored-by: Ann Lee <ann@example.com>")
}
