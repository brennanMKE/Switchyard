// SigningWireTests.swift — SignatureVerification and SigningConfig encode to the
// schemaVersion 1 envelope (#0136). Two associated-value enums (#0129 Decision 5,
// #0134 refinements) and one declared case-name-string enum (#0133's clause).
//
// Every git-derived fixture value below is pasted from a real run (2026-08-07):
// crafted commits carrying structurally-valid-but-garbage signature blocks
// (`git hash-object --literally`, the #0019/#0127 technique — NO signing key was
// created or used), read back through the real `SignatureVerification.run` and
// `SigningConfig.read`, then encoded with `wireJSON` — the literals are that
// output. The one hand-built value (the `.good` verification) is marked where
// it appears: producing a real `G` requires a real key, which is forbidden.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("Signing wire shapes")
struct SigningWireTests {

    // MARK: - SignatureVerification.State (Decision 5, associated-value clause)

    /// The seven payload-free cases, one literal each: a uniform object frame
    /// carrying only `code` (#0134 refinement 4). The strings are declared in
    /// `encode(to:)`, not derived — and this vocabulary is deliberately NOT
    /// `SignatureStatus`'s (`noSignature` here vs `noSig` there). The array is
    /// explicit and its count is asserted so the loop cannot go vacuous.
    @Test func stateEncodesEveryPayloadFreeCaseAsACodeObject() throws {
        let vocabulary: [(SignatureVerification.State, String)] = [
            (.noSignature, #"{"code":"noSignature"}"#),
            (.good, #"{"code":"good"}"#),
            (.goodUntrusted, #"{"code":"goodUntrusted"}"#),
            (.bad, #"{"code":"bad"}"#),
            (.expiredSignature, #"{"code":"expiredSignature"}"#),
            (.expiredKey, #"{"code":"expiredKey"}"#),
            (.revokedKey, #"{"code":"revokedKey"}"#),
        ]
        #expect(vocabulary.count == 7)
        for (state, expected) in vocabulary {
            #expect(try wireJSON(state) == expected)
        }
    }

    // MARK: - SignatureVerification.Format (Decision 5, middle clause)

    /// The whole declared vocabulary, one literal per case — a single JSON
    /// string, exactly the case name, written by the explicit `encode(to:)`.
    /// SE-0295 synthesis would emit `{"ssh":{}}` instead (#0133).
    @Test func formatEncodesEveryCaseAsItsDeclaredString() throws {
        let vocabulary: [(SignatureVerification.Format, String)] = [
            (.ssh, #""ssh""#),
            (.openpgp, #""openpgp""#),
            (.x509, #""x509""#),
            (.none, #""none""#),
            (.unrecognized, #""unrecognized""#),
        ]
        #expect(vocabulary.count == 5)
        for (format, expected) in vocabulary {
            #expect(try wireJSON(format) == expected)
        }
    }

    // MARK: - SignatureVerification

    /// The crafted-bad-SSH result, exactly as the real run returned it: a
    /// garbage SSH signature block against an empty allowed_signers gives
    /// `%G?` = `B` with nothing on `%GS`/`%GK`, so `signer` and `key` are nil
    /// and OMITTED from the wire, never `null` (#0129 Decision 4).
    @Test func craftedBadSSHVerificationEncodesToTheLiteralWireShape() throws {
        let value = SignatureVerification(
            state: .bad, format: .ssh, signer: nil, key: nil)
        let json = try wireJSON(value)
        #expect(json == #"{"format":"ssh","state":{"code":"bad"}}"#)
        #expect(!json.contains("\"signer\""))
        #expect(!json.contains("\"key\""))
        #expect(!json.contains("null"))
    }

    /// Every field populated. HAND-BUILT, the one non-run fixture in this
    /// file: a real `G` requires a real signing key, which this project never
    /// creates — the signer/key strings are the shapes git documents for
    /// `%GS`/`%GK` (and `emptySignerAndKeyBecomeNil` in `YardGitTests` feeds
    /// the same shapes through `parse`).
    @Test func fullyPopulatedVerificationEncodesToTheLiteralWireShape() throws {
        let value = SignatureVerification(
            state: .good,
            format: .ssh,
            signer: "Fixture <fixture@example.invalid>",
            key: "SHA256:abc")
        #expect(try wireJSON(value) == #"{"format":"ssh","key":"SHA256:abc","signer":"Fixture <fixture@example.invalid>","state":{"code":"good"}}"#)
    }

    /// The `cannotCheck` reason rides verbatim under `reason`, next to the
    /// stable `code` — the whole value is the real run's result for a crafted
    /// SSH-signed commit with no `gpg.ssh.allowedSignersFile` configured.
    /// The reason is git's trimmed stderr: config prose and (in other
    /// variants) absolute tool paths — established wire content, never file
    /// contents or key material.
    @Test func cannotCheckVerificationCarriesTheRealReason() throws {
        let value = SignatureVerification(
            state: .cannotCheck(reason: "error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification"),
            format: .ssh,
            signer: nil,
            key: nil)
        #expect(try wireJSON(value) == #"{"format":"ssh","state":{"code":"cannotCheck","reason":"error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification"}}"#)
    }

    // MARK: - SigningConfig

    /// Every field populated — the real `SigningConfig.read` output for a
    /// fixture configured `commit.gpgsign=true`, `gpg.format=ssh`, a tilde
    /// signing key, and an allowed-signers path. The computed `willSign` /
    /// `canVerifySSHSignatures` never appear (#0129 Decision 7), and the
    /// nested `format` rides as a `code` object.
    @Test func signingConfigFullValueEncodesToTheLiteralWireShape() throws {
        let value = SigningConfig(
            commitSigningEnabled: true,
            format: .ssh,
            signingKey: "~/.ssh/id_ed25519.pub",
            allowedSignersFile: "/path/to/allowed-signers")
        let json = try wireJSON(value)
        #expect(json == #"{"allowedSignersFile":"\/path\/to\/allowed-signers","commitSigningEnabled":true,"format":{"code":"ssh"},"signingKey":"~\/.ssh\/id_ed25519.pub"}"#)
        #expect(!json.contains("willSign"))
        #expect(!json.contains("canVerifySSHSignatures"))
    }

    /// The type's whole point, pinned: `false` means "someone decided no" and
    /// rides as `false`; nil means "nobody decided" and is ABSENT — `{}` is
    /// the truthful wire for a fully unset configuration, never `null`s.
    /// (The third state, `true`, is pinned by the full-value literal above.)
    /// Both values are the real `read` output — the false one is a fresh
    /// fixture's preset, the empty one the same fixture after
    /// `git config --unset commit.gpgsign`.
    @Test func signingConfigPinsFalseVersusAbsent() throws {
        let decidedNo = SigningConfig(
            commitSigningEnabled: false,
            format: nil, signingKey: nil, allowedSignersFile: nil)
        #expect(try wireJSON(decidedNo) == #"{"commitSigningEnabled":false}"#)

        let nobodyDecided = SigningConfig(
            commitSigningEnabled: nil,
            format: nil, signingKey: nil, allowedSignersFile: nil)
        let json = try wireJSON(nobodyDecided)
        #expect(json == "{}")
        #expect(!json.contains("null"))
    }

    /// `SigningConfig.Format`'s whole vocabulary: three payload-free cases as
    /// bare `code` objects, and `unrecognized` carrying the raw config string
    /// under `value` (#0134 refinement 2 — declared wire name). The `"gost"`
    /// value is from a real run: `git config gpg.format gost`, read back as
    /// `.unrecognized("gost")`. The array count is asserted so the loop
    /// cannot go vacuous.
    @Test func signingConfigFormatEncodesEveryCaseAsACodeObject() throws {
        let vocabulary: [(SigningConfig.Format, String)] = [
            (.openpgp, #"{"code":"openpgp"}"#),
            (.ssh, #"{"code":"ssh"}"#),
            (.x509, #"{"code":"x509"}"#),
            (.unrecognized("gost"), #"{"code":"unrecognized","value":"gost"}"#),
        ]
        #expect(vocabulary.count == 4)
        for (format, expected) in vocabulary {
            #expect(try wireJSON(format) == expected)
        }
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence: the engine result type encodes to a
    /// `schemaVersion: 1` envelope — the compile itself proves the
    /// `Encodable & Sendable` bound, and the literal pins the whole response
    /// for the crafted-bad-SSH verification.
    @Test func envelopeWrapsAVerificationWithTheV1Keys() throws {
        let value = SignatureVerification(
            state: .bad, format: .ssh, signer: nil, key: nil)
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"format":"ssh","state":{"code":"bad"}},"schemaVersion":1}"#)

        // Structural read-back, so a failure here distinguishes "envelope
        // broke" from "payload byte drift" — and pins the agent's branch
        // path: result.state.code.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let resultObject = try #require(object["result"] as? [String: Any])
        let stateObject = try #require(resultObject["state"] as? [String: Any])
        #expect(stateObject["code"] as? String == "bad")
    }
}
