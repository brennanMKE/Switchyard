// HookArmTests.swift — the `hook` arm's gate and dispatch routing (#0154)

import Foundation
import Testing
@testable import YardKit

/// Counts calls without a broker, launch agent, or `NSXPCConnection`.
private actor ConnectCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Records whether the gate's stdin reader ran. The reader is called
/// synchronously on the test's own thread (the closure is non-escaping), so
/// no synchronization is needed.
private final class StdinReader {
    private(set) var callCount = 0
    let payload: Data

    init(payload: Data = Data("0000000 1234567 refs/heads/main\n".utf8)) {
        self.payload = payload
    }

    func read() -> Data {
        callCount += 1
        return payload
    }
}

@Suite("HookArm: the gate and its routing")
struct HookArmTests {

    private func refusedMessage(
        _ arguments: [String],
        environment: [String: String] = [:]
    ) -> String {
        let reader = StdinReader()
        guard case let .refused(message) = HookArm.gate(
            arguments: arguments,
            environment: environment,
            readStandardInput: { reader.read() })
        else {
            return ""
        }
        return message
    }

    // MARK: - The forwarding case

    /// A foreign `committed` `ref-txn` invocation is the one shape that
    /// forwards: it drains stdin (exactly once) and carries the state.
    @Test func foreignCommittedForwardsAndDrainsStdinOnce() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "committed", "refs/heads/main"],
            environment: [:],
            readStandardInput: { reader.read() })

        guard case let .forward(state, standardInput) = gate else {
            Issue.record("expected .forward, got \(gate)")
            return
        }
        #expect(state == "committed")
        #expect(standardInput == reader.payload)
        #expect(reader.callCount == 1)
    }

    /// Git passes refnames as extra arguments; the state is always argv[2].
    /// Whatever the tail carries must not change the verdict.
    @Test(arguments: [["hook", "ref-txn", "committed"], ["hook", "ref-txn", "committed", "refs/heads/x", "refs/tags/y"]])
    func committedWithAnyArgumentTailForwards(arguments: [String]) {
        let reader = StdinReader()
        guard case .forward = HookArm.gate(
            arguments: arguments,
            environment: [:],
            readStandardInput: { reader.read() })
        else {
            Issue.record("expected .forward for \(arguments)")
            return
        }
        #expect(reader.callCount == 1)
    }

    // MARK: - The contract: state and environment are checked BEFORE stdin

    /// `prepared` is the most common invocation a real repository produces.
    /// It must exit before stdin is ever drained — a mutation that moves the
    /// drain above the state check fails exactly here.
    @Test func preparedNeverDrainsStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "prepared"],
            environment: [:],
            readStandardInput: { reader.read() })

        #expect(gate == .nothingToRecord)
        #expect(reader.callCount == 0)
    }

    @Test func abortedNeverDrainsStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "aborted"],
            environment: [:],
            readStandardInput: { reader.read() })

        #expect(gate == .nothingToRecord)
        #expect(reader.callCount == 0)
    }

    /// A state a future git adds is the same policy as every
    /// non-`committed` state (#0042): silent no-op, stdin untouched.
    @Test func unrecognizedStateNeverDrainsStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "preparing"],
            environment: [:],
            readStandardInput: { reader.read() })

        #expect(gate == .nothingToRecord)
        #expect(reader.callCount == 0)
    }

    /// Switchyard's own transaction (marker present and non-empty) records
    /// nothing — and must not drain stdin to find that out.
    @Test func ownTransactionNeverDrainsStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "committed"],
            environment: [ServiceNames.yardInvocationMarkerVariable: "1"],
            readStandardInput: { reader.read() })

        #expect(gate == .nothingToRecord)
        #expect(reader.callCount == 0)
    }

    /// Present-but-empty counts as foreign — the documented escape hatch
    /// tests use through `GitProcess.extraEnvironment` — so an empty marker
    /// still forwards.
    @Test func emptyMarkerCountsAsForeign() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn", "committed"],
            environment: [ServiceNames.yardInvocationMarkerVariable: ""],
            readStandardInput: { reader.read() })

        guard case .forward = gate else {
            Issue.record("expected .forward, got \(gate)")
            return
        }
        #expect(reader.callCount == 1)
    }

    // MARK: - Refusals: logged, exit 0, stdin untouched

    /// A missing state argument — `switchyard hook ref-txn` with nothing
    /// after it — is refused before stdin is drained.
    @Test func missingStateArgumentRefusesWithoutDrainingStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "ref-txn"],
            environment: [:],
            readStandardInput: { reader.read() })

        guard case let .refused(message) = gate else {
            Issue.record("expected .refused, got \(gate)")
            return
        }
        #expect(message.contains("missing state argument"))
        #expect(reader.callCount == 0)
    }

    /// A handler this build has no arm for (`post-rewrite` lands with
    /// #0160) is refused the same way: logged, stdin untouched.
    @Test func unknownHandlerRefusesWithoutDrainingStdin() {
        let reader = StdinReader()
        let gate = HookArm.gate(
            arguments: ["hook", "post-rewrite", "amend"],
            environment: [:],
            readStandardInput: { reader.read() })

        guard case let .refused(message) = gate else {
            Issue.record("expected .refused, got \(gate)")
            return
        }
        #expect(message.contains("post-rewrite"))
        #expect(reader.callCount == 0)
    }

    /// Not a hook invocation at all — still a refusal, never a crash and
    /// never a drain.
    @Test func wrongCommandShapeRefusesWithoutDrainingStdin() {
        #expect(!refusedMessage(["hook"]).isEmpty)
        #expect(!refusedMessage(["hooks", "ref-txn", "committed"]).isEmpty)
    }

    // MARK: - dispatch routing: local, and never the remote connector

    /// `hook` is classified local by `route`, so the remote connector —
    /// whose production implementation launches the app — must never run
    /// for it. The hook connector must not run either when there is nothing
    /// to forward.
    @Test func hookPreparedNeverCallsEitherConnector() async throws {
        let remoteCounter = ConnectCounter()
        let hookCounter = ConnectCounter()

        let result = await dispatch(
            arguments: ["hook", "ref-txn", "prepared"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectHook: {
                await hookCounter.increment()
                throw AppConnectionError.appUnavailable
            })

        #expect(await remoteCounter.count == 0)
        #expect(await hookCounter.count == 0)
        #expect(result.exitCode == .success)
    }

    /// A foreign `committed` invocation reaches the hook connector exactly
    /// once — with `launchIfNeeded: false` baked in — and still exits 0
    /// when the app is unreachable. This is the first killer of the exit-0
    /// mutation: an arm that maps unreachability to a non-zero exit fails
    /// here.
    @Test func hookCommittedForeignReachesHookConnectorAndExitsZero() async throws {
        let remoteCounter = ConnectCounter()
        let hookCounter = ConnectCounter()

        let result = await dispatch(
            arguments: ["hook", "ref-txn", "committed"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectHook: {
                await hookCounter.increment()
                throw AppConnectionError.appUnavailable
            })

        #expect(await remoteCounter.count == 0)
        #expect(await hookCounter.count == 1)
        #expect(result.exitCode == .success)
    }

    /// A timed-out app is the same as an unreachable one: exit 0. The
    /// two-second bound is a judgement (see `HookArm.appTimeout`); what the
    /// invariant requires is that exhausting it changes nothing.
    @Test func hookConnectorTimeoutStillExitsZero() async throws {
        let result = await dispatch(
            arguments: ["hook", "ref-txn", "committed"],
            workingDirectory: "/",
            connect: { throw AppConnectionError.appUnavailable },
            connectHook: { throw CLIError.timedOut(HookArm.appTimeout) })

        #expect(result.exitCode == .success)
    }
}
