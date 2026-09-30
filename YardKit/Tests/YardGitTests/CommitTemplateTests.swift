// CommitTemplateTests.swift — the text commit.template starts a message with (#0562)

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]

private func configure(_ key: String, _ value: String, in repo: FixtureRepository) throws {
    try GitProcess().run(["config", key, value], workingDirectory: repo.url.path, extraEnvironment: hermetic)
}

private func write(_ text: String, to path: String) throws {
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

@Test func noTemplateConfiguredReadsNil() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: hermetic) == nil)
}

@Test func aTemplateLosesItsCommentsAndOuterBlankLines() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    let file = repo.url.appendingPathComponent("template.txt").path
    try write("\nSummary\n\n# Why was this change made?\nRefs: \n\n", to: file)
    try configure("commit.template", file, in: repo)

    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: hermetic) == "Summary\n\nRefs:")
}

@Test func aTemplateHonorsCoreCommentChar() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    try write("Summary\n; a comment\n# not one\n", to: repo.url.appendingPathComponent("t.txt").path)
    try configure("commit.template", "t.txt", in: repo) // relative to the worktree
    try configure("core.commentChar", ";", in: repo)

    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: hermetic) == "Summary\n# not one")
}

@Test func aTildeTemplateIsReadFromHome() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    try write("From home\n", to: repo.url.appendingPathComponent("home.txt").path)
    try configure("commit.template", "~/home.txt", in: repo)
    var env = hermetic
    env["HOME"] = repo.url.path

    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: env) == "From home")
}

@Test func aMissingOrAllCommentTemplateReadsNil() throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    try configure("commit.template", repo.url.appendingPathComponent("absent.txt").path, in: repo)
    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: hermetic) == nil)

    let file = repo.url.appendingPathComponent("comments.txt").path
    try write("# only\n# comments\n", to: file)
    try configure("commit.template", file, in: repo)
    #expect(try CommitTemplate.read(at: repo.url.path, extraEnvironment: hermetic) == nil)
}
