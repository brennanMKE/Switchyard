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

/// One `reference-transaction` invocation as a per-invocation logging hook
/// recorded it: the state argument and the stdin lines delivered with it.
private struct HookInvocation: Equatable {
    let state: String
    let stdinLines: [String]
}

/// Parses the marker-delimited log the measured-contract hook writes:
/// `--- state=<state> begin ---`, the raw stdin lines, then
/// `--- state=<state> end ---`. Unopened stdin lines are dropped — a log
/// this parser cannot make sense of fails the assertions downstream.
private func invocations(of url: URL) -> [HookInvocation] {
    var result: [HookInvocation] = []
    var state: String?
    var stdin: [String] = []
    for line in lines(of: url) {
        if line.hasPrefix("--- state="), line.hasSuffix(" begin ---") {
            state = String(line.dropFirst("--- state=".count)
                .dropLast(" begin ---".count))
            stdin = []
        } else if line.hasPrefix("--- state="), line.hasSuffix(" end ---") {
            if let open = state {
                result.append(HookInvocation(state: open, stdinLines: stdin))
            }
            state = nil
            stdin = []
        } else if state != nil {
            stdin.append(line)
        }
    }
    return result
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
    // git 2.54.0 emits `preparing` before `prepared` on every transaction
    // (measured 2026-09-22); like every non-`committed` state, a handler
    // that sees it must behave identically: exit 0, touch nothing.
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
    // Tripwire: this is the state set measured on git 2.54.0 (2026-09-22,
    // both ref formats). A state git adds, drops, or renames fails here and
    // the contract gets re-measured rather than assumed.
    #expect(states.isSubset(of: ["preparing", "prepared", "committed", "aborted"]),
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
func hookSequencesAndStdinMatchTheMeasuredContract(
    _ format: FixtureRepository.RefFormat
) throws {
    // Pins, as exact equality, the per-transaction invocation sequences git
    // 2.54.0 emits (measured 2026-09-22, one scenario per scratch repo, both
    // ref formats) and that stdin carries the update lines on EVERY
    // invocation, not only on `prepared`. A state added, dropped, or
    // reordered — or stdin withheld from any state — fails here and forces a
    // re-measure.
    func loggingScript(_ log: URL) -> String {
        """
        #!/bin/sh
        { echo "--- state=$1 begin ---"
          cat
          echo "--- state=$1 end ---"
        } >> "\(log.path)"
        exit 0
        """
    }

    // CREATE: the hook exists before the repo's only ref update.
    var createRepo = try FixtureRepository(refFormat: format)
    defer { createRepo.destroy() }
    try createRepo.build([.init("a")])
    let oidA = try #require(createRepo.oids["a"])

    let createLog = createRepo.url.appendingPathComponent("hook-transactions.log")
    try installReferenceTransactionHook(in: createRepo, script: loggingScript(createLog))
    try GitProcess().run(["update-ref", "refs/heads/observed", oidA],
                         workingDirectory: createRepo.url.path)

    let created = invocations(of: createLog)
    #expect(created.map { $0.state } == ["preparing", "prepared", "committed"],
            "create sequence was \(created.map { $0.state })")
    let createLine = "\(zeros40) \(oidA) refs/heads/observed"
    for invocation in created {
        #expect(invocation.stdinLines == [createLine],
                "state \(invocation.state) must receive the update line on stdin")
    }

    // DELETE: the ref predates the hook, so only the deletion logs. The
    // sequences genuinely differ per ref format on git 2.54.0 (measured
    // 2026-09-22; the scratch repo and this fixture agree): the files
    // backend fires `aborted` mid-transaction on a *successful* delete,
    // reftable does not. An unconditional `update-ref -d` reports
    // zeros→zeros on every invocation (measured), not old→zeros.
    var deleteRepo = try FixtureRepository(refFormat: format)
    defer { deleteRepo.destroy() }
    try deleteRepo.build([.init("a")])
    let oidB = try #require(deleteRepo.oids["a"])
    try GitProcess().run(["update-ref", "refs/heads/observed", oidB],
                         workingDirectory: deleteRepo.url.path)

    let deleteLog = deleteRepo.url.appendingPathComponent("hook-transactions.log")
    let expectedDeleteStates: [String]
    switch format {
    case .files: expectedDeleteStates = ["preparing", "aborted", "prepared", "committed"]
    case .reftable: expectedDeleteStates = ["preparing", "prepared", "committed"]
    }
    try installReferenceTransactionHook(in: deleteRepo, script: loggingScript(deleteLog))
    try GitProcess().run(["update-ref", "-d", "refs/heads/observed"],
                         workingDirectory: deleteRepo.url.path)

    let deleted = invocations(of: deleteLog)
    #expect(deleted.map { $0.state } == expectedDeleteStates,
            "delete sequence was \(deleted.map { $0.state })")
    let deleteLine = "\(zeros40) \(zeros40) refs/heads/observed"
    for invocation in deleted {
        #expect(invocation.stdinLines == [deleteLine],
                "state \(invocation.state) must receive the update line on stdin")
    }
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
    #expect(attempt.standardError
        .contains("update aborted by the reference-transaction hook"))

    let verify = try git.capture(
        ["rev-parse", "--verify", "--quiet", "refs/heads/doomed"],
        workingDirectory: repo.url.path)
    #expect(verify.exitCode != 0, "the aborted ref must not exist")
}
