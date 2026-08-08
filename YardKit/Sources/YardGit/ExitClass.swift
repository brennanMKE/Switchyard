// ExitClass.swift — the §6 exit-code class an engine failure carries (#0141)

/// The guide §6 exit-code classes an engine failure can map to. The raw
/// values ARE the §6 exit codes — 6, 8, 9 — written here as literals because
/// the authoritative table (`ExitCode` in `YardKit`) lives on the other side
/// of a boundary neither target may import across: `LayeringTests` asserts
/// both arrow directions from the source. The pairing — number and envelope
/// label — is pinned by `ExitClassWireTests` in `YardWireTests`, the one test
/// target that sees both sides, so drift between the two enums is a red test
/// rather than a silent renumbering.
///
/// Only the engine-reachable classes appear. Codes 1–5 and 7 (usage, the four
/// XPC codes, human-declined) are decided before or above the engine, never
/// by it: a `YardGit` failure is always about the repository's state, its
/// conflicts, or signing. `blockedOnConflicts` and `signingFailed` have no
/// conforming error yet — M2's mutating and signing operations produce them —
/// but the vocabulary is closed here once so M2 conforms without reopening
/// this file, and the pairing test already covers all three.
public enum ExitClass: Int32, CaseIterable, Equatable, Sendable {

    /// The repository is in a state the operation cannot work with —
    /// guide §6 code 6, envelope label `repository_error`.
    case repositoryError = 6

    /// A mutating operation cannot proceed over unresolved conflicts —
    /// guide §6 code 8, envelope label `blocked_on_conflicts`.
    case blockedOnConflicts = 8

    /// Producing a signature failed — guide §6 code 9, envelope label
    /// `signing_failed`.
    case signingFailed = 9
}

/// An engine failure that declares which §6 exit code it maps to.
///
/// Same shape as #0129's `Encodable` decision: the declaration lives in the
/// engine and uses nothing outside this module, so the dependency arrow does
/// not move. `YardKit` never sees this protocol — at wiring time (M3) the
/// registration layer converts with `ExitCode(rawValue:
/// Int(error.exitClass.rawValue))`, a total conversion because the pairing
/// test pins every case.
public protocol ExitClassCarrying: Error {
    /// The §6 class this failure maps to. Declared per error type so the
    /// mapping is engine contract, not per-command judgment at wiring time.
    var exitClass: ExitClass { get }
}
