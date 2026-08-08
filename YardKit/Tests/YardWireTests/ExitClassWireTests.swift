// ExitClassWireTests.swift — engine failures carry the §6 exit code (#0141)
//
// The one place both vocabularies are visible from production types:
// `ExitClass` (YardGit) declares its raw values to be the §6 codes, and
// `ExitCode` (YardKit) owns the authoritative table. These tests pin the
// pairing and each conforming error's class, so M3 registration is the
// mechanical `ExitCode(rawValue: Int(error.exitClass.rawValue))` rather than
// a per-command judgment call.

import Testing
import YardGit
import YardKit

@Suite("§6 exit classes")
struct ExitClassWireTests {

    /// Maps each engine class to its `ExitCode` case and the label the
    /// failure envelope will carry. A switch, not a dictionary, so a new
    /// `ExitClass` case is a compile error here before it can dodge the
    /// pairing test.
    private func expectedPairing(_ cls: ExitClass) -> (code: ExitCode, label: String) {
        switch cls {
        case .repositoryError: (.repositoryError, "repository_error")
        case .blockedOnConflicts: (.blockedOnConflicts, "blocked_on_conflicts")
        case .signingFailed: (.signingFailed, "signing_failed")
        }
    }

    /// The §6 numbers themselves, as literals — so renumbering `ExitClass`
    /// is red even if `ExitCode` were someday renumbered to match it.
    @Test func exitClassRawValuesAreTheSectionSixCodes() {
        #expect(ExitClass.repositoryError.rawValue == 6)
        #expect(ExitClass.blockedOnConflicts.rawValue == 8)
        #expect(ExitClass.signingFailed.rawValue == 9)
        #expect(ExitClass.allCases.count == 3)
    }

    /// Every engine class resolves to a real `ExitCode` carrying the same
    /// number, paired with the expected case and envelope label.
    @Test func everyExitClassPairsWithAYardKitExitCode() throws {
        for cls in ExitClass.allCases {
            let exitCode = try #require(
                ExitCode(rawValue: Int(cls.rawValue)),
                "ExitClass.\(cls) (\(cls.rawValue)) has no ExitCode counterpart")
            let expected = expectedPairing(cls)
            #expect(exitCode == expected.code)
            #expect(exitCode.codeLabel == expected.label)
        }
    }

    /// `WorktreeContext.Error`: both cases are repository-state failures —
    /// §6 code 6. The count is asserted so the loop cannot go vacuous.
    @Test func worktreeContextErrorCasesAreRepositoryErrors() {
        let failures: [WorktreeContext.Error] = [
            .notARepository(path: "/tmp/empty", detail: "fatal: not a git repository"),
            .pathNotResolved(name: "MERGE_HEAD"),
        ]
        #expect(failures.count == 2)
        for failure in failures {
            #expect(failure.exitClass == .repositoryError)
            #expect(ExitCode(rawValue: Int(failure.exitClass.rawValue)) == .repositoryError)
        }
    }

    /// `WorktreeRemoveError`: all five refusals are repository-state
    /// failures — §6 code 6. `unclean` is dirty files, not unresolved
    /// conflicts, so it is a 6 and not an 8; 8 is reserved for operations
    /// blocked on an unmerged index (M2).
    @Test func worktreeRemoveErrorCasesAreRepositoryErrors() {
        let failures: [WorktreeRemoveError] = [
            .unclean(paths: ["a.txt"]),
            .unknown(path: "/x"),
            .nested(inside: "/a", target: "/a/b"),
            .unknownFailure(code: 128, stderr: "boom"),
            .lockFailed(path: "/x", detail: "locked"),
        ]
        #expect(failures.count == 5)
        for failure in failures {
            #expect(failure.exitClass == .repositoryError)
            #expect(ExitCode(rawValue: Int(failure.exitClass.rawValue)) == .repositoryError)
        }
    }

    /// `WorktreeAddError`: all six refusals are repository-state failures —
    /// §6 code 6. `invalidBranchName` is a 6 and not a usage error: usage
    /// (§6 code 1) is about the CLI invocation itself and is decided before
    /// the engine runs — git refusing the name is repository semantics.
    @Test func worktreeAddErrorCasesAreRepositoryErrors() {
        let failures: [WorktreeAddError] = [
            .branchInUse(branch: "main", holderPath: "/a", holderIsMainWorktree: true),
            .branchExists("main"),
            .invalidBranchName("bad..name"),
            .pathExists("/x"),
            .invalidReference("nonexistent"),
            .unknownFailure(code: 128, stderr: "boom"),
        ]
        #expect(failures.count == 6)
        for failure in failures {
            #expect(failure.exitClass == .repositoryError)
            #expect(ExitCode(rawValue: Int(failure.exitClass.rawValue)) == .repositoryError)
        }
    }

    /// The class is reachable through the protocol from an untyped `any
    /// Error` — the shape a generic catch site uses. A runtime cast, so
    /// removing `: ExitClassCarrying` while keeping an `exitClass` property
    /// is red here, not silently absorbed.
    @Test func conformancesAreReachableThroughAnyError() {
        let failures: [any Error] = [
            WorktreeContext.Error.pathNotResolved(name: "HEAD"),
            WorktreeRemoveError.unclean(paths: ["a.txt"]),
            WorktreeAddError.branchExists("main"),
        ]
        for failure in failures {
            #expect(
                failure is any ExitClassCarrying,
                "\(type(of: failure)) does not declare its §6 exit class")
        }
    }
}
