// Absorb.swift — distribute staged hunks into the commits that last touched their lines (#0061)

import Foundation

/// The outcome absorb decided for one staged hunk: either the ancestor commit
/// the hunk is confident to belong in, or a report that the hunk stays staged.
///
/// The confidence rule is the one the issue makes load-bearing: every
/// old-side line the hunk touches must blame — against `HEAD`, range-limited
/// (#0018) — to **one** commit. Mixed tips, boundary commits, uncommitted
/// lines, and paths that do not exist in `HEAD` are all unconfident: the
/// hunk stays staged and is reported, never guessed into the wrong commit.
/// Absorbing a hunk into the wrong commit is worse than not absorbing it,
/// because a human reviewing the result will not notice.
public struct AbsorbHunkOutcome: Sendable, Equatable, Encodable {

    /// The hunk's stable content-derived id, as the staged listing reported it.
    public let hunkID: String

    /// Path relative to the repository root, as the hunk's diff reported it.
    public let path: String

    /// True when the hunk had no confident target and remains staged. Its
    /// staged state is never consumed by a run — confident hunks are staged
    /// away one target at a time, and the index is preserved around the
    /// rewrite — so what is left staged after absorb is exactly this hunk
    /// set, reported here.
    public let leftStaged: Bool

    /// The confident target commit's full oid: the one commit every line the
    /// hunk touches blames to. `nil` exactly when `leftStaged` is true.
    public let target: String?

    /// Why the hunk stayed staged. `nil` exactly when `leftStaged` is false.
    public let reason: String?

    public init(hunkID: String, path: String, leftStaged: Bool,
                target: String?, reason: String?) {
        self.hunkID = hunkID
        self.path = path
        self.leftStaged = leftStaged
        self.target = target
        self.reason = reason
    }

    /// The stable wire keys. Identical to the stored-member names on purpose;
    /// no raw values — the case name IS the wire key. `target` and `reason`
    /// are absent when nil: presence is the confidence signal, and `nil`
    /// encoding as JSON `null` would make every reader unwrap-or-special-case.
    private enum CodingKeys: String, CodingKey {
        case hunkID, path, leftStaged, target, reason
    }
}

/// The per-hunk distribution absorb planned (or executed), one outcome per
/// hunk of the staged diff, in listing order.
public struct AbsorbPlan: Sendable, Equatable, Encodable {

    /// Every hunk's outcome, in the staged listing's order.
    public let hunks: [AbsorbHunkOutcome]

    public init(hunks: [AbsorbHunkOutcome]) {
        self.hunks = hunks
    }

    /// Hunks absorb will (or did) commit into their targets.
    public var confident: [AbsorbHunkOutcome] {
        hunks.filter { !$0.leftStaged }
    }

    /// Hunks left staged and reported — never guessed into a commit.
    public var unconfident: [AbsorbHunkOutcome] {
        hunks.filter { $0.leftStaged }
    }

    /// The stable wire key, identical to the stored-member name.
    private enum CodingKeys: String, CodingKey {
        case hunks
    }
}

/// Distributes the **staged index** into the prior commits that last touched
/// each hunk's lines — the engine behind `yard absorb`, and the highest-
/// leverage command for cleaning up an agent's messy branch.
///
/// The mechanism is `Fixup`'s measured sequence generalized to many targets
/// (#0060's decision):
///
/// 1. **Match** — the staged diff is split into per-file hunks (`listHunks`),
///    and each hunk's old-side lines are blamed against `HEAD`, restricted
///    to the lines it touches (`blameFile`'s structured output). All lines
///    resolving to one ancestor commit is a confident target; anything else
///    — mixed tips, boundary commits, uncommitted lines, a path absent from
///    `HEAD` — stays staged and is reported.
/// 2. **Stage per target** — the index is reset to `HEAD`, then for each
///    target (oldest first) that target's hunks are applied with one
///    `git apply --cached` and committed as one `git commit --fixup=<target>`
///    through `CommitCreate`'s signing path. Unconfident hunks are never
///    staged away: the index is snapshotted before the reset and restored
///    after the rebase, which also preserves binary and mode-only staged
///    content no patch text can express.
/// 3. **Replay once** — one `git rebase --autosquash` from the lowest
///    target's parent (or `--root` when that parent does not resolve, the
///    same probe `Fixup` measures), with the same conflict contract: a
///    conflicted replay leaves the rebase in progress, resumable.
/// 4. **Checkpoint** — the whole distribution runs inside one
///    `JournalCheckpoint.around(operation: "absorb")`, so `yard undo`
///    reverses it as a single step (#0212's trap). The guards and the
///    planning run *before* the checkpoint, and a run with no confident
///    hunk never enters it: nothing mutated, nothing to reverse.
/// 5. **Signing** — `CommitCreate.Signing` is forwarded to every fixup
///    commit and the rebase: the explicit-flag rule, never config-reliant.
///
/// The pre-absorb **final tree is preserved by construction**: absorb only
/// redistributes existing staged changes into earlier commits, so the tips'
/// trees differ only by where the confident hunks sit in history.
public struct Absorb: Equatable, Sendable {

    /// What absorb planned — and, after a run, what it did: one outcome per
    /// staged hunk, confident hunks naming their target commit.
    public let plan: AbsorbPlan

    /// `HEAD` after the rewrite — `nil` when nothing was rewritten: a
    /// `--dry-run` plan, or a run where every hunk was unconfident and
    /// nothing had to change. A run that absorbed at least one hunk always
    /// carries the rewritten `HEAD`, even when it equals the pre-absorb tip
    /// (possible when every confident target sat above every replayed
    /// commit's changes — absorbed into the tip itself).
    public let head: String?

    public init(plan: AbsorbPlan, head: String?) {
        self.plan = plan
        self.head = head
    }

    /// Plans and, unless `dryRun`, executes the distribution.
    ///
    /// - Parameter dryRun: the pure planning mode — the staged diff is split
    ///   and classified, nothing is touched (no index write, no commit, no
    ///   rebase, **and no journal checkpoint**, which would itself move a
    ///   ref), and the returned `plan` is the whole payload.
    /// - Parameter signing: forwarded to every fixup commit and the rebase,
    ///   exactly as `Fixup.run` forwards it — see that doc comment for the
    ///   measured `.config` semantics.
    /// - Parameter extraEnvironment: merged over the process environment for
    ///   every invocation. Tests use it to neutralize global and system
    ///   config scope; production callers leave it empty.
    /// - Throws: `AbsorbError.nothingStaged` when the index has nothing
    ///   staged; `.blockedOnConflicts` when the index already holds unmerged
    ///   entries (refused before anything is touched — proceeding would
    ///   silently drop the staged conflict resolution — or when the
    ///   autosquash rebase cannot apply cleanly, which leaves the rebase in
    ///   progress, resumable); `.signingFailed` when a signature was
    ///   attempted and could not be produced, leaving no rebase in progress;
    ///   `GitProcess.Failure` for every other non-zero exit.
    public static func run(
        dryRun: Bool = false,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Absorb {
        // 1. Refuse an empty index. Measured in #0039: `git commit --fixup=`
        //    with nothing staged silently no-ops, so the guard is ours.
        let staged = try git.run(
            ["diff", "--cached", "--name-only"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        ).lines
        guard !staged.isEmpty else {
            throw AbsorbError.nothingStaged
        }

        // 2. Refuse an unmerged index. A staged conflict resolution is work
        //    the step below would reset away and no patch text can rebuild
        //    (the resolution's stages are not a diff), so absorb refuses
        //    before anything is touched — the same "cannot proceed over
        //    unresolved conflicts" contract guide §6 code 8 exists for.
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw AbsorbError.blockedOnConflicts(files: conflicts)
        }

        // 3. Split the staged diff into per-file hunks and classify each.
        let files = try listHunks(at: path, area: .staged, git: git)
        let plan = try classify(files: files, at: path, git: git)

        // 4. A dry run is pure planning — no checkpoint, no mutation. So is a
        //    run whose plan has no confident hunk: nothing would be staged
        //    away or rewritten, so there is nothing to checkpoint or undo.
        if dryRun || plan.confident.isEmpty {
            return Absorb(plan: plan, head: nil)
        }

        // 5. Everything past this point is one checkpoint for the whole
        //    distribution.
        return try JournalCheckpoint.around(operation: "absorb", at: path, git: git) { scoped in
            try perform(
                plan: plan,
                files: files,
                signing: signing,
                at: path,
                git: scoped,
                extraEnvironment: extraEnvironment
            )
        }
    }
}

// MARK: - Classification (match)

extension Absorb {

    /// Classifies every hunk of the staged diff: blame the hunk's path
    /// against `HEAD`, restricted to the old-side lines it touches; all
    /// blamed lines resolving to one ancestor commit is a confident target,
    /// anything else stays staged and is reported.
    ///
    /// "The lines it touches" are the hunk's old-side `-` lines — the lines
    /// the change replaces or removes. Context lines are deliberately not
    /// blamed: with `--unified=3` they reach three lines into neighboring
    /// hunks' territory, and blaming them would make nearly every hunk in a
    /// multi-commit file read as mixed. A pure-insertion hunk (no old-side
    /// lines at all, `oldCount == 0`) attributes to the line it inserts
    /// against — the anchor line just above the insertion, or line 1 when
    /// the insertion opens the file.
    ///
    /// Files without hunks (binary and mode-only changes) and combined
    /// (`diff --cc`) blocks — the shape an unmerged path prints — never
    /// reach a blame call at all: both stay staged and are reported.
    private static func classify(
        files: [FileDiff],
        at path: String,
        git: GitProcess
    ) throws -> AbsorbPlan {
        var outcomes: [AbsorbHunkOutcome] = []
        for file in files {
            let combined = file.headerText.hasPrefix("diff --cc ")
            for hunk in file.hunks {
                if combined {
                    outcomes.append(AbsorbHunkOutcome(
                        hunkID: hunk.id, path: file.path, leftStaged: true, target: nil,
                        reason: "conflicted path — resolve the conflict, then re-run absorb"))
                    continue
                }
                let touched = oldSideLines(hunk)
                guard !touched.isEmpty else {
                    outcomes.append(AbsorbHunkOutcome(
                        hunkID: hunk.id, path: file.path, leftStaged: true, target: nil,
                        reason: "hunk touches no line of HEAD's file"))
                    continue
                }
                outcomes.append(
                    try classifyHunk(hunk, path: file.path, touched: touched, at: path, git: git))
            }
        }
        return AbsorbPlan(hunks: outcomes)
    }

    /// One hunk's attribution: blame `HEAD` restricted to the touched lines,
    /// then decide confidence by the blames' tips.
    private static func classifyHunk(
        _ hunk: Hunk,
        path: String,
        touched: [Int],
        at repoPath: String,
        git: GitProcess
    ) throws -> AbsorbHunkOutcome {
        let range = touched.min()! ... touched.max()!
        let blamed: [BlameLine]
        do {
            blamed = try blameFile(
                at: repoPath, file: path, lines: range, revision: "HEAD", git: git)
        } catch let failure as GitProcess.Failure {
            // A path with nothing to blame in HEAD — a staged new file above
            // all. Unconfident is the safe verdict here: the hunk stays
            // staged and is reported, with git's own detail as the reason.
            return AbsorbHunkOutcome(
                hunkID: hunk.id, path: path, leftStaged: true, target: nil,
                reason: "no commit in HEAD's history to attribute \(path) to — "
                    + "the hunk stays staged")
        }
        let lines = blamed.filter { touched.contains($0.finalLine) }
        guard !lines.isEmpty else {
            return AbsorbHunkOutcome(
                hunkID: hunk.id, path: path, leftStaged: true, target: nil,
                reason: "blame attributed none of the touched lines — the hunk stays staged")
        }
        // Boundary commits attribute their lines "no earlier than here", so
        // one in the set makes the target a guess. Measured: every root
        // commit's lines carry `boundary` in porcelain output.
        if lines.contains(where: \.isBoundary) {
            return AbsorbHunkOutcome(
                hunkID: hunk.id, path: path, leftStaged: true, target: nil,
                reason: "a touched line is attributed to a boundary commit (a root commit) — "
                    + "the hunk stays staged")
        }
        // Defensive: blaming `HEAD` can never yield uncommitted lines, but
        // the issue's rule names them, so the guard is stated here rather
        // than assumed dead.
        if lines.contains(where: \.isUncommitted) {
            return AbsorbHunkOutcome(
                hunkID: hunk.id, path: path, leftStaged: true, target: nil,
                reason: "a touched line is not in any commit — the hunk stays staged")
        }
        let tips = Set(lines.map(\.oid))
        guard tips.count == 1, let target = tips.first else {
            let shorts = tips.map { String($0.prefix(7)) }.sorted().joined(separator: ", ")
            return AbsorbHunkOutcome(
                hunkID: hunk.id, path: path, leftStaged: true, target: nil,
                reason: "the touched lines are last touched by several commits (\(shorts)) — "
                    + "no confident target, the hunk stays staged")
        }
        return AbsorbHunkOutcome(
            hunkID: hunk.id, path: path, leftStaged: false, target: target, reason: nil)
    }

    /// The old-side line numbers a hunk touches, walked the way the hunk's
    /// own line budget is consumed: context and `-` lines advance the old
    /// side, `+` and `\` lines do not.
    private static func oldSideLines(_ hunk: Hunk) -> [Int] {
        var touched: [Int] = []
        var oldLine = hunk.oldStart
        for line in hunk.body {
            switch line.first {
            case "-":
                touched.append(oldLine)
                oldLine += 1
            case " ":
                oldLine += 1
            default:
                break
            }
        }
        // A pure-insertion hunk touches no old-side line; its anchor is the
        // line the insertion goes against (line 1 when the header starts at
        // old line 0 — an insertion above the file's first line).
        if touched.isEmpty, hunk.oldCount == 0 {
            touched.append(max(hunk.oldStart, 1))
        }
        return touched
    }
}

// MARK: - Execution

extension Absorb {

    /// Runs the distribution: one fixup commit per target, oldest target
    /// first, then one autosquash rebase from the lowest target's parent.
    /// Assumes the guards passed, the plan has a confident hunk, and the
    /// checkpoint is already written.
    ///
    /// The index is snapshotted before the reset and restored after the
    /// rebase. That is what keeps unconfident hunks staged without re-
    /// staging them as text — and it is also what preserves staged binary
    /// and mode-only content, which no patch text can express: the restored
    /// bytes name the same blobs, and against the rewritten tip they read as
    /// exactly the staged set that was never absorbed.
    private static func perform(
        plan: AbsorbPlan,
        files: [FileDiff],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Absorb {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let indexSnapshot = try IndexSnapshot.capture(in: context, git: git)

        // The fixup commits are built hunk-by-hunk on a clean index: reset
        // to HEAD, apply one target's hunks, commit --fixup. What is left
        // staged comes back from the snapshot after the rebase.
        try git.run(
            ["reset", "-q", "--mixed", "HEAD"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )

        var groups: [String: [AbsorbHunkOutcome]] = [:]
        for outcome in plan.confident {
            guard let target = outcome.target else { continue }
            groups[target, default: []].append(outcome)
        }
        // Oldest target first — the rebase's base is the lowest one, and
        // autosquash folds each fixup into its own target in one pass.
        let order = try git.run(
            ["rev-list", "HEAD"], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.reversed()
        let targets = order.filter { groups[$0] != nil }

        for target in targets {
            let ids = groups[target]!.map(\.hunkID)
            let patch = try selectPatch(ids: ids, from: files, area: .staged)
            try applyPatchToIndex(patch, at: path, git: git)
            try commitFixup(
                target: target, signing: signing, at: path, git: git,
                extraEnvironment: extraEnvironment)
        }

        try autosquashRebase(
            lowestTarget: targets.first!, signing: signing, at: path, git: git,
            extraEnvironment: extraEnvironment)

        // The pre-absorb index bytes, back: the unconfident hunks (and any
        // binary or mode-only staged content) are staged exactly as they
        // were, while the confident hunks now match HEAD and drop out of the
        // staged diff on their own.
        try indexSnapshot.restore(in: context, git: git)

        let head = try git.run(
            ["rev-parse", "HEAD"], workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        return Absorb(plan: plan, head: head)
    }

    /// One `git commit --fixup=<target>`, signing per intent — the measured
    /// sequence #0039 runs, via `CommitCreate`'s classification of a failed
    /// commit. No rebase has started at this point, so there is nothing to
    /// abort.
    private static func commitFixup(
        target: String,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let commitArguments = ["commit", "--fixup=\(target)"] + CommitCreate.arguments(for: signing)
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        let output: GitProcess.Output
        do {
            output = try git.capture(
                commitArguments,
                workingDirectory: path,
                extraEnvironment: extraEnvironment,
                timeout: inEffect ? GitProcess.signingTimeout : nil
            )
        } catch let failure as GitProcess.Failure {
            if case .timedOut = failure {
                throw classifyTimeout(failure, signingInEffect: inEffect)
            }
            throw failure
        }
        guard output.exitCode == 0 else {
            throw try classifiedCommitFailure(
                output: output,
                arguments: commitArguments,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }
    }

    /// One `git rebase --autosquash <lowest>^` — or `--root` when that
    /// parent does not resolve, the same quiet probe Fixup measures — with
    /// `--autostash`, because absorb is exactly the case git's rebase
    /// cleanliness check would otherwise refuse: the staged content not being
    /// absorbed still sits in the worktree or the index, and `--autostash`
    /// rides it out of the rewrite and back. The conflict contract is
    /// Fixup's, measured: non-empty conflicts leave the rebase in progress,
    /// resumable; a signing failure aborts it first.
    private static func autosquashRebase(
        lowestTarget: String,
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws {
        let parentProbe = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(lowestTarget)^"],
            workingDirectory: path,
            extraEnvironment: extraEnvironment
        )
        let rebaseArguments: [String]
        if parentProbe.exitCode == 0 {
            rebaseArguments = ["rebase", "--autosquash", "--autostash", "\(lowestTarget)^"]
                + CommitCreate.arguments(for: signing)
        } else {
            rebaseArguments = ["rebase", "--autosquash", "--autostash", "--root"]
                + CommitCreate.arguments(for: signing)
        }
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        let rebaseOutput: GitProcess.Output
        do {
            rebaseOutput = try git.capture(
                rebaseArguments,
                workingDirectory: path,
                extraEnvironment: extraEnvironment,
                timeout: inEffect ? GitProcess.signingTimeout : nil
            )
        } catch let failure as GitProcess.Failure {
            if case .timedOut = failure {
                // A timed-out rebase can never be resumed from mid-hang, so
                // it is aborted unconditionally, exactly as Fixup's does.
                _ = try? git.run(
                    ["rebase", "--abort"], workingDirectory: path,
                    extraEnvironment: extraEnvironment)
                throw classifyTimeout(failure, signingInEffect: inEffect)
            }
            throw failure
        }
        guard rebaseOutput.exitCode == 0 else {
            throw try classifiedRebaseFailure(
                output: rebaseOutput,
                arguments: rebaseArguments,
                signing: signing,
                at: path,
                git: git,
                extraEnvironment: extraEnvironment
            )
        }
    }

    /// Classifies a failed `git commit --fixup=…`. No rebase has started, so
    /// there is nothing to abort — a signing failure or a plain repository
    /// error, exactly as Fixup classifies the same shape.
    private static func classifiedCommitFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: inEffect) {
            switch failure {
            case let .signingFailed(reason):
                return AbsorbError.signingFailed(reason: reason)
            }
        }
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a failed `git rebase --autosquash …`, by the index and not
    /// the message: non-empty conflicts stay resumable (`.blockedOnConflicts`,
    /// no abort); a signing failure aborts first (it can never sign, so it is
    /// not resumable); neither aborts and surfaces git's own failure.
    private static func classifiedRebaseFailure(
        output: GitProcess.Output,
        arguments: [String],
        signing: CommitCreate.Signing,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> Error {
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            return AbsorbError.blockedOnConflicts(files: conflicts)
        }

        let inEffect = try CommitCreate.signingInEffect(
            signing, in: path, git: git, extraEnvironment: extraEnvironment)
        if let failure = CommitCreate.classify(
            stderr: output.standardError, signingInEffect: inEffect) {
            _ = try? git.run(
                ["rebase", "--abort"], workingDirectory: path,
                extraEnvironment: extraEnvironment)
            switch failure {
            case let .signingFailed(reason):
                return AbsorbError.signingFailed(reason: reason)
            }
        }

        _ = try? git.run(
            ["rebase", "--abort"], workingDirectory: path, extraEnvironment: extraEnvironment)
        return GitProcess.Failure.exited(
            code: output.exitCode, stderr: output.standardError, arguments: arguments)
    }

    /// Classifies a `GitProcess.Failure.timedOut` from either the fixup
    /// commit or the rebase, the mirror of `Fixup.classifyTimeout`. Signing
    /// in effect -> `.signingFailed`; otherwise `failure` is rethrown
    /// unchanged, keeping `ExitClass.repositoryError` via `GitProcess.
    /// Failure`'s own conformance. Pure and subprocess-free -- the caller
    /// aborts the rebase itself before calling this, since that is a side
    /// effect, not a classification.
    static func classifyTimeout(_ failure: GitProcess.Failure, signingInEffect: Bool) -> Error {
        guard case let .timedOut(after, _, _) = failure, signingInEffect else { return failure }
        return AbsorbError.signingFailed(
            reason: "the autosquash rewrite did not finish within \(after) and was terminated -- "
                + "likely a signing prompt with no way to answer it")
    }
}

// MARK: - Errors

/// Why `Absorb.run` refused, or could not finish.
public enum AbsorbError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The index has nothing staged to distribute.
    case nothingStaged
    /// Either the index already held unmerged entries (refused before
    /// anything was touched — proceeding would silently drop the staged
    /// conflict resolution), or the autosquash rebase could not apply
    /// cleanly. In the rebase case the rebase is left in progress,
    /// resumable, and `files` names the conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced. No rebase is
    /// left in progress.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case .nothingStaged:
            "nothing staged to absorb"
        case let .blockedOnConflicts(files):
            "absorb blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class (#0141)

extension AbsorbError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .nothingStaged: .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}
