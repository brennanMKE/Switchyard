// SignatureVerification.swift — typed result of asking git to verify one commit's signature

import Foundation

/// The outcome of verifying one commit's signature, read from
/// `git log -1 --format=%G?%x01%GS%x01%GK <revision> --` plus the commit's raw
/// `gpgsig` header (for format detection, via `git cat-file commit`).
///
/// Three-valued by design (docs/engine-findings.md, #0002): "no signature",
/// "signature present but git cannot check it", and the checked states are all
/// distinct. `%G?` alone cannot express that — it prints `N` both for an
/// unsigned commit and for a signature git could not check (missing
/// gpg.ssh.allowedSignersFile, missing gpg binary) — so `parse` reads stderr
/// too. Reporting only: nothing here signs anything or creates keys.
public struct SignatureVerification: Equatable, Sendable {

    /// Verification state, mapped from git's `%G?` flag plus stderr.
    public enum State: Equatable, Sendable {
        /// `%G?` = `N` with empty stderr: the commit carries no signature.
        case noSignature
        /// `%G?` = `G`: good, trusted signature.
        case good
        /// `%G?` = `U`: good signature, but the key's trust is unknown.
        case goodUntrusted
        /// `%G?` = `B`: bad signature.
        case bad
        /// `%G?` = `X`: good signature that has expired.
        case expiredSignature
        /// `%G?` = `Y`: good signature made by an expired key.
        case expiredKey
        /// `%G?` = `R`: good signature made by a revoked key.
        case revokedKey
        /// `%G?` = `E`, or `N` with a non-empty stderr, or an unrecognized
        /// flag: the signature could not be checked. `reason` is git's stderr
        /// (trimmed), or a fixed fallback when stderr is empty.
        case cannotCheck(reason: String)
    }

    /// Signature format, detected from the raw commit object's signature
    /// header (`gpgsig` or `gpgsig-sha256`), not from config — a repository
    /// can contain commits signed under a different configuration than its
    /// current one.
    public enum Format: Equatable, Sendable {
        /// `-----BEGIN SSH SIGNATURE-----`
        case ssh
        /// `-----BEGIN PGP SIGNATURE-----` (or `PGP MESSAGE`)
        case openpgp
        /// `-----BEGIN SIGNED MESSAGE-----` (gpgsm / X.509)
        case x509
        /// No signature header on the commit at all.
        case none
        /// A signature header whose armor matches none of the above.
        case unrecognized
    }

    public let state: State
    public let format: Format
    /// `%GS` — signer identity as git reports it. `nil` when git printed nothing.
    public let signer: String?
    /// `%GK` — the key git used. `nil` when git printed nothing.
    public let key: String?

    public init(state: State, format: Format, signer: String?, key: String?) {
        self.state = state
        self.format = format
        self.signer = signer
        self.key = key
    }

    /// Verifies the signature on `revision` in the repository at
    /// `workingDirectory`.
    ///
    /// Two git invocations, both through `GitProcess.run` so a bad revision or
    /// missing repository propagates as `GitProcess.Failure`:
    ///
    /// 1. `git log -1 --format=%G?%x01%GS%x01%GK <revision> --` — flag, signer,
    ///    key on stdout (exit 0 even when checking fails); the *why* on stderr.
    /// 2. `git cat-file commit <revision>` — raw object, for format detection.
    ///
    /// - Parameter extraEnvironment: merged over the process environment for
    ///   both invocations. Tests use it to neutralize global and system config
    ///   scope; production callers leave it empty.
    public static func run(
        revision: String,
        in workingDirectory: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> SignatureVerification {
        let logOutput = try git.run(
            ["log", "-1", "--format=%G?\u{01}%GS\u{01}%GK", revision, "--"],
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment
        )
        let fields = (logOutput.lines.first ?? "")
            .split(separator: "\u{01}", omittingEmptySubsequences: false)
            .map(String.init)
        let rawCommit = try git.run(
            ["cat-file", "commit", revision],
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment
        )
        return parse(
            flag: fields.count > 0 ? fields[0] : "",
            signer: fields.count > 1 ? fields[1] : "",
            key: fields.count > 2 ? fields[2] : "",
            stderr: logOutput.standardError,
            format: detectFormat(rawCommit: rawCommit.text)
        )
    }

    /// Pure mapping from git's outputs to a result. Exposed internally so the
    /// states that cannot be produced without a real signing key (`G`, `U`,
    /// `X`, `Y`, `R`, `E`) are still unit-tested.
    static func parse(
        flag: String,
        signer: String,
        key: String,
        stderr: String,
        format: Format
    ) -> SignatureVerification {
        let reason = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: State
        switch flag {
        case "G": state = .good
        case "U": state = .goodUntrusted
        case "B": state = .bad
        case "X": state = .expiredSignature
        case "Y": state = .expiredKey
        case "R": state = .revokedKey
        case "E": state = .cannotCheck(reason: reason.isEmpty ? "signature cannot be checked" : reason)
        case "N": state = reason.isEmpty ? .noSignature : .cannotCheck(reason: reason)
        default:  state = .cannotCheck(reason: "unrecognized %G? flag \"\(flag)\"")
        }
        return SignatureVerification(
            state: state,
            format: format,
            signer: signer.isEmpty ? nil : signer,
            key: key.isEmpty ? nil : key
        )
    }

    /// Detects the signature format from a raw commit object (the text output
    /// of `git cat-file commit`). Looks only inside the header block — the
    /// text before the first blank line — so a message body that *mentions*
    /// `gpgsig` cannot confuse it. Recognizes both `gpgsig` and
    /// `gpgsig-sha256` header names. The armor label decides the format, per
    /// the measurement that git stores SSH and PGP signatures under the same
    /// `gpgsig` header.
    static func detectFormat(rawCommit: String) -> Format {
        let header = rawCommit.components(separatedBy: "\n\n").first ?? rawCommit
        let lines = header.split(separator: "\n", omittingEmptySubsequences: false)
        var signatureLines: [Substring] = []
        var inSignature = false
        for line in lines {
            if line.hasPrefix("gpgsig ") || line.hasPrefix("gpgsig-sha256 ") {
                inSignature = true
                signatureLines.append(line)
            } else if inSignature, line.hasPrefix(" ") {
                // Header continuation lines start with a single space.
                signatureLines.append(line)
            } else {
                inSignature = false
            }
        }
        guard !signatureLines.isEmpty else { return .none }
        let signature = signatureLines.joined(separator: "\n")
        if signature.contains("BEGIN SSH SIGNATURE") { return .ssh }
        if signature.contains("BEGIN PGP SIGNATURE") || signature.contains("BEGIN PGP MESSAGE") {
            return .openpgp
        }
        if signature.contains("BEGIN SIGNED MESSAGE") { return .x509 }
        return .unrecognized
    }
}
