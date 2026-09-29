// SkillPluginTests.swift — the Claude Code plugin wrapping the skill (#0068)

import Foundation
import Testing
@testable import YardKit

/// The repository root, from this file's compile-time path.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // YardKitTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // YardKit (package root)
    .deletingLastPathComponent()   // repository root

private func jsonObject(at relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        "\(relativePath) must be a JSON object")
}

/// Guide §11 decision 31: the plugin root is `skills/switchyard/` itself, so
/// the plugin ships the one canonical SKILL.md and nothing else.
@Suite("Claude Code plugin")
struct SkillPluginTests {

    @Test("the marketplace lists one plugin whose source is the skill directory")
    func marketplacePointsAtTheSkillDirectory() throws {
        let marketplace = try jsonObject(at: ".claude-plugin/marketplace.json")
        #expect(marketplace["name"] as? String == ServiceNames.cliName)
        let owner = try #require(marketplace["owner"] as? [String: Any])
        #expect(!(owner["name"] as? String ?? "").isEmpty)
        let plugins = try #require(marketplace["plugins"] as? [[String: Any]])
        #expect(plugins.count == 1)
        #expect(plugins.first?["name"] as? String == ServiceNames.cliName)
        #expect(plugins.first?["source"] as? String == "./skills/switchyard")
    }

    @Test("the plugin manifest names the plugin and carries no version")
    func pluginManifestNamesThePlugin() throws {
        let manifest = try jsonObject(at: "skills/switchyard/.claude-plugin/plugin.json")
        #expect(manifest["name"] as? String == ServiceNames.cliName)
        // No version: Claude Code then versions a git-hosted plugin by commit
        // SHA, so every regenerated SKILL.md reaches installs without a bump.
        #expect(manifest["version"] == nil)
    }

    @Test("the plugin directory holds exactly SKILL.md and its manifest — no second copy")
    func pluginHoldsOnlyTheCanonicalSkill() throws {
        let fm = FileManager.default
        // Finder's .DS_Store is not content; everything else is.
        func entries(_ relativePath: String) throws -> [String] {
            try fm.contentsOfDirectory(atPath: repositoryRoot.appendingPathComponent(relativePath).path)
                .filter { $0 != ".DS_Store" }.sorted()
        }
        #expect(try entries("skills/switchyard") == [".claude-plugin", "SKILL.md"])
        #expect(try entries("skills/switchyard/.claude-plugin") == ["plugin.json"])
        #expect(try entries("skills") == [ServiceNames.cliName])
        #expect(try entries(".claude-plugin") == ["marketplace.json"])
    }
}
