// TemplateReportWireTests.swift — WorktreeTemplate.Report encodes to the
// schemaVersion 1 envelope. Last contact for #0129 Decision 5: a PAYLOAD-FREE
// case inside an associated-value enum keeps the object frame — `.applied`
// encodes as `{"code":"applied"}`, no detail and no `message` (`Outcome`
// declares no `description`, so nothing owns that key).

import Foundation
import Testing
import YardGit
import YardKit

@Suite("WorktreeTemplate report wire shapes")
struct TemplateReportWireTests {

    // MARK: - Outcome, one literal per case (Decision 5)

    /// The payload-free case: same object frame as its siblings, `code` only.
    /// Not a bare string — Decision 5 forbids string-or-object unions within
    /// one enum — and no fabricated `message`.
    @Test func appliedEncodesAsACodeOnlyObject() throws {
        let json = try wireJSON(WorktreeTemplate.Report.Outcome.applied)
        #expect(json == #"{"code":"applied"}"#)
        #expect(!json.contains("message"))
    }

    /// The unlabeled payload rides under a declared wire name (#0134
    /// refinement 2): the string is the entry's repo-relative path -> `path`.
    @Test func missingSourceEncodesThePath() throws {
        #expect(try wireJSON(WorktreeTemplate.Report.Outcome.missingSource("cache/deps")) == #"{"code":"missingSource","path":"cache\/deps"}"#)
    }

    @Test func destinationExistsEncodesThePath() throws {
        #expect(try wireJSON(WorktreeTemplate.Report.Outcome.destinationExists(".env")) == #"{"code":"destinationExists","path":".env"}"#)
    }

    /// The labeled payloads keep their labels; no collision with `code`, so
    /// no wire rename is needed (contrast `WorktreeAddError.unknownFailure`).
    @Test func commandFailedEncodesExitCodeAndStderr() throws {
        #expect(try wireJSON(WorktreeTemplate.Report.Outcome.commandFailed(exitCode: 3, stderr: "oops\n")) == #"{"code":"commandFailed","exitCode":3,"stderr":"oops\n"}"#)
    }

    /// The filesystem error's rendering is failure detail, not a
    /// description-owned `message` -> declared wire name `detail`.
    @Test func failedEncodesTheDetail() throws {
        #expect(try wireJSON(WorktreeTemplate.Report.Outcome.failed("entry has no path")) == #"{"code":"failed","detail":"entry has no path"}"#)
    }

    // MARK: - Report and Entry

    /// A report embeds its entry and outcome; `Entry`'s nil `command` is
    /// OMITTED (#0129 Decision 4), `Action` encodes as its raw value, and the
    /// computed `succeeded` never appears (Decision 7).
    @Test func reportEmbedsEntryAndOutcome() throws {
        let report = WorktreeTemplate.Report(
            entry: .init(action: .copy, path: ".env"),
            outcome: .applied)
        let json = try wireJSON(report)
        #expect(json == #"{"entry":{"action":"copy","path":".env"},"outcome":{"code":"applied"}}"#)
        #expect(!json.contains("succeeded"))
        #expect(!json.contains("null"))
    }

    /// #0023's guarantee, extended to the wire: a REAL `apply` copies a file
    /// whose contents are a secret, and the encoded reports never carry those
    /// bytes. The `.applied` and on-disk asserts keep this non-vacuous — the
    /// copy demonstrably ran, so the secret was in reach.
    @Test func realApplyReportsEncodeWithoutFileContents() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wire-tpl-\(UUID().uuidString)")
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "SECRET=hunter2\n".write(
            to: source.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let template = WorktreeTemplate(entries: [.init(action: .copy, path: ".env")])
        let reports = template.apply(from: source.path, to: destination.path)
        #expect(reports.count == 1)
        #expect(reports.first?.outcome == .applied)
        #expect(fm.fileExists(atPath: destination.appendingPathComponent(".env").path))
        let json = try wireJSON(reports)
        #expect(json == #"[{"entry":{"action":"copy","path":".env"},"outcome":{"code":"applied"}}]"#)
        #expect(!json.contains("hunter2"))
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence: `apply(from:to:)` returns `[Report]`,
    /// which rides as a JSON array in `result`, byte-pinned with the v1 keys.
    @Test func envelopeWrapsTemplateReports() throws {
        let reports = [WorktreeTemplate.Report(
            entry: .init(action: .run, command: "npm install"),
            outcome: .commandFailed(exitCode: 3, stderr: "oops\n"))]
        let json = try wireJSON(Envelope(result: EncodableResult(reports)))
        #expect(json == #"{"ok":true,"result":[{"entry":{"action":"run","command":"npm install"},"outcome":{"code":"commandFailed","exitCode":3,"stderr":"oops\n"}}],"schemaVersion":1}"#)

        // Structural read-back, pinning the agent's branch path:
        // result[i].outcome.code.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let resultArray = try #require(object["result"] as? [[String: Any]])
        let outcome = try #require(resultArray.first?["outcome"] as? [String: Any])
        #expect(outcome["code"] as? String == "commandFailed")
        #expect(outcome["exitCode"] as? Int == 3)
    }
}
