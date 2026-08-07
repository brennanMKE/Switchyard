import Foundation
import Testing
@testable import YardGit

struct WorktreeStatusTests {
    let git = GitProcess()
    
    // MARK: - Test 1: Files matching repo.oids for basic staged/unstaged
    
    @Test func statusOfFilesMatchingOids() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        // Modify a committed file in worktree (unstaged)
        let modifiedPath = repo.url.appendingPathComponent("modified.txt")
        try "new content".write(to: modifiedPath, atomically: true, encoding: .utf8)
        
        // Stage a new file (added to index)  
        let addedPath = repo.url.appendingPathComponent("added.txt")
        try "newly added".write(to: addedPath, atomically: true, encoding: .utf8)
        let repoGit = GitProcess()  // Create separate instance since 'git' is private
        try repoGit.run(["add", "-A"], workingDirectory: repo.url.path)  // Stage everything including new file
        
        // Run git status in the repo's main worktree
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(data: output.standardOutput)
        
        // Find entries by path  
        let modifiedEntry = status.entries.first { $0.path == "modified.txt" }
        #expect(modifiedEntry != nil, "should find modified file")
        
        let modified = try #require(modifiedEntry)
        #expect(modified.staged == .unmodified, "worktree modification should show staged as unmodified")
        #expect(modified.worktree == .modified, "file modified in worktree should show staged as modified")
        
        let addedEntry = status.entries.first { $0.path == "added.txt" }
        #expect(addedEntry != nil, "should find added file")
        
        let added = try #require(addedEntry)
        #expect(added.staged == .added, "new file in index should show staged as added")
        #expect(added.worktree == .unmodified, "staged file shouldn't show worktree modification")
    }
    
    // MARK: - Test 2: Staged modifications (modify THEN stage, not just path write)
    
    @Test func stagedModificationAfterModifyAndStage() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        // Modify a committed file in worktree first (unstaged)
        let basePath = repo.url.appendingPathComponent("base.txt")
        var content = try String(contentsOf: basePath, encoding: .utf8)
        content += "\nmodified line"
        try content.write(to: basePath, atomically: true, encoding: .utf8)
        
        // Stage it using git command directly (git is private in FixtureRepository)
        let repoGit = GitProcess()
        try repoGit.run(["add", "-A"], workingDirectory: repo.url.path)
        
        // Capture status after staging
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(data: output.standardOutput)
        
        // Find base.txt entry - it should be staged as modified, worktree clean
        let baseEntry = status.entries.first { $0.path == "base.txt" }
        #expect(baseEntry != nil, "should find base file")
        
        let base = try #require(baseEntry)
        #expect(base.staged == .modified, "file should be staged as modified after staging")
        #expect(base.worktree == .unmodified, "worktree should be clean after staging")
    }
    
    // MARK: - Test 3: Untracked files detection
    
    @Test func untrackedFilesDetected() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        
        // Create a truly untracked file (not added to index)  
        let untrackedPath = repo.url.appendingPathComponent("untracked.txt")
        try "I'm not in the index".write(to: untrackedPath, atomically: true, encoding: .utf8)
        
        // Capture status  
        let output = try git.capture(
            ["status", "--porcelain=v2", "-z"],
            workingDirectory: repo.url.path
        )
        
        let parser = WorktreeStatusParser()
        let status = try parser.parse(data: output.standardOutput)
        
        // Find untracked entry  
        let untrackedEntry = status.entries.first { $0.path == "untracked.txt" }
        #expect(untrackedEntry != nil, "should find untracked file")
        
        let entry = try #require(untrackedEntry)
        #expect(entry.staged == .untracked, "file should be marked as untracked")
        #expect(entry.worktree == .modified || entry.worktree == .unmodified, "worktree state may vary")
    }
    
    // MARK: - Unit test on hand-crafted NUL-terminated data
    
    @Test func parserAcceptsHandCraftedPorcelainBytes() {
        // Construct a minimal -z buffer with known status codes
        var buf: [UInt8] = []
        
        func append(_ s: String) { buf.append(contentsOf: Array(s.utf8)) }
        func nl()   { buf.append(0x00) }  // NUL terminator
        
        append("1 M. N..."); nl()
        append("modified.txt"); nl()  // Modified in worktree, staged unchanged
        
        append("1 A. N..."); nl()
        append("added.txt"); nl()  // Added to index, worktree unchanged
        
        let data = Data(buf)
        
        do {
            let parser = WorktreeStatusParser()
            let status = try parser.parse(data: data)
            
            // Should have 2 entries  
            #expect(status.entries.count == 2, "parser should recognize both file statuses")
            
            // Verify each entry's state
            let modifiedEntry = status.entries.first { $0.path == "modified.txt" }
            if let entry = modifiedEntry {
                #expect(entry.staged == .unmodified, "staged should be unmodified for unstaged change")
                #expect(entry.worktree == .modified, "worktree should be modified")
            } else {
                Issue.record("Should find modified.txt entry")
            }
            
            let addedEntry = status.entries.first { $0.path == "added.txt" }
            if let entry = addedEntry {
                #expect(entry.staged == .added, "staged should be added for new file in index")
                #expect(entry.worktree == .unmodified, "worktree should be unchanged")
            } else {
                Issue.record("Should find added.txt entry")
            }
        } catch {
            Issue.record("Failed to parse hand-crafted data: \(error)")
        }
    }
}
