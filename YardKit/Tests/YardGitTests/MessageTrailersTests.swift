// MessageTrailersTests.swift — a trailer lands where git puts it (#0560)
//
// Each expected string was measured with `git interpret-trailers` 2.54.0.

import Foundation
import Testing
@testable import YardGit

private let hermetic = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
private let ann = "Co-authored-by: Ann Lee <ann@example.com>"

private func adding(_ message: String, env: [String: String] = hermetic) throws -> String {
    let repo = try FixtureRepository()
    defer { repo.destroy() }
    return try MessageTrailers.adding(ann, to: message, at: repo.url.path, extraEnvironment: env)
}

@Test func aTrailerStartsABlockAfterTheBody() throws {
    #expect(try adding("Subject\n\nBody text.") == "Subject\n\nBody text.\n\n\(ann)\n")
    #expect(try adding("Subject") == "Subject\n\n\(ann)\n")
}

@Test func aTrailerJoinsAnExistingBlock() throws {
    #expect(try adding("Subject\n\nSigned-off-by: Me <me@example.com>")
        == "Subject\n\nSigned-off-by: Me <me@example.com>\n\(ann)\n")
}

@Test func aTrailerAlreadyThereIsNotAddedTwice() throws {
    #expect(try adding("Subject\n\n\(ann)") == "Subject\n\n\(ann)\n")
}

@Test func aBlankMessageKeepsItsSubjectLineFree() throws {
    #expect(try adding("") == "\n\n\(ann)\n")
    #expect(try adding(" \n") == "\n\n\(ann)\n")
}

@Test func trailerConfigCannotMoveOrDropIt() throws {
    var env = hermetic
    env["GIT_CONFIG_COUNT"] = "2"
    env["GIT_CONFIG_KEY_0"] = "trailer.ifmissing"
    env["GIT_CONFIG_VALUE_0"] = "doNothing"
    env["GIT_CONFIG_KEY_1"] = "trailer.where"
    env["GIT_CONFIG_VALUE_1"] = "start"
    #expect(try adding("Subject", env: env) == "Subject\n\n\(ann)\n")
    #expect(try adding("Subject\n\nSigned-off-by: Me <me@example.com>", env: env)
        == "Subject\n\nSigned-off-by: Me <me@example.com>\n\(ann)\n")
}

@Test func aDashedLineIsTextNotADivider() throws {
    #expect(try adding("Subject\n\n---\nnotes") == "Subject\n\n---\nnotes\n\n\(ann)\n")
}
