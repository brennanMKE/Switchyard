// SigningConfig.swift

import Foundation

/// What git is configured to do about commit signing, read from the effective
/// configuration (system -> global -> local -> worktree) via `git config --get`.
/// Reporting only: nothing here signs or verifies anything (#0036, #0037).
///
/// Two independent questions, two independent fields:
/// - `willSign` — will a plain `git commit` produce a signed commit?
/// - `canVerifySSHSignatures` — can git report an SSH signature as *good*,
///   rather than merely present? Requires `gpg.ssh.allowedSignersFile`
///   (docs/engine-findings.md, #0002 findings).
public struct SigningConfig: Equatable, Sendable {

    public enum Format: Equatable, Sendable {
        case openpgp
        case ssh
        case x509
        /// A value git itself would reject at commit time. Reported, not
        /// validated — reporting is this type's whole job.
        case unrecognized(String)

        init(configValue: String) {
            switch configValue {
            case "openpgp": self = .openpgp
            case "ssh":     self = .ssh
            case "x509":    self = .x509
            default:        self = .unrecognized(configValue)
            }
        }
    }

    /// `commit.gpgsign`, normalized through `--type=bool`. `nil` means the key
    /// is unset in every scope. Git treats unset as "do not sign", but
    /// reporting `nil` as `false` would erase a distinction an agent needs:
    /// unset means "nobody decided", `false` means "someone decided no".
    public let commitSigningEnabled: Bool?

    /// `gpg.format`. `nil` means unset; git's default is then openpgp, but the
    /// default is git's to apply, not ours to bake in.
    public let format: Format?

    /// `user.signingKey`, verbatim as configured — no tilde expansion, no
    /// existence check. `nil` means unset.
    public let signingKey: String?

    /// `gpg.ssh.allowedSignersFile`, verbatim as configured. `nil` means unset.
    public let allowedSignersFile: String?

    /// Will a plain `git commit` produce a signed commit?
    public var willSign: Bool { commitSigningEnabled == true }

    /// Can git verify an SSH signature as good rather than merely present?
    public var canVerifySSHSignatures: Bool { allowedSignersFile != nil }

    public init(commitSigningEnabled: Bool?,
                format: Format?,
                signingKey: String?,
                allowedSignersFile: String?) {
        self.commitSigningEnabled = commitSigningEnabled
        self.format = format
        self.signingKey = signingKey
        self.allowedSignersFile = allowedSignersFile
    }

    /// Reads the effective signing configuration for the repository at
    /// `workingDirectory`.
    ///
    /// - Parameter extraEnvironment: merged over the process environment for
    ///   every `git config` invocation. Tests use it to neutralize global and
    ///   system scope; production callers leave it empty.
    public static func read(
        in workingDirectory: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> SigningConfig {
        let env = extraEnvironment

        // 1. commitSigningEnabled: --type=bool normalizes yes/1/on to true,
        //    no/0/off to false. Exit 128 (malformed) must throw, not read as nil.
        let commitArgs = ["config", "--type=bool", "--get", "commit.gpgsign"]
        let commitOutput = try git.capture(commitArgs, workingDirectory: workingDirectory, extraEnvironment: env)
        let commitSigningEnabled: Bool?
        switch commitOutput.exitCode {
        case 0:
            commitSigningEnabled = (commitOutput.lines.first == "true")
        case 1:
            commitSigningEnabled = nil
        default:
            throw GitProcess.Failure.exited(
                code: commitOutput.exitCode,
                stderr: commitOutput.standardError,
                arguments: commitArgs
            )
        }

        // 2. format — plain string match, no boolean parsing.
        let formatArgs = ["config", "--get", "gpg.format"]
        let formatOutput = try git.capture(formatArgs, workingDirectory: workingDirectory, extraEnvironment: env)
        let format: Format?
        switch formatOutput.exitCode {
        case 0:
            let raw = formatOutput.lines.first ?? ""
            format = Format(configValue: raw)
        case 1:
            format = nil
        default:
            throw GitProcess.Failure.exited(
                code: formatOutput.exitCode,
                stderr: formatOutput.standardError,
                arguments: formatArgs
            )
        }

        // 3. signingKey — raw string, no transformation.
        let keyArgs = ["config", "--get", "user.signingKey"]
        let keyOutput = try git.capture(keyArgs, workingDirectory: workingDirectory, extraEnvironment: env)
        let signingKey: String?
        switch keyOutput.exitCode {
        case 0:
            signingKey = keyOutput.lines.first ?? ""
        case 1:
            signingKey = nil
        default:
            throw GitProcess.Failure.exited(
                code: keyOutput.exitCode,
                stderr: keyOutput.standardError,
                arguments: keyArgs
            )
        }

        // 4. allowedSignersFile — case-sensitive subsection "ssh" (Given 4).
        let signerArgs = ["config", "--get", "gpg.ssh.allowedSignersFile"]
        let signerOutput = try git.capture(signerArgs, workingDirectory: workingDirectory, extraEnvironment: env)
        let allowedSignersFile: String?
        switch signerOutput.exitCode {
        case 0:
            allowedSignersFile = signerOutput.lines.first ?? ""
        case 1:
            allowedSignersFile = nil
        default:
            throw GitProcess.Failure.exited(
                code: signerOutput.exitCode,
                stderr: signerOutput.standardError,
                arguments: signerArgs
            )
        }

        return SigningConfig(
            commitSigningEnabled: commitSigningEnabled,
            format: format,
            signingKey: signingKey,
            allowedSignersFile: allowedSignersFile
        )
    }
}

// MARK: - Wire encoding (#0136)

/// `SigningConfig` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension SigningConfig: Encodable {
    /// Stable wire keys, identical to the stored-member names; no raw values.
    /// The computed `willSign` / `canVerifySSHSignatures` are not encoded
    /// (#0129 Decision 7). All four stored members are optional and every nil
    /// is omitted (#0129 Decision 4) — `commitSigningEnabled`'s absent state
    /// IS the "nobody decided" answer, so `{}` is the truthful wire for a
    /// fully unset configuration.
    private enum CodingKeys: String, CodingKey {
        case commitSigningEnabled, format, signingKey, allowedSignersFile
    }
}

/// `Format` is an associated-value enum (#0129 Decision 5): an object with a
/// stable `code` string on every case — a uniform frame (#0134 refinement 4) —
/// plus `value` (the raw config string, #0134 refinement 2) on `unrecognized`
/// only. Hand-written because SE-0295 synthesis COMPILES for this enum and
/// encodes `{"ssh":{}}`, so deleting this method is a silent wire change, not
/// a compile error.
extension SigningConfig.Format: Encodable {
    /// Wire keys: `code` on every case; `value` on `unrecognized`.
    private enum CodingKeys: String, CodingKey {
        case code, value
    }

    /// The stable wire vocabulary, one literal per case. Renaming a case is a
    /// compile error at this switch while the literal stays put;
    /// `SigningWireTests` pins all four.
    private var wireCode: String {
        switch self {
        case .openpgp: "openpgp"
        case .ssh: "ssh"
        case .x509: "x509"
        case .unrecognized: "unrecognized"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireCode, forKey: .code)
        if case let .unrecognized(value) = self {
            try container.encode(value, forKey: .value)
        }
    }
}
