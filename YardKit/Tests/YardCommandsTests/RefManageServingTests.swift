// RefManageServingTests.swift — the `tag` and `branch` arms in
// `runEngineCommand` (#0363)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

/// Parses a command's stdout into its top-level JSON object, failing loudly
/// (rather than returning an empty dictionary) when it does not decode —
/// Rule 7: an extractor that silently returns empty would make every
/// following assertion pass unconditionally.
private func jsonObject(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any], "stdout must decode as a JSON object: \(text)")
}

/// `c1 → c2 → c3` on `main`.
private func linearFixture() throws -> FixtureRepository {
    var repo = try FixtureRepository()
    try repo.build([
        .init("c1", files: ["f.txt": "a1\n"]),
        .init("c2", files: ["f.txt": "a1\na2\n"]),
        .init("c3", files: ["f.txt": "a1\na2\na3\n"]),
    ])
    return repo
}

@Suite("tag and branch engine arms")
struct RefManageServingTests {

    // MARK: - tag

    @Test func tagServesASuccessEnvelopeWithThePayload() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }
        let c2 = try #require(repo.oids["c2"])

        let result = try #require(
            runEngineCommand(arguments: ["tag", "v1", c2],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)
        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["result"] as? [String: Any],
                                   "result must be the tag payload")
        #expect(payload["ref"] as? String == "refs/tags/v1")
        #expect(payload["oid"] as? String == c2)
        #expect(payload["annotated"] as? Bool == false)
    }

    @Test func tagWithTheWrongPositionalCountIsAUsageRefusal() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["tag", "only-a-name"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .usage)
        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
        #expect(result.stderr.contains("usage"))
    }

    @Test func anAnnotatedTagRidesTheMessageFlagThroughTheArm() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["tag", "v1", "main", "--message", "annotated"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let payload = try #require(try jsonObject(result.stdout)["result"] as? [String: Any])
        #expect(payload["annotated"] as? Bool == true,
                "--message implies an annotated tag on the arm level")
    }

    // MARK: - branch

    @Test func branchCreateServesASuccessEnvelopeAndTheRefStays() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }
        let c2 = try #require(repo.oids["c2"])

        let result = try #require(
            runEngineCommand(arguments: ["branch", "create", "feature", c2],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .success)
        let payload = try #require(try jsonObject(result.stdout)["result"] as? [String: Any])
        #expect(payload["ref"] as? String == "refs/heads/feature")
        #expect(payload["oid"] as? String == c2)
        #expect(payload.keys.contains("headFollowed") == false,
                "create reports no head-follow field")

        let git = GitProcess()
        let refs = try git.run(
            ["for-each-ref", "--format=%(refname)"],
            workingDirectory: repo.url.path, extraEnvironment: [:]
        ).lines
        #expect(refs.contains("refs/heads/feature"))
    }

    @Test func branchDeleteOfTheCheckedOutBranchIsATypedRequestFailure() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["branch", "delete", "main"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .requestFailed)
        let object = try jsonObject(result.stdout)
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "request_failed")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("checked out"), "the typed refusal names the state; got \(message)")
    }

    @Test func branchWithAnUnknownSubcommandIsAUsageRefusal() throws {
        let repo = try linearFixture()
        defer { repo.destroy() }

        let result = try #require(
            runEngineCommand(arguments: ["branch", "frobnicate"],
                             workingDirectory: repo.url.path))

        #expect(result.exitCode == .usage)
        let error = try #require(try jsonObject(result.stdout)["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
    }
}
