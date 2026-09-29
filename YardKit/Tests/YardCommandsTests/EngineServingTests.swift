// EngineServingTests.swift — the shared rendering every guide §11
// decision 37 arm uses (EngineServing.swift)

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

private struct Unclassified: Error, CustomStringConvertible {
    var description: String { "something unclassified" }
}

private struct Echo: Encodable, Sendable { let value: String }

@Suite("Engine serving helpers")
struct EngineServingTests {

    /// Each §6 class the engine declares comes out as its own exit code and
    /// envelope label — not the flat request_failed the older arms use.
    @Test func classifiedErrorsExitWithTheirOwnClass() throws {
        let cases: [(any Error, ExitCode, String)] = [
            (StagingError.unknownHunkIDs(ids: ["x"], area: .unstaged), .repositoryError, "repository_error"),
            (CommitCreate.Failure.signingFailed(reason: "no key"), .signingFailed, "signing_failed"),
            (Stash.Refusal.nothingToStash, .repositoryError, "repository_error"),
        ]
        for (error, exitCode, label) in cases {
            let reply = engineFailure(error)
            #expect(reply.exitCode == exitCode, "\(error)")
            #expect(try errorCode(reply) == label)
            #expect(reply.stderr == "[error] \(label): \(error)\n")
        }
    }

    @Test func anUnclassifiedErrorIsRequestFailed() throws {
        let reply = engineFailure(Unclassified())
        #expect(reply.exitCode == .requestFailed)
        #expect(try errorCode(reply) == "request_failed")
        let error = try #require(try envelope(reply)["error"] as? [String: Any])
        #expect(error["message"] as? String == "something unclassified")
    }

    @Test func usageIsExitOneWithTheMessage() throws {
        let reply = engineUsage("stage takes paths")
        #expect(reply.exitCode == .usage)
        #expect(try errorCode(reply) == "usage")
        #expect(reply.stderr == "[error] usage: stage takes paths\n")
    }

    /// A completed command with an outcome to branch on is ok:true at a
    /// non-zero exit — how a conflicted stash apply reports.
    @Test func successCarriesThePayloadAtTheGivenExit() throws {
        let plain = engineSuccess(Echo(value: "v"))
        #expect(plain.exitCode == .success)
        #expect(try payload(plain)["value"] as? String == "v")
        #expect(plain.stdout.hasSuffix("}\n"))

        let conflicted = engineSuccess(Echo(value: "c"), exitCode: .blockedOnConflicts)
        #expect(conflicted.exitCode == .blockedOnConflicts)
        #expect(try payload(conflicted)["value"] as? String == "c")
    }

    /// Paths are repository-relative, so the arms run git from the top.
    @Test func repositoryTopResolvesFromASubdirectory() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try write("s\n", to: "sub/s.txt", in: repo)
        #expect(try repositoryTop(repo.url.appendingPathComponent("sub").path) == repo.url.path)
    }
}
