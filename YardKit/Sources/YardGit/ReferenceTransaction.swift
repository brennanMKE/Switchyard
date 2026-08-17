// ReferenceTransaction.swift

import Foundation

/// The decision core of the `reference-transaction` hook handler (#0042).
///
/// The hook runs inside the user's own git transactions, so this type is
/// governed by two rules that are safety properties, not style:
///
/// - **`decide` is total.** It never throws and its exit code is 0 for every
///   input — a non-zero exit in the `prepared` state makes git abort the
///   user's transaction (`fatal: ref updates aborted by hook`, measured on
///   git 2.50.1), and under #0041's chaining a non-zero from any link can be
///   surfaced by the chain wrapper. There is deliberately no `Failure` enum
///   and no `ExitClassCarrying` conformance here: a handler that can fail is
///   a handler that can abort someone else's work.
/// - **Standard input is read only when it will be used.** `decide` calls
///   `readStandardInput` only for a `committed` transaction that is not
///   `switchyard`'s own, so the future CLI arm can check its argument and
///   environment and exit before ever draining stdin.
///
/// Recording the resulting updates as observed journal entries is #0028's
/// store plus a follow-up issue; forwarding to the app over XPC is M3.
/// This type only decides.
public enum ReferenceTransaction {

    /// The transaction state git passes as the hook's single argument.
    ///
    /// Measured on git 2.50.1: the states that fire are `prepared`,
    /// `committed`, and `aborted` — there is no `preparing` state despite
    /// older prose claiming one. `unrecognized` absorbs anything a future
    /// git adds, and the policy for it is the same as for every
    /// non-`committed` state: exit 0, record nothing.
    public enum State: Equatable, Sendable {
        case prepared
        case committed
        case aborted
        case unrecognized(String)

        public init(argument: String) {
            switch argument {
            case "prepared": self = .prepared
            case "committed": self = .committed
            case "aborted": self = .aborted
            default: self = .unrecognized(argument)
            }
        }
    }

    /// One `<old-value> SP <new-value> SP <ref-name> LF` stdin line.
    ///
    /// The values are object names — 40 hex chars under SHA-1, 64 under
    /// SHA-256 — or, for a symbolic update, `ref:<ref-target>`. The
    /// all-zeros object name marks "no value": zeros → oid is a creation,
    /// oid → zeros is a deletion. Both fields can be zeros at once — git
    /// emits `0{40} 0{40} AUTO_MERGE` transactions routinely — and a
    /// deletion's old value is *what the caller passed in*, which is zeros
    /// for an unconditional `git update-ref -d`, so "deletion" is decided
    /// on the new value alone.
    public struct RefUpdate: Equatable, Sendable {
        public let oldValue: String
        public let newValue: String
        public let refName: String

        public init(oldValue: String, newValue: String, refName: String) {
            self.oldValue = oldValue
            self.newValue = newValue
            self.refName = refName
        }

        /// The ref did not exist before this transaction (as far as the
        /// caller asserted): old is all-zeros, new is a real value.
        public var isCreation: Bool {
            Self.isAllZeros(oldValue) && !Self.isAllZeros(newValue)
        }

        /// The ref does not exist after this transaction: new is all-zeros.
        public var isDeletion: Bool {
            Self.isAllZeros(newValue)
        }

        /// Either side is a symbolic target (`ref:refs/heads/main`), which
        /// git emits for `git symbolic-ref` and branch checkouts of `HEAD`.
        public var isSymbolic: Bool {
            oldValue.hasPrefix("ref:") || newValue.hasPrefix("ref:")
        }

        static func isAllZeros(_ value: String) -> Bool {
            !value.isEmpty && value.allSatisfy { $0 == "0" }
        }
    }

    /// What `parse` understood, and what it had to drop.
    public struct ParseResult: Equatable, Sendable {
        public let updates: [RefUpdate]
        /// Lines that did not carry three fields. Counted rather than thrown:
        /// the handler must not fail, but it must not pretend either.
        public let malformedLineCount: Int

        public init(updates: [RefUpdate], malformedLineCount: Int) {
            self.updates = updates
            self.malformedLineCount = malformedLineCount
        }
    }

    /// The handler's verdict for one hook invocation.
    public struct Decision: Equatable, Sendable {
        /// Always 0 — see the type comment. Modeled explicitly so the
        /// invariant is assertable rather than implicit.
        public let exitCode: Int32
        /// Updates to record as observed entries. Empty unless the state is
        /// `committed` and the transaction is not `switchyard`'s own.
        public let updates: [RefUpdate]
        /// Malformed stdin lines dropped while parsing. 0 whenever stdin
        /// was not read.
        public let malformedLineCount: Int
    }

    /// Decides what one hook invocation does.
    ///
    /// - Parameters:
    ///   - stateArgument: the hook's single argument, verbatim.
    ///   - environment: the hook process's environment. Git propagates its
    ///     own environment to hooks, and `GitProcess` sets the marker on
    ///     every invocation, so `switchyard`'s own transactions carry
    ///     `markerVariable` set to a non-empty value here (measured; empty
    ///     means foreign, which is what lets tests simulate other tools
    ///     through `GitProcess.extraEnvironment`).
    ///   - markerVariable: the environment variable naming our own
    ///     transactions. Defaults to `GitProcess.markerVariable`; a
    ///     parameter so a rename by #0028 is one line here.
    ///   - readStandardInput: called at most once, and only for a foreign
    ///     `committed` transaction.
    public static func decide(
        stateArgument: String,
        environment: [String: String],
        markerVariable: String = GitProcess.markerVariable,
        readStandardInput: () -> Data
    ) -> Decision {
        guard State(argument: stateArgument) == .committed else {
            return Decision(exitCode: 0, updates: [], malformedLineCount: 0)
        }
        if let marker = environment[markerVariable], !marker.isEmpty {
            return Decision(exitCode: 0, updates: [], malformedLineCount: 0)
        }
        let parsed = parse(readStandardInput())
        return Decision(
            exitCode: 0,
            updates: parsed.updates,
            malformedLineCount: parsed.malformedLineCount
        )
    }

    /// Parses hook stdin: `<old-value> SP <new-value> SP <ref-name> LF` per
    /// update. Ref names cannot contain SP or LF (`git check-ref-format`),
    /// so splitting on both is exact; `maxSplits: 2` keeps the ref name
    /// whole even if a future git relaxes that. Decoding is lossy UTF-8 —
    /// the values are hex or `ref:`-prefixed names, and a mangled ref name
    /// in an observed record is recoverable where a crashed hook is not.
    public static func parse(_ input: Data) -> ParseResult {
        var updates: [RefUpdate] = []
        var malformed = 0
        for line in input.split(separator: UInt8(ascii: "\n")) {
            let text = String(decoding: line, as: UTF8.self)
            let fields = text.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty,
                  !fields[2].isEmpty else {
                malformed += 1
                continue
            }
            updates.append(RefUpdate(
                oldValue: String(fields[0]),
                newValue: String(fields[1]),
                refName: String(fields[2])
            ))
        }
        return ParseResult(updates: updates, malformedLineCount: malformed)
    }
}

/// `RefUpdate` rides inside an observed journal entry's metadata (#0153), so
/// its keys are pinned rather than synthesized: a rename here silently changes
/// bytes already written into a repository's refs.
extension ReferenceTransaction.RefUpdate: Encodable {
    private enum CodingKeys: String, CodingKey {
        case oldValue, newValue, refName
    }
}

extension ReferenceTransaction {

    /// What one `reference-transaction` hook invocation did.
    public struct HookOutcome: Equatable, Sendable {
        /// What the hook must exit with. **Always 0**, including when
        /// recording failed — a non-zero exit from this hook aborts the
        /// user's ref transaction (`fatal: ref updates aborted by hook`,
        /// exit 128, measured), so a journal defect must never become a
        /// repository defect.
        public let exitCode: Int32
        /// The observed entry written, when one was.
        public let recorded: JournalAnchor.Entry?
        /// Why recording failed, when it did. Present *and* `exitCode == 0`
        /// is the normal shape of a swallowed failure; a caller that wants to
        /// surface it may, but the hook does not.
        public let recordingFailure: String?
        /// Malformed stdin lines dropped while parsing.
        public let malformedLineCount: Int
    }

    /// Runs one hook invocation end to end: decide, then persist.
    ///
    /// The decision core owns the invariants (exit 0 always; only `committed`
    /// reads stdin; our own transactions are skipped via the marker). This
    /// adds persistence and **catches everything it can throw**, which is the
    /// whole reason it is a separate function rather than a call site.
    public static func runHook(
        stateArgument: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        in context: WorktreeContext,
        markerVariable: String = GitProcess.markerVariable,
        git: GitProcess = GitProcess(),
        readStandardInput: () -> Data
    ) -> HookOutcome {
        let decision = decide(
            stateArgument: stateArgument,
            environment: environment,
            markerVariable: markerVariable,
            readStandardInput: readStandardInput)

        guard !decision.updates.isEmpty else {
            return HookOutcome(
                exitCode: decision.exitCode, recorded: nil,
                recordingFailure: nil,
                malformedLineCount: decision.malformedLineCount)
        }

        do {
            let entry = try JournalObserved.record(
                decision.updates, in: context, git: git)
            return HookOutcome(
                exitCode: decision.exitCode, recorded: entry,
                recordingFailure: nil,
                malformedLineCount: decision.malformedLineCount)
        } catch {
            // Deliberately total. Every failure mode of the store -- a git
            // that cannot run, a ref that already exists, a full disk --
            // lands here and still exits 0.
            return HookOutcome(
                exitCode: decision.exitCode, recorded: nil,
                recordingFailure: String(describing: error),
                malformedLineCount: decision.malformedLineCount)
        }
    }
}
