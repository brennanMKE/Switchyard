// ReviewNotes.swift — review decisions as git notes (#0059)
//
// Trailers change the commit SHA; notes do not. That asymmetry is the whole
// design: agent provenance rides in trailers, written at commit time and
// covered by the signature (docs/provenance.md), while a review decision
// arrives AFTER the commit exists and must never invalidate it. So each
// decision is attached as a note under a dedicated namespace,
// `refs/notes/switchyard-review` — never `refs/notes/commits`, which git's
// default tooling owns. The namespace is excluded from the engine's ordinary
// ref enumeration (`RefSnapshot.capture`, `graphRows`) the way journal refs
// are, so attaching a decision is invisible to every other surface.
//
// **Where the JSON encoding happens.** `YardGit` cannot import `YardKit`
// (layering), and the decision type — `ReviewReply` — lives in `YardKit`. So
// this module deals in the note BODY as an opaque string: the caller that sees
// both types (the app-side review flow, `runReviewRequest` in `YardCommands`)
// encodes the reply to its JSON and hands the string here. The body stays
// machine-readable by convention — it is the `ReviewReply` JSON, `sortedKeys`,
// the same wire shape #0055 puts on the XPC reply — and any reader can decode
// it back into a `ReviewReply` without this module.
//
// **Byte fidelity, measured on git 2.50.1 (2026-09-04):** `git notes add`
// applies `stripspace` by default, which appends a trailing newline to the
// stored blob; `--no-stripspace` stores the bytes verbatim. `git notes show`
// prints the blob verbatim with nothing appended, and `-F -` reads the note
// from stdin, which keeps a large `editedPatch` off the argv size limit. So
// `record` writes through stdin with `--no-stripspace` and every read back is
// byte-identical to what the caller encoded — pinned by tests.

import Foundation

public enum ReviewNotes {

    /// The dedicated notes namespace for review decisions. Never
    /// `refs/notes/commits` — that namespace is git's own default and other
    /// tools' notes must neither be read as decisions nor shadowed by them.
    /// Excluded from `RefSnapshot.capture` and `graphRows`' `--all` traversal,
    /// and the only notes ref `CommitLog`'s `%N` field is fed from.
    public static let refNamespace = "refs/notes/switchyard-review"

    /// One attached decision: the annotated commit's oid and the note body —
    /// for this namespace, the `ReviewReply` JSON the decision flow wrote.
    public struct Note: Sendable, Equatable {
        /// The oid of the commit the note annotates.
        public let oid: String
        /// The note body, verbatim.
        public let body: String

        public init(oid: String, body: String) {
            self.oid = oid
            self.body = body
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A `git notes list` line did not parse. Thrown rather than skipped:
        /// silently dropping a note is silent data loss on the read side.
        case malformedNotesListLine(String)

        public var description: String {
            switch self {
            case let .malformedNotesListLine(line):
                "unparseable `git notes list` output line: \(line)"
            }
        }
    }

    // MARK: - Record

    /// Attaches `body` as the note for `commitOID` in the repository at
    /// `path`. Overwrites any existing note for that commit (`-f`): a
    /// re-review of the same commit replaces the recorded decision, latest
    /// wins. The body travels on stdin (`-F -`) so a large `editedPatch` never
    /// hits the argument-size limit, and `--no-stripspace` keeps the stored
    /// blob byte-identical to `body`.
    public static func record(
        body: String,
        forCommitOID commitOID: String,
        at path: String,
        git: GitProcess = GitProcess()
    ) throws {
        try git.run(
            ["notes", "--ref=\(refNamespace)", "add", "-f", "--no-stripspace", "-F", "-", commitOID],
            workingDirectory: path,
            standardInput: Data(body.utf8))
    }

    /// Async twin of `record(body:forCommitOID:at:git:)` (#0344).
    public static func record(
        body: String,
        forCommitOID commitOID: String,
        at path: String,
        git: GitProcess = GitProcess()
    ) async throws {
        try await git.run(
            ["notes", "--ref=\(refNamespace)", "add", "-f", "--no-stripspace", "-F", "-", commitOID],
            workingDirectory: path,
            standardInput: Data(body.utf8))
    }

    // MARK: - List

    /// Every note in the namespace, one `Note` per annotated object. Order
    /// follows `git notes list` (tree order) — match on `oid`, never position.
    public static func list(at path: String, git: GitProcess = GitProcess()) throws -> [Note] {
        let out = try git.run(["notes", "--ref=\(refNamespace)", "list"], workingDirectory: path)
        var notes: [Note] = []
        for line in out.lines {
            // `git notes list` prints `<note-blob-oid> <annotated-object-oid>`.
            // Refnames cannot contain space, so the two-field split is exact.
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedNotesListLine(line)
            }
            let oid = String(fields[1])
            notes.append(Note(oid: oid, body: try noteBody(forCommitOID: oid, at: path, git: git) ?? ""))
        }
        return notes
    }

    /// Async twin of `list(at:git:)` (#0344).
    public static func list(at path: String, git: GitProcess = GitProcess()) async throws -> [Note] {
        let out = try await git.run(["notes", "--ref=\(refNamespace)", "list"], workingDirectory: path)
        var notes: [Note] = []
        for line in out.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedNotesListLine(line)
            }
            let oid = String(fields[1])
            notes.append(Note(oid: oid, body: try await noteBody(forCommitOID: oid, at: path, git: git) ?? ""))
        }
        return notes
    }

    // MARK: - Read one

    /// The note body for `commitOID`, verbatim, or `nil` when the commit
    /// carries no note in this namespace. `git notes show` prints the blob
    /// verbatim (measured: nothing appended), so this is byte-identical to
    /// what `record` was given.
    public static func noteBody(
        forCommitOID commitOID: String,
        at path: String,
        git: GitProcess = GitProcess()
    ) throws -> String? {
        let out = try git.capture(
            ["notes", "--ref=\(refNamespace)", "show", commitOID], workingDirectory: path)
        if out.exitCode == 0 { return out.text }
        // Exit 1 with `no note found for object …` is absence — information,
        // not failure. Any other non-zero exit is a repository problem and
        // keeps its git-reported detail.
        if out.exitCode == 1 { return nil }
        throw GitProcess.Failure.exited(
            code: out.exitCode, stderr: out.standardError,
            arguments: ["notes", "--ref=\(refNamespace)", "show", commitOID])
    }

    /// Async twin of `noteBody(forCommitOID:at:git:)` (#0344).
    public static func noteBody(
        forCommitOID commitOID: String,
        at path: String,
        git: GitProcess = GitProcess()
    ) async throws -> String? {
        let out = try await git.capture(
            ["notes", "--ref=\(refNamespace)", "show", commitOID], workingDirectory: path)
        if out.exitCode == 0 { return out.text }
        if out.exitCode == 1 { return nil }
        throw GitProcess.Failure.exited(
            code: out.exitCode, stderr: out.standardError,
            arguments: ["notes", "--ref=\(refNamespace)", "show", commitOID])
    }
}

// MARK: - §6 exit class

extension ReviewNotes.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
