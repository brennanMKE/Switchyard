import Foundation
import YardKit

// MARK: - Status Entry

struct WorktreeStatusEntry {
    var path: String = ""
    var staged: State = .unmodified
    var worktree: State = .unmodified
}

extension WorktreeStatusEntry {
    enum State: String, CaseIterable {
        case unmodified = "."
        case added = "A"
        case deleted = "D"
        case modified = "M"
        case untracked = "?"
        case conflicted = "u"  // In git index (3-party), represents conflict
        
        init?(char: Character) {
            switch char {
            case ".": self = .unmodified
            case "A", "+": self = .added
            case "D", "-": self = .deleted
            case "M": self = .modified
            case "?": self = .untracked
            case "u", "!": self = .conflicted  // '!' is also used for conflicts in some contexts
            default: return nil
            }
        }
    }
}

// MARK: - Worktree Status

struct WorktreeStatus {
    let entries: [WorktreeStatusEntry]

    init(entries: [WorktreeStatusEntry]) {
        self.entries = entries
    }
}

extension WorktreeStatus: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: WorktreeStatusEntry...) {
        self.entries = elements
    }
}

// MARK: - Parser

class WorktreeStatusParser {
    var status: String? = nil
    var entries: [WorktreeStatusEntry] = []

    init() {}

    func parse(data: Data) throws -> WorktreeStatus {
        entries = []
        
        guard let stringData = String(data: data, encoding: .utf8) else {
            return WorktreeStatus(entries: [])
        }

        // Porcelain v2 format with -z uses NUL as record separator,
        // newlines within records are literal in paths (rare but possible)
        let rawRecords = stringData.split(separator: "\0").filter { !$0.isEmpty }
        
        for record in rawRecords {
            // Check for branch header: "## branch name" or "## (no branch)"
            if record.hasPrefix("## ") {
                let parts = record.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, parts[1] != "no branch." {
                    status = String(parts[1])
                }
            }
            
            // Parse file records - format: "<n> <status_codes> [<hashes>] <path>"
            // where n is 1 (two-party) or 2 (three-party for conflicts)
            guard record.hasPrefix("1 ") || record.hasPrefix("2 ") else { continue }
            
            // Split by whitespace, but we need to handle paths with spaces
            let parts = record.split(separator: " ", omittingEmptySubsequences: false)
            
            guard parts.count >= 2 else { continue }
            
            let recordType = parts[0]  // "1" or "2"
            let statusStr = String(parts[1])
            
            // Extract path - it's everything after the known status fields
            var filePath: String? = nil
            
            if recordType == "1" {
                // Two-party format: 1 <status> [<hash1> <hash2> <hash3>] <path>
                if parts.count == 2 {
                    // Just status and path: "1 XY <path>"
                    filePath = String(parts[2...].joined(separator: " "))
                } else if parts.count == 3 {
                    // Status and path (no hashes): "1 XY <path>"  
                    filePath = String(parts[2])
                } else if parts.count >= 5 {
                    // With optional hashes: "1 XY [<hash>] <path>" or "1 XY <hash> <hash> <hash> <path>"
                    // The path is everything after the status and optional hash fields
                    var pathParts = parts.dropFirst(2)
                    
                    // Skip up to 3 hash fields (40-char hex strings) if present
                    for _ in 0..<3 {
                        guard let first = pathParts.first,
                              first.count == 40,
                              first.allSatisfy({ $0.isHexDigit }) else { break }
                        pathParts = pathParts.dropFirst()
                    }
                    
                    filePath = String(pathParts.joined(separator: " "))
                } else {
                    // Skip ambiguous cases
                    continue
                }
                
            } else if recordType == "2" {
                // Three-party format: 2 <status> [<hash1> <hash2> <hash3>] [u] <path>
                // The 'u' indicates unmerged (conflict) state
                
                if parts.count >= 5 {
                    // With hashes and possibly 'u' flag
                    var pathParts = parts.dropFirst(2)
                    
                    // Skip up to 3 hash fields if present (they have 'u' or '-' in third column)
                    for _ in 0..<3 {
                        guard let first = pathParts.first,
                              (first.count == 40 || first.count < 10),
                              first.allSatisfy({ $0.isHexDigit || $0 == "u" || $0 == "-" }) else { break }
                        pathParts = pathParts.dropFirst()
                    }
                    
                    // Remove the 'u' flag if present (third column indicator for conflict)
                    var finalParts = pathParts.dropFirst() // Skip the path itself
                    if !finalParts.isEmpty, finalParts.first == "u" {
                        finalParts = finalParts.dropFirst()
                    }
                    
                    filePath = String(finalParts.joined(separator: " "))
                } else {
                    // Minimal format without all hashes
                    filePath = String(parts.dropFirst(2).joined(separator: " "))
                }
            }
            
            guard let path = filePath else { continue }
            
            var entry = WorktreeStatusEntry()
            
            // Parse staged state (first character of status code)
            if let firstChar = statusStr.first {
                entry.staged = WorktreeStatusEntry.State(char: firstChar) ?? .unmodified
                
            // Parse worktree state (second character of status code)
            } else if let secondChar = statusStr.dropFirst().first {
                entry.worktree = WorktreeStatusEntry.State(char: secondChar) ?? .unmodified
                
            // For two-party format (1 XY), both are in one code
                } else {
                // No status characters means unmodified for both (rare)
            }
            
            entry.path = path
            
            // Check if this is a conflict (3-party format with 'u' flag)
            let isThreeParty = record.hasPrefix("2 ")
            
            if isThreeParty {
                // In 3-party format, check for 'u' in the status area
                if record.contains(" u ") || record.contains(" u\t") {
                    // This indicates an unmerged file (conflict)
                    entry.staged = .conflicted
                } else if statusStr.first == "u" {
                    entry.staged = .conflicted
                } else if record.contains(" u ") {
                    entry.staged = .conflicted
                    // The worktree might still show modification
                }
            } else {
                // For two-party format, check if status is "??", "!?" or "?!" for untracked
                if statusStr == "??" {
                    entry.staged = .untracked
                    entry.worktree = .modified // untracked files are "present" in worktree
                
                } else if statusStr == "!?" || statusStr == "?!" {
                    // Conflicted file tracked in index but not in worktree or vice versa
                    entry.staged = .conflicted
                    entry.worktree = .modified
                }
            }
            
            entries.append(entry)
        }

        return WorktreeStatus(entries: entries)
    }
}

// MARK: - Helper extensions for String/Character
  
extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self.lowercased())
    }
}
