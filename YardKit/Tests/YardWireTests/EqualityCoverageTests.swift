// EqualityCoverageTests.swift — every hand-written `static func ==` compares
// every one of its type's stored members (#0316).
//
// #0312's finding is the reason this file exists: `WorktreeEntry.==`
// (WorktreeList.swift) omitted `prunableReason`, and no mutation was needed
// to expose it — the suite was green around the omission because nothing
// compared the operator's body against the type's own member list. #0312
// fixed the operator; this guard is what keeps that class of omission from
// recurring, here or on any future hand-written `==`.
// This guard makes that comparison mechanical: a source scan finds every
// hand-written `==`, extracts the members it actually compares, extracts the
// type's own stored members from its declaration, and fails when the first
// set is not a superset of the second.
//
// Deliberately NOT built on `ConformanceScan`: that scanner classifies one
// line at a time (a conformance clause is always exactly one line), which is
// the right shape for "does this protocol have a conformance site here?".
// This guard has to answer a different question — "does this type
// declaration's *body* contain a stored member the operator's *body* never
// touches?" — which needs brace-depth tracking across a range of lines, not
// single-line classification. Bolting that onto `ConformanceScan` would
// change the shape the other two guards depend on for a need only this one
// has, which is exactly the "second, differently-shaped scanner" the issue
// warns against — except here the second shape is unavoidable, so it is
// kept small, self-contained, and in this file rather than merged in.
//
// This target imports YardGit WITHOUT `@testable` on purpose, matching
// `ExitClassCoverageTests`/`DescriptionCoverageTests` (#0116 failure class).
// This guard needs no runtime construction at all, though — both sides of
// the comparison come from source text, not from constructed values — so it
// does not import YardGit.

import Foundation
import Testing

/// Pairs a hand-written `static func ==` with its type's own stored member
/// list, restricted to `YardKit/Sources/YardGit`. Scoped to `struct`/`class`
/// declarations only (every current conformer is a `struct`); an `actor` or
/// an `enum` with associated values adopting hand-written `Equatable` would
/// need the same treatment if one appears, and this scanner's `unrecognized`-
/// style failure mode is instead a silent zero-member match today (see
/// `everyHandWrittenEqualityCoversItsStoredMembers`'s non-empty-members
/// `#require`, which turns that specific failure into a loud one for the
/// files this scan actually reaches).
enum EqualityScan {

    struct Conformer {
        let file: String
        let typeName: String
        let storedMembers: [String]
        let comparedMembers: Set<String>
    }

    private struct OpenType {
        let name: String
        let bodyDepth: Int
        var members: [String] = []
    }

    static func scan(under root: URL) throws -> [Conformer] {
        var conformers: [Conformer] = []
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "cannot enumerate \(root.path)")
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            conformers.append(contentsOf: try scanFile(url))
        }
        return conformers
    }

    private static func scanFile(_ url: URL) throws -> [Conformer] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let typeDeclPattern = try Regex(
            #"^(?:public\s+|internal\s+|final\s+|package\s+)*(?:struct|class)\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let memberDeclPattern = try Regex(
            #"^(?:public\s+|internal\s+|package\s+)*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:"#)
        let staticPrefixPattern = try Regex(#"^(?:public\s+)?static\s"#)
        let equalityPattern = try Regex(
            #"^(?:public\s+)?static\s+func\s*==\s*\(\s*lhs:\s*([A-Za-z_][A-Za-z0-9_.]*)\s*,\s*rhs:"#)
        let memberRefPattern = try Regex(#"\b(?:lhs|rhs)\.([A-Za-z_][A-Za-z0-9_]*)"#)

        var depth = 0
        var typeStack: [OpenType] = []
        var completedMembers: [String: [String]] = [:]
        var equalitySites: [(typeName: String, startLine: Int)] = []

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                // Comment lines carry no braces worth counting and are never a
                // declaration site, so they fall straight through.
            } else if let match = try typeDeclPattern.firstMatch(in: trimmed), trimmed.contains("{") {
                let name = String(match[1].substring ?? "")
                typeStack.append(OpenType(name: name, bodyDepth: depth + 1))
            } else if let top = typeStack.last, depth == top.bodyDepth,
                      trimmed.range(of: "(") == nil,
                      trimmed.range(of: "{") == nil,
                      (try? staticPrefixPattern.firstMatch(in: trimmed)) == nil,
                      let match = try memberDeclPattern.firstMatch(in: trimmed) {
                // A direct (non-nested), non-static, non-computed stored
                // member of the innermost currently open type: `let`/`var`
                // with no trailing `{` (a computed property or closure) and
                // no `(` (a tuple-typed declaration or a function/init this
                // pattern should never match, kept as a second guard).
                let name = String(match[1].substring ?? "")
                typeStack[typeStack.count - 1].members.append(name)
            } else if let match = try equalityPattern.firstMatch(in: trimmed) {
                let typeName = String(match[1].substring ?? "")
                equalitySites.append((typeName: typeName, startLine: index))
            }

            for ch in rawLine {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    while let top = typeStack.last, depth < top.bodyDepth {
                        let closed = typeStack.removeLast()
                        completedMembers[closed.name] = closed.members
                    }
                }
            }
        }

        var conformers: [Conformer] = []
        for site in equalitySites {
            var funcDepth = 0
            var started = false
            var bodyLines: [String] = []
            for line in lines[site.startLine...] {
                for ch in line {
                    if ch == "{" {
                        funcDepth += 1
                        started = true
                    } else if ch == "}" {
                        funcDepth -= 1
                    }
                }
                bodyLines.append(line)
                if started && funcDepth == 0 { break }
            }
            let body = bodyLines.joined(separator: "\n")
            var compared: Set<String> = []
            for match in body.matches(of: memberRefPattern) {
                compared.insert(String(match[1].substring ?? ""))
            }
            conformers.append(Conformer(
                file: url.lastPathComponent,
                typeName: site.typeName,
                storedMembers: completedMembers[site.typeName] ?? [],
                comparedMembers: compared))
        }
        return conformers
    }
}

@Suite("§ equality-conformance coverage")
struct EqualityCoverageTests {

    /// Locates the repository root from this file, so the tests work
    /// wherever the package is checked out — under `swift test` and under
    /// Xcode alike, matching `ExitClassCoverageTests.repoRoot`.
    private var engineRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardWireTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("YardKit/Sources/YardGit")
    }

    /// Deliberate omissions: type name → the recorded reason, which must
    /// cite an issue number. Adding an entry here is a decision, not a
    /// default — a hand-written `==` belongs in full coverage unless an
    /// issue says why it cannot be, matching the convention
    /// `ExitClassCoverageTests`/`DescriptionCoverageTests` already use.
    ///
    /// `WorktreeEntry` no longer needs an entry: #0312 added
    /// `prunableReason` to its `==`, so it now compares every stored member
    /// and passes `everyHandWrittenEqualityCoversItsStoredMembers` on its
    /// own — the exemption that used to live here has nothing left to
    /// excuse (`everyAllowListedTypeStillOmitsAStoredMember` would have
    /// failed the moment the fix landed if the entry had stayed).
    ///
    /// Empty is the goal state, not an error — the day this list has no
    /// entries is the day every hand-written `==` in the engine covers its
    /// own type completely. That day is today. None of the three tests
    /// below require it to be non-empty.
    private let allowList: [String: String] = [:]

    /// #0316's headline: every hand-written `==` compares every one of its
    /// type's stored members, or has an allow-list entry that says why not.
    @Test func everyHandWrittenEqualityCoversItsStoredMembers() throws {
        let conformers = try EqualityScan.scan(under: engineRoot)
        try #require(
            !conformers.isEmpty,
            "the scan found no hand-written `static func ==` at all — the scanner or its path is broken")

        for conformer in conformers {
            try #require(
                !conformer.storedMembers.isEmpty,
                """
                \(conformer.typeName) (\(conformer.file)): the scan found its \
                `==` but no stored members at all — the type-body scan did not \
                locate this type's declaration, or it genuinely has none, \
                either of which needs a human to look
                """)

            if allowList[conformer.typeName] != nil {
                continue
            }

            let missing = Set(conformer.storedMembers).subtracting(conformer.comparedMembers)
            #expect(
                missing.isEmpty,
                """
                \(conformer.typeName).== (\(conformer.file)) omits stored member(s): \
                \(missing.sorted().joined(separator: ", ")). Add them to the \
                comparison, or add an allow-list entry in \
                EqualityCoverageTests.swift citing an issue.
                """)
        }
    }

    /// The allow-list is honest in one direction: every entry cites an
    /// issue, and every entry still names a conformer the scan actually
    /// finds — a type renamed, removed, or no longer hand-written (i.e. now
    /// synthesized) drops out of the scan, and a stale entry here would
    /// silently exempt nothing. Deliberately does NOT require `allowList`
    /// to be non-empty: an empty list is the success state (see the doc
    /// comment on `allowList`), and a test that fails on that state is one
    /// whoever hits it will delete rather than honor. Whether an entry is
    /// still *earning* its place — as opposed to merely still existing — is
    /// `everyAllowListedTypeStillOmitsAStoredMember`'s job, not this one's.
    @Test func allowListEntriesRequireAnIssueCitationAndARealConformer() throws {
        for (name, reason) in allowList {
            #expect(reason.contains("#"), "\(name) allow-list entry must cite an issue: \(reason)")
        }

        let conformers = try EqualityScan.scan(under: engineRoot)
        let names = Set(conformers.map(\.typeName))
        let stale = Set(allowList.keys).subtracting(names)
        #expect(
            stale.isEmpty,
            """
            allow-list entries with no matching == conformer (type renamed, \
            removed, no longer hand-written, or the scanner broke): \
            \(stale.sorted().joined(separator: ", "))
            """)
    }

    /// Makes the allow-list self-expiring. Round 1 shipped an exemption
    /// mechanism that only checked an entry still *points at* a real `==`
    /// (`allowListEntriesRequireAnIssueCitationAndARealConformer` above) —
    /// which stays green even after the underlying omission is fixed,
    /// because a completed `==` is still a hand-written `==` the scan
    /// finds. Verified directly: adding `prunableReason` to
    /// `WorktreeEntry.==` and rerunning left the suite green, which is the
    /// defect this test closes. Every allow-listed type must still fail the
    /// coverage check `everyHandWrittenEqualityCoversItsStoredMembers`
    /// would otherwise apply to it — the moment it stops failing, its
    /// exemption has nothing left to excuse.
    @Test func everyAllowListedTypeStillOmitsAStoredMember() throws {
        guard !allowList.isEmpty else { return }   // nothing to check — see the doc comment on `allowList`

        let conformers = try EqualityScan.scan(under: engineRoot)
        let byName = Dictionary(uniqueKeysWithValues: conformers.map { ($0.typeName, $0) })

        for name in allowList.keys {
            let conformer = try #require(
                byName[name],
                """
                \(name) is allow-listed but the scan found no == for it at all \
                — see allowListEntriesRequireAnIssueCitationAndARealConformer
                """)
            let missing = Set(conformer.storedMembers).subtracting(conformer.comparedMembers)
            #expect(
                !missing.isEmpty,
                """
                \(name)'s == now compares every stored member — its allow-list \
                entry in EqualityCoverageTests.swift is stale and should be \
                removed, which lets everyHandWrittenEqualityCoversItsStoredMembers \
                start enforcing full coverage on it automatically.
                """)
        }
    }
}
