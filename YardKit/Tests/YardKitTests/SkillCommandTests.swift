// SkillCommandTests.swift — `switchyard skill` (#0067)

import Foundation
import Testing
@testable import YardKit

/// `skills/switchyard/SKILL.md`, resolved the way `SkillGoldenTests` does.
private let committedSkill = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // YardKitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // YardKit (package root)
    .deletingLastPathComponent()   // repository root
    .appendingPathComponent("skills/switchyard/SKILL.md")

@Suite("switchyard skill")
struct SkillCommandTests {

    @Test("skill prints the committed SKILL.md byte for byte and exits 0")
    func skillPrintsTheCommittedFile() throws {
        let result = runYard(arguments: ["skill"])
        let committed = try String(contentsOf: committedSkill, encoding: .utf8)
        #expect(result.exitCode == .success)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout == committed)
    }

    @Test("skill --json prints the same markdown: the global flag changes nothing")
    func jsonFlagChangesNothing() {
        #expect(runYard(arguments: ["skill", "--json"]).stdout == runYard(arguments: ["skill"]).stdout)
    }

    @Test("skill with an argument is a usage error")
    func extraArgumentIsUsage() throws {
        let result = runYard(arguments: ["skill", "extra"])
        #expect(result.exitCode == .usage)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
    }

    @Test("skill is answered locally, never routed to the app")
    func skillIsLocal() {
        #expect(route(["skill"]) == .local)
    }
}
