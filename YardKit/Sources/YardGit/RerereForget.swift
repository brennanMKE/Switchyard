// RerereForget.swift — `git rerere forget <path>…`, the measured mutation
// path (#0065 round 2)
//
// Round 1's `Rerere` is read-only by contract, so the mutation lives here.
// What the probe measured (git 2.50.1, fixture repos under build/):
//
// - `git rerere forget <path>` removes the recorded resolution FOR THAT
//   PATH — the rr-cache entry for its conflict id loses `postimage` and
//   gains nothing back but `thisimage`; other conflict ids' postimages are
//   untouched (measured with two simultaneously recorded resolutions).
// - It works with NO live conflict: the measured run forgot a settled
//   resolution on a clean index, printing `Updated preimage for 'f.txt'`
//   and `Forgot resolution for 'f.txt'`, exit 0 — and writing MERGE_RR
//   (`<id>\tf.txt`), so `Rerere.status` afterward reports the entry as
//   merely known with the path attributed.
// - A path with nothing recorded is a SILENT no-op: exit 0, no output,
//   nothing changed (measured for a never-conflicted path). That shape is
//   refused here — the caller asked to forget a resolution, and "nothing
//   was forgotten" must not read as success.
//
// Read-only half of the verification (the pre/post state) is `Rerere.status`
// itself; this file runs the one mutating subprocess and nothing else.

import Foundation

/// What `git rerere forget` reported, parsed from its measured output
/// lines. The pre/post `Rerere.status` check is the truth that something
/// actually changed; these are the per-path details git volunteered.
public struct RerereForgetOutcome: Sendable, Equatable {

    /// The paths the forget was asked for, as passed.
    public let paths: [String]

    /// Paths git reported `Forgot resolution for '<p>'` — the resolution
    /// removals.
    public let forgot: [String]

    /// Paths git reported `Updated preimage for '<p>'` — the preimages
    /// rewritten alongside a forget.
    public let updatedPreimage: [String]

    public init(paths: [String], forgot: [String], updatedPreimage: [String]) {
        self.paths = paths
        self.forgot = forgot
        self.updatedPreimage = updatedPreimage
    }
}

/// Why a forget refused. Every case is a state the caller must see, never a
/// silent no-op dressed up as one.
public enum RerereForgetError: Error, Equatable, Sendable, CustomStringConvertible {

    /// Called with no paths at all — there is nothing to name to git.
    case emptyPaths

    /// None of `paths` had a recorded resolution to forget: git's own
    /// behavior for such a path is a silent exit-0 no-op (measured), which
    /// is refused here by comparing the recorded set before and after.
    case nothingRecorded(paths: [String])

    /// `git rerere forget` exited non-zero.
    case gitRefused(exitCode: Int32, stderr: String)

    public var description: String {
        switch self {
        case .emptyPaths:
            "rerere forget needs at least one conflicted path"
        case let .nothingRecorded(paths):
            "no recorded resolution to forget for "
                + paths.map { "'\($0)'" }.joined(separator: ", ")
        case let .gitRefused(exitCode, stderr):
            "git rerere forget exited \(exitCode)" + (stderr.isEmpty ? "" : ": \(stderr)")
        }
    }
}

/// Forgets the recorded resolution(s) for `paths` — `git rerere forget
/// <path>…` — in the repository at `repositoryPath`.
///
/// The recorded set (`Rerere.status` entries in the `.recorded` state) is
/// read before and after the subprocess: when nothing stopped being
/// recorded, the call throws `.nothingRecorded` rather than returning an
/// outcome that describes no change — that is the measured silent no-op
/// shape, and a caller deleting a resolution must not mistake it for one.
///
/// - Throws: `RerereForgetError.emptyPaths` for an empty path list,
///   `.nothingRecorded` when the recorded set did not shrink, and
///   `.gitRefused` when git itself exits non-zero.
public func rerereForget(
    at repositoryPath: String,
    _ paths: [String],
    git: GitProcess = GitProcess(),
    extraEnvironment: [String: String] = [:]
) throws -> RerereForgetOutcome {
    guard !paths.isEmpty else { throw RerereForgetError.emptyPaths }

    func recordedIDs() throws -> Set<String> {
        Set(try Rerere.status(
            at: repositoryPath, git: git, extraEnvironment: extraEnvironment)
            .entries.filter { $0.state == .recorded }.map(\.conflictID))
    }
    let before = try recordedIDs()

    let arguments = ["rerere", "forget"] + paths
    let output = try git.capture(
        arguments, workingDirectory: repositoryPath, extraEnvironment: extraEnvironment)
    guard output.exitCode == 0 else {
        throw RerereForgetError.gitRefused(exitCode: output.exitCode, stderr: output.standardError)
    }

    // Parse the two measured line shapes. MEASURED: git prints them on
    // stderr (`git rerere forget f.txt 2>/dev/null` prints nothing), so the
    // stderr lines are scanned — stdout lines too, because the pre/post
    // check below, not these details, decides success, and a stream move
    // would cost nothing but the per-path report. git quotes paths only via
    // C quoting for control characters (this engine refuses those shapes
    // elsewhere); a path with a quote in it parses short here.
    func quoted(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix("'") else { return nil }
        let body = String(line.dropFirst(prefix.count).dropLast())
        guard body.count >= 2, body.hasPrefix("'") else { return nil }
        return String(body.dropFirst())
    }
    var forgot: [String] = []
    var updatedPreimage: [String] = []
    let outputLines = output.standardError.split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init) + output.lines
    for line in outputLines {
        if let path = quoted(after: "Forgot resolution for ", in: line) {
            forgot.append(path)
        } else if let path = quoted(after: "Updated preimage for ", in: line) {
            updatedPreimage.append(path)
        }
    }

    let after = try recordedIDs()
    // Precisely: something that was recorded must no longer be. Measured,
    // forgetting a path with nothing recorded changes nothing silently —
    // and equality alone would also pass a forget that ADDED a recorded
    // entry while removing nothing. The shrink is the contract.
    guard after.count < before.count else {
        throw RerereForgetError.nothingRecorded(paths: paths)
    }

    return RerereForgetOutcome(
        paths: paths, forgot: forgot, updatedPreimage: updatedPreimage)
}

// MARK: - §6 exit class

/// A forget that names no resolution (or that git refuses) is repository
/// state, not a usage error — guide §6 code 6, the same class the read-only
/// rerere surface's errors carry.
extension RerereForgetError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
