// ConformanceScan.swift — shared source scan behind the conformance-coverage
// guards (#0182; mechanism from #0181).
//
// Swift cannot enumerate a protocol's conformers at runtime, so coverage
// guards list conformers by scanning the sources — the `ServiceNamesTests`
// pattern — and compare the result against a runtime registry as sets in
// both directions. This type is the scan half, parameterised by protocol
// name so the next guard (#0183 asks the same question for `Equatable`)
// extends a call site instead of copying a scanner.
//
// It fails closed the same way #0181's embedded scanner does: exactly three
// line shapes are recognised — a comment, a declaration-site conformance,
// an extension-site conformance — plus the protocol's own declaration, and
// every other line naming the protocol is reported as unrecognized, so a
// conformance shape the scanner cannot parse turns a guard red rather than
// becoming a silently missed conformer.

import Foundation
import Testing

struct ConformanceScan {

    /// One conformance site. `file` is the source file's last path
    /// component; `name` is the type name exactly as the conformance line
    /// writes it — the local name for a declaration-site conformance (a line
    /// scan cannot see nesting), the possibly-qualified name for an
    /// extension-site one. The pair is the identity a registry row claims.
    struct Site: Hashable, Comparable {
        let file: String
        let name: String

        var label: String { "\(file):\(name)" }

        static func < (a: Site, b: Site) -> Bool {
            (a.file, a.name) < (b.file, b.name)
        }
    }

    struct Result {
        var declarationSites: Set<Site> = []
        var extensionSites: Set<Site> = []
        var protocolDeclarations = 0
        var unrecognized: [String] = []
        var duplicates: [String] = []

        var sites: Set<Site> { declarationSites.union(extensionSites) }
    }

    /// Scans every `.swift` file under `root` for lines naming
    /// `protocolName`, classifying each into `Result`.
    static func scan(for protocolName: String, under root: URL) throws -> Result {
        let escaped = NSRegularExpression.escapedPattern(for: protocolName)
        let typeName = "([A-Za-z_][A-Za-z0-9_.]*)"
        let declarationSite = try Regex(
            "^(?:public\\s+|package\\s+|final\\s+|indirect\\s+)*(?:enum|struct|class|actor)\\s+"
                + "\(typeName)(?:<[^>{]*>)?\\s*:[^{]*\\b\(escaped)\\b")
        let extensionSite = try Regex(
            "^(?:public\\s+)?extension\\s+\(typeName)\\s*:[^{]*\\b\(escaped)\\b")
        let protocolDeclaration = try Regex(
            "^(?:public\\s+)?protocol\\s+\(escaped)\\b")

        var result = Result()
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "cannot enumerate \(root.path)")
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains(protocolName) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if let match = try declarationSite.firstMatch(in: trimmed) {
                    insert(Site(file: url.lastPathComponent, name: String(match[1].substring ?? "")),
                           into: &result.declarationSites, duplicates: &result.duplicates)
                } else if let match = try extensionSite.firstMatch(in: trimmed) {
                    insert(Site(file: url.lastPathComponent, name: String(match[1].substring ?? "")),
                           into: &result.extensionSites, duplicates: &result.duplicates)
                } else if try protocolDeclaration.firstMatch(in: trimmed) != nil {
                    result.protocolDeclarations += 1
                } else {
                    result.unrecognized.append("\(url.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }
        return result
    }

    private static func insert(_ site: Site, into sites: inout Set<Site>,
                               duplicates: inout [String]) {
        if !sites.insert(site).inserted {
            duplicates.append(site.label)
        }
    }
}
