// ReferenceTransactionTests.swift — tests for the ref-txn decision core (#0042)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

private let zeros40 = String(repeating: "0", count: 40)
private let zeros64 = String(repeating: "0", count: 64)

/// Installs a `reference-transaction` hook in the fixture. The path comes
/// from `git rev-parse --git-path hooks` via `WorktreeContext` — never from
/// string concatenation onto `.git/`.
private func installReferenceTransactionHook(
    in repo: FixtureRepository, script: String
) throws {
    let context = try WorktreeContext.resolve(path: repo.url.path)
    let hooksDir = try context.path(for: "hooks")
    try FileManager.default.createDirectory(
        atPath: hooksDir, withIntermediateDirectories: true)
    let hookPath = hooksDir + "/reference-transaction"
    try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: hookPath)
}

private func lines(of url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

// MARK: - Parsing the measured stdin format

@Test func parseClassifiesCreationUpdateAndDeletion() throws {
    let oidA = "d9dea2ebe2e5e6c990c6008be87f630ed8454a13"
    let oidB = "1d219550e5873ab99a9b8d4cd32ae65668d4814b"
    let input = Data("""
    \(zeros40) \(oidA) refs/heads/created
    \(oidA) \(oidB) refs/heads/main
    \(oidA) \(zeros40) refs/heads/deleted
    \(zeros40) \(zeros40) AUTO_MERGE
    """.utf8)

    let result = ReferenceTransaction.parse(input)

    #expect(result.malformedLineCount == 0)
    try #require(result.updates.count == 4)

    #expect(result.updates[0].refName == "refs/heads/created")
    #expect(result.updates[0].oldValue == zeros40)
    #expect(result.updates[0].newValue == oidA)
    #expect(result.updates[0].isCreation)
    #expect(!result.updates[0].isDeletion)

    #expect(result.updates[1].refName == "refs/heads/main")
    #expect(!result.updates[1].isCreation)
    #expect(!result.updates[1].isDeletion)

    #expect(result.updates[2].isDeletion)
    #expect(!result.updates[2].isCreation)

    // git emits zero→zero transactions routinely (AUTO_MERGE on commit).
    #expect(!result.updates[3].isCreation)
    #expect(result.updates[3].isDeletion)
    #expect(result.updates[3].refName == "AUTO_MERGE")
}

@Test func parseHandlesSixtyFourCharZeroOids() {
    // Measured in a --object-format=sha256 repository.
    let oid = "ea68d4f3ee288867fb1ad9d54558b7bd2c8473124d66711a8fbe470c88bf6206"
    let result = ReferenceTransaction.parse(
        Data("\(zeros64) \(oid) refs/heads/main\n".utf8))
    #expect(result.updates.count == 1)
    #expect(result.updates.first?.isCreation == true)
    #expect(result.updates.first?.isDeletion == false)
}

@Test func parseHandlesSymbolicRefUpdates() {
    // Measured: `git symbolic-ref HEAD refs/heads/other` emits this line.
    let result = ReferenceTransaction.parse(
        Data("\(zeros40) ref:refs/heads/other HEAD\n".utf8))
    #expect(result.updates.count == 1)
    #expect(result.updates.first?.isSymbolic == true)
    #expect(result.updates.first?.refName == "HEAD")
    #expect(result.updates.first?.newValue == "ref:refs/heads/other")
}

@Test func parseDropsMalformedLinesAndCounts() {
    let oidA = "d9dea2ebe2e5e6c990c6008be87f630ed8454a13"
    let input = Data("""
    garbage-no-spaces
    \(zeros40) \(oidA) refs/heads/ok
    two fields
    """.utf8)
    let result = ReferenceTransaction.parse(input)
    #expect(result.updates.count == 1)
    #expect(result.updates.first?.refName == "refs/heads/ok")
    #expect(result.malformedLineCount == 2)

    let empty = ReferenceTransaction.parse(Data())
    #expect(empty.updates.isEmpty)
    #expect(empty.malformedLineCount == 0)
}

// MARK: - The decision policy

@Test func nonCommittedStatesExitZeroWithoutReadingStdin() {
    // "preparing" is prose folklore — git 2.50.1 has no such state — but a
    // handler that sees it must behave identically: exit 0, touch nothing.
    for state in ["prepared", "preparing", "aborted", "", "future-state"] {
        var reads = 0
        let decision = ReferenceTransaction.decide(
            stateArgument: state,
            environment: [:],
            readStandardInput: {
                reads += 1
                return Data("x y z\n".utf8)
            })
        #expect(decision.exitCode == 0, "state \(state) must exit 0")
        #expect(decision.updates.isEmpty, "state \(state) must record nothing")
        #expect(reads == 0, "state \(state) must not read stdin")
    }
}

@Test func committedForeignTransactionParsesStdin() {
    let oidA = "d9dea2ebe2e5e6c990c6008be87f630ed8454a13"
    let stdin = Data("\(zeros40) \(oidA) refs/heads/x\n".utf8)

    // No marker at all: a foreign tool's transaction.
    let foreign = ReferenceTransaction.decide(
        stateArgument: "committed",
        environment: ["PATH": "/usr/bin"],
        readStandardInput: { stdin })
    #expect(foreign.exitCode == 0)
    #expect(foreign.updates.count == 1)
    #expect(foreign.updates.first?.refName == "refs/heads/x")

    // Marker present but EMPTY is also foreign — the escape hatch tests use
    // through GitProcess.extraEnvironment, since the base environment always
    // sets the marker to "1".
    let emptied = ReferenceTransaction.decide(
        stateArgument: "committed",
        environment: [GitProcess.markerVariable: ""],
        readStandardInput: { stdin })
    #expect(emptied.updates.count == 1)
}

@Test func committedOwnTransactionRecordsNothingWithoutReadingStdin() {
    var reads = 0
    let decision = ReferenceTransaction.decide(
        stateArgument: "committed",
        environment: [GitProcess.markerVariable: "1"],
        readStandardInput: {
            reads += 1
            return Data("x y z\n".utf8)
        })
    #expect(decision.exitCode == 0)
    #expect(decision.updates.isEmpty, "our own transactions must not be recorded")
    #expect(reads == 0, "our own transactions need no stdin read")
}

@Test func decisionExitCodeIsZeroForEveryInput() {
    // The invariant the issue exists for: no input — not even garbage on a
    // committed transaction — produces a non-zero exit.
    for state in ["prepared", "committed", "aborted", "junk", ""] {
        for env in [[:], [GitProcess.markerVariable: "1"]] {
            let decision = ReferenceTransaction.decide(
                stateArgument: state,
                environment: env,
                readStandardInput: { Data("total garbage\nmore garbage\n".utf8) })
            #expect(decision.exitCode == 0,
                    "state \(state), env \(env) must still exit 0")
        }
    }
}

// MARK: - The real contract, against a real repository, both ref formats

@Test(arguments: FixtureRepository.RefFormat.supported())
func hookReceivesTheMeasuredContract(_ format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let oidA = try #require(repo.oids["a"])

    let statesLog = repo.url.appendingPathComponent("hook-states.log")
    let stdinLog = repo.url.appendingPathComponent("hook-stdin.log")
    try installReferenceTransactionHook(in: repo, script: """
    #!/bin/sh
    printf '%s\\n' "$1" >> "\(statesLog.path)"
    if [ "$1" = committed ]; then cat >> "\(stdinLog.path)"; fi
    exit 0
    """)

    let git = GitProcess()
    try git.run(["update-ref", "refs/heads/observed", oidA],
                workingDirectory: repo.url.path)
    try git.run(["update-ref", "-d", "refs/heads/observed"],
                workingDirectory: repo.url.path)

    let states = Set(lines(of: statesLog))
    #expect(states.contains("prepared"))
    #expect(states.contains("committed"))
    // Tripwire: if a future git adds a state (the "preparing" of the prose),
    // this fails and the contract gets re-measured rather than assumed.
    #expect(states.isSubset(of: ["prepared", "committed", "aborted"]),
            "unexpected hook state in \(states)")

    let captured = try Data(contentsOf: stdinLog)
    let result = ReferenceTransaction.parse(captured)
    #expect(result.malformedLineCount == 0)

    let observed = result.updates.filter { $0.refName == "refs/heads/observed" }
    try #require(observed.count == 2)
    #expect(observed[0].isCreation)
    #expect(observed[0].newValue == oidA)
    #expect(observed[1].isDeletion)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func gitProcessInvocationsCarryTheMarkerIntoTheHook(
    _ format: FixtureRepository.RefFormat
) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let oidA = try #require(repo.oids["a"])

    let markerLog = repo.url.appendingPathComponent("hook-markers.log")
    try installReferenceTransactionHook(in: repo, script: """
    #!/bin/sh
    if [ "$1" = committed ]; then
        printf '%s\\n' "${\(GitProcess.markerVariable)-UNSET}" >> "\(markerLog.path)"
    fi
    exit 0
    """)

    try GitProcess().run(["update-ref", "refs/heads/marked", oidA],
                         workingDirectory: repo.url.path)

    let seen = lines(of: markerLog)
    #expect(!seen.isEmpty, "the hook must have fired at least once")
    #expect(seen.allSatisfy { $0 == "1" },
            "every GitProcess invocation must carry \(GitProcess.markerVariable)=1; saw \(seen)")
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func nonZeroExitInPreparedAbortsTheTransaction(
    _ format: FixtureRepository.RefFormat
) throws {
    // The fact the whole policy rests on, pinned against both ref formats:
    // a handler exiting non-zero in `prepared` destroys the user's ref
    // update. This is why `decide` is total and always 0.
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("a")])
    let oidA = try #require(repo.oids["a"])

    try installReferenceTransactionHook(in: repo, script: """
    #!/bin/sh
    if [ "$1" = prepared ]; then exit 1; fi
    exit 0
    """)

    let git = GitProcess()
    let attempt = try git.capture(["update-ref", "refs/heads/doomed", oidA],
                                  workingDirectory: repo.url.path)
    #expect(attempt.exitCode != 0)
    #expect(attempt.standardError.contains("aborted by hook"))

    let verify = try git.capture(
        ["rev-parse", "--verify", "--quiet", "refs/heads/doomed"],
        workingDirectory: repo.url.path)
    #expect(verify.exitCode != 0, "the aborted ref must not exist")
}
