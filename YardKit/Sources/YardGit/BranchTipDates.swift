// BranchTipDates.swift — the branch map's recency and root inputs (#0428,
// umbrella #0425)
//
// Guide §11 decision 29 filters the branch map by each branch tip's commit
// date and roots its tree at the default branch. This read names the
// default branch exactly as decision 27 does -- `origin/HEAD`'s target,
// else the literal `main`, from one `symbolic-ref`
// (`BranchStatus.defaultBranchName`) -- and reads every local and
// remote-tracking tip's committer date with one `for-each-ref`, never one
// process per branch. `refs/remotes/<remote>/HEAD` is skipped: for-each-ref
// lists that symref as if it were a branch (decision 27's measured caveat).

import Foundation

public enum BranchTipDates {

    public struct Report: Sendable, Equatable {
        /// The default branch's short name: `origin/HEAD`'s target, else
        /// `main`.
        public let defaultBranch: String
        /// Each tip's committer date in seconds since 1970, keyed by full ref
        /// name (`refs/heads/main`, `refs/remotes/origin/main`).
        public let dates: [String: Int]

        public init(defaultBranch: String, dates: [String: Int]) {
            self.defaultBranch = defaultBranch
            self.dates = dates
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A `for-each-ref` line did not parse.
        case malformedLine(_ line: String)

        public var description: String {
            switch self {
            case let .malformedLine(line):
                "Could not read a branch tip date from git's line: \(line)"
            }
        }
    }

    /// Tab-separated: ref names cannot contain ASCII control characters
    /// (git-check-ref-format).
    static let forEachRefArguments = [
        "for-each-ref", "--format=%(refname)\t%(committerdate:unix)", "refs/heads/", "refs/remotes/",
    ]

    /// One `symbolic-ref` and one `for-each-ref`.
    public static func read(at path: String, git: GitProcess = GitProcess()) async throws -> Report {
        let defaultBranch = try BranchStatus.defaultBranchName(
            fromSymbolicRef: await git.capture(["symbolic-ref", BranchStatus.originHEADRef], workingDirectory: path))
        let out = try await git.run(forEachRefArguments, workingDirectory: path)
        return Report(defaultBranch: defaultBranch, dates: try parse(out.text))
    }

    static func parse(_ text: String) throws -> [String: Int] {
        var dates: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, let seconds = Int(fields[1]) else {
                throw Error.malformedLine(String(line))
            }
            let ref = String(fields[0])
            if ref.hasPrefix("refs/remotes/"), ref.hasSuffix("/HEAD") { continue }
            dates[ref] = seconds
        }
        return dates
    }
}

/// Unparseable plumbing output is a repository-state failure -- guide §6
/// code 6, the same class as `BranchStatus.Error`.
extension BranchTipDates.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
