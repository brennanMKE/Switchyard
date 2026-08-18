// CrossToolGuard.swift — what moved behind the journal's back (#0031)

import Foundation

/// Detects and names every ref another tool moved between a journal capture
/// and now.
///
/// An agent running `git` directly between two `switchyard` commands is the
/// normal case, not the exception. The guard's job is therefore not to stop
/// other tools touching the repository — nothing can — but to **notice that
/// they did and say exactly what changed**, so a restore never silently
/// claims authority over history the journal did not create. A refusal that
/// cannot name the ref, the recorded value, and the current one is a dead end
/// for whoever hits it.
///
/// **What is compared:** the recorded `RefSnapshot` — the exact value restore
/// would write back — against a fresh capture taken under the same listing
/// rules. Restore (#0027) writes back only the refs its snapshot recorded and
/// never deletes a ref created since (guide §11 decision 20), so "the set
/// restore would touch" is exactly that snapshot's ref names, plus `HEAD`.
/// The unscoped `diff` overload below checks the union of both sides' names
/// instead, for a caller with no narrower notion of "what will be written."
/// A caller that does know — `JournalRestore` does, from the snapshot it is
/// about to apply — passes `scope`, so a ref outside it is not evidence the
/// caller's world moved, only that some *other* ref exists that this restore
/// will never touch (#0232). Guarding a wider set than the caller passes as
/// `scope` would let restore clobber unguarded state, which is the failure
/// this type exists to prevent. Pseudo-refs (`ORIG_HEAD`, `MERGE_HEAD`,
/// `AUTO_MERGE`) are outside `for-each-ref` and outside the snapshot, so they
/// are outside the guard; the index and worktree are the other primitives'
/// business (#0151, #0152).
///
/// **The value vocabulary matches the `reference-transaction` hook (#0042):**
/// a symbolic `HEAD` reports as `ref:<target>`, everything else as an object
/// id, and an absent ref as nil. The hook *observes* moves as they happen;
/// the guard *interprets* the accumulated divergence at restore time by
/// re-reading state — it never consumes hook output, so it works identically
/// in a repository whose user declined hook installation.
///
/// **Worktrees:** `HEAD` is per-worktree, so the guard sees the `HEAD` of the
/// worktree its `WorktreeContext` was resolved for — the one the entry was
/// captured in. Shared refs (`refs/heads/*` and friends) are guarded from any
/// worktree, so a sibling's commit is caught as its branch moving. Reporting
/// that a clean restore will disturb a *sibling's* checkout is #0044's layer
/// on top of this one.
///
/// **Force is the caller's decision, not this type's.** The restore flow stops
/// on the thrown error; a human-authorized `--force` skips the check entirely
/// (`bypassGuard`, and M3 owns detecting who may say so). There is deliberately
/// no `force:` parameter here — a bypass the engine offers is a bypass an agent
/// will find.
///
/// **What is compared, and by whom.** This type is *reference-agnostic*: `diff`
/// takes whatever snapshot the caller believes and reports divergence from the
/// present. Choosing the reference is the composing flow's job, and
/// `JournalRestore` supplies the **scoped chain cursor's** snapshot — the state
/// the repository is believed to be in — never the target entry's. Comparing
/// against the target would refuse every legitimate restore, since the diff
/// between a checkpoint and the present is exactly the history the caller asked
/// to revert (#0168 decision 1; #0034 decision 4 corrected 2026-08-17).
/// `requireUnchanged` below has no production call site and exists for a caller
/// that does hold a specific reference snapshot.
public enum CrossToolGuard {

    /// One ref whose current value is not what the journal recorded.
    ///
    /// `expected` is the value at capture, `actual` the value now; nil means
    /// the ref did not exist on that side. Values are object ids, except a
    /// symbolic `HEAD`, which reads `ref:<target>`. On the wire a nil side's
    /// key is omitted (synthesized `Encodable` uses `encodeIfPresent`).
    public struct Divergence: Equatable, Sendable {
        public let ref: String
        public let expected: String?
        public let actual: String?

        public init(ref: String, expected: String?, actual: String?) {
            self.ref = ref
            self.expected = expected
            self.actual = actual
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// Another tool changed refs since capture. Carries every divergence,
        /// because an agent has to branch on the report and a human has to
        /// read it — "repository changed" alone is useless to both.
        case repositoryChanged(divergences: [Divergence])

        public var description: String {
            switch self {
            case let .repositoryChanged(divergences):
                let details = divergences
                    .map { "\($0.ref) was \($0.expected ?? "absent"), now \($0.actual ?? "absent")" }
                    .joined(separator: "; ")
                return "repository changed since capture: \(details)"
            }
        }
    }

    // MARK: - Comparison

    /// Pure diff of two snapshots: `HEAD` first when it diverged, then every
    /// divergent ref name in sorted order, so the report is deterministic and
    /// two agents comparing reports see the same bytes.
    ///
    /// Unscoped: every name either side recorded is checked. This is what a
    /// caller uses when it has no narrower notion of "what will be written" —
    /// `divergences(from:in:git:)` and `requireUnchanged` below both compare
    /// the whole repository. `JournalRestore` uses the scoped overload
    /// instead (#0232).
    public static func diff(recorded: RefSnapshot, current: RefSnapshot) -> [Divergence] {
        let allNames = Set(recorded.refs.map(\.name)).union(current.refs.map(\.name))
        return diff(recorded: recorded, current: current, scope: allNames)
    }

    /// Divergences limited to `scope`, the ref names the caller is about to
    /// write. A ref outside it cannot be disturbed by this restore, so a
    /// change to one is not evidence that the caller's world moved under it
    /// (#0232). `HEAD` is always checked: restore always writes it, and it
    /// has no place in `scope`'s vocabulary of ref *names*.
    public static func diff(
        recorded: RefSnapshot, current: RefSnapshot, scope: Set<String>
    ) -> [Divergence] {
        var divergences: [Divergence] = []
        if recorded.head != current.head {
            divergences.append(Divergence(
                ref: "HEAD",
                expected: value(of: recorded.head),
                actual: value(of: current.head)
            ))
        }
        let recordedByName = Dictionary(uniqueKeysWithValues: recorded.refs.map { ($0.name, $0.oid) })
        let currentByName = Dictionary(uniqueKeysWithValues: current.refs.map { ($0.name, $0.oid) })
        for name in Set(recordedByName.keys).union(currentByName.keys).intersection(scope).sorted() {
            let expected = recordedByName[name]
            let actual = currentByName[name]
            if expected != actual {
                divergences.append(Divergence(ref: name, expected: expected, actual: actual))
            }
        }
        return divergences
    }

    /// Compares the recorded snapshot against the repository as it is now.
    /// Empty means no other tool moved anything restore would touch.
    public static func divergences(
        from recorded: RefSnapshot,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [Divergence] {
        diff(recorded: recorded, current: try RefSnapshot.capture(in: context, git: git))
    }

    /// Throws `Error.repositoryChanged` naming every divergence unless the
    /// repository's refs are exactly as recorded. Restore paths call this
    /// immediately before applying a snapshot.
    public static func requireUnchanged(
        since recorded: RefSnapshot,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let divergences = try divergences(from: recorded, in: context, git: git)
        guard divergences.isEmpty else {
            throw Error.repositoryChanged(divergences: divergences)
        }
    }

    /// The reported form of a `HEAD` value: `ref:<target>` for a symbolic
    /// `HEAD` (the `reference-transaction` hook's own vocabulary), the bare
    /// oid when detached. The distinction matters: after a plain `git commit`
    /// the branch moved but `HEAD` still points at the same branch, so `HEAD`
    /// is *not* reported — one divergence, on the ref that actually changed.
    static func value(of head: RefSnapshot.Head) -> String {
        switch head {
        case let .symbolic(target): "ref:\(target)"
        case let .detached(oid): oid
        }
    }
}

// MARK: - §6 exit class (#0141)

/// The repository is in a state the operation cannot work with — guide §6
/// code 6. Not 8 (conflicts) and not 9 (signing), the engine's only other
/// codes; the internals doc's older "exit 4" predates #0141's vocabulary,
/// under which codes 1–5 are decided above the engine.
extension CrossToolGuard.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Wire encoding (#0130)

/// A divergence rides the wire inside the structured error payload: agents
/// branch on `ref`/`expected`/`actual`, so the shape is contract, not prose.
extension CrossToolGuard.Divergence: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; byte pinning lands with the undo envelope (M3).
    private enum CodingKeys: String, CodingKey {
        case ref, expected, actual
    }
}
