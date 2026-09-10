// RerereResolution.swift — one recorded resolution's bytes and diff (#0065 round 2)
//
// The sidebar's Detail pane needs to SHOW what a recorded resolution does,
// and the measured `git rerere` text surfaces cannot provide it: once the
// conflict settles, `git rerere status`, `diff`, and `remaining` all print
// nothing (measured, git 2.50.1, the #0065 round-1 probe). What survives is
// the rr-cache itself: `rr-cache/<conflict-id>/preimage` (the conflict with
// markers) and `postimage` (the resolved file). This file reads those bytes
// read-only and computes the preimage → postimage unified diff, in the same
// `--- a/<path>` / `+++ b/<path>` shape `git rerere diff` prints while a
// conflict IS live (measured in the round-2 probe) — computed here, never
// shelled out for, because `Rerere` never invokes `git rerere` in any form.

import Foundation

extension Rerere {

    /// One recorded resolution: the cached conflict preimage, the resolved
    /// postimage, and the unified diff between them — what the Detail pane
    /// renders for a selected sidebar row.
    public struct Resolution: Sendable, Equatable {

        /// The rr-cache directory this resolution was read from.
        public let conflictID: String

        /// A conflicted path attributed to this resolution, when the live
        /// state names one (MERGE_RR). `nil` for a settled resolution —
        /// git's rr-cache is keyed by content hash and stores no path, and
        /// no measured `git rerere` surface recovers one after the conflict
        /// ends. The Detail pane renders the diff under the conflict id in
        /// that case rather than inventing a path.
        public let path: String?

        /// `rr-cache/<conflict-id>/preimage` — the conflict with markers.
        public let preimage: Data

        /// `rr-cache/<conflict-id>/postimage` — the recorded resolution.
        public let postimage: Data

        /// The preimage → postimage diff, in `git rerere diff`'s shape. One
        /// element, except: empty when the sides are byte-equal, and one
        /// `isBinary` element (no hunks) when either side is not UTF-8.
        public let diff: [FileDiff]

        public init(
            conflictID: String, path: String?, preimage: Data, postimage: Data, diff: [FileDiff]
        ) {
            self.conflictID = conflictID
            self.path = path
            self.preimage = preimage
            self.postimage = postimage
            self.diff = diff
        }
    }

    /// Reads the recorded resolution cached under `conflictID` in the
    /// repository at `path`. Read-only: file reads only, no `git rerere`
    /// invocation, no config read — a recorded resolution's bytes exist
    /// whether or not `rerere.enabled` is still set.
    ///
    /// - Throws: `RerereError.noRecordedResolution` when the id is not a
    ///   conflict id at all, names no rr-cache directory, or its directory
    ///   holds no `postimage` (merely known, never resolved); and
    ///   `RerereError.unreadableStateFile` when a state file exists but
    ///   cannot be read.
    public static func resolution(
        for conflictID: String,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Resolution {
        // The id becomes a path component below, so it is validated first:
        // anything that cannot be a conflict id (including anything shaped
        // like a traversal) has no resolution to read, by the same rule the
        // cache scanner refuses directories with.
        guard isConflictID(conflictID) else {
            throw RerereError.noRecordedResolution(conflictID: conflictID)
        }
        let context = try WorktreeContext.resolve(path: path, git: git)
        let cacheDir = try context.path(for: "rr-cache", git: git)
        let directory = URL(fileURLWithPath: cacheDir).appendingPathComponent(conflictID)

        let preimage: Data
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("preimage").path) {
            do {
                preimage = try Data(contentsOf: directory.appendingPathComponent("preimage"))
            } catch {
                throw RerereError.unreadableStateFile(
                    name: "rr-cache/\(conflictID)/preimage", detail: String(describing: error))
            }
        } else {
            throw RerereError.noRecordedResolution(conflictID: conflictID)
        }

        let postimageURL = directory.appendingPathComponent("postimage")
        guard FileManager.default.fileExists(atPath: postimageURL.path) else {
            // A preimage without a postimage is a merely-known conflict —
            // rerere is waiting for a resolution, and there is none to show.
            throw RerereError.noRecordedResolution(conflictID: conflictID)
        }
        let postimage: Data
        do {
            postimage = try Data(contentsOf: postimageURL)
        } catch {
            throw RerereError.unreadableStateFile(
                name: "rr-cache/\(conflictID)/postimage", detail: String(describing: error))
        }

        // A live path, when one is attributed: MERGE_RR maps path → id for
        // conflicts git is currently tracking (a replay attributes too —
        // measured: the replay's record reaches MERGE_RR's successor state,
        // and `Rerere.status` reads both sources). A settled resolution has
        // none, and `path` stays nil rather than guessing.
        var attributedPath: String?
        let mergeRRPath = try context.path(for: "MERGE_RR", git: git)
        if FileManager.default.fileExists(atPath: mergeRRPath) {
            let tracked: [TrackedPath]
            do {
                tracked = try parseMergeRR(try Data(contentsOf: URL(fileURLWithPath: mergeRRPath)))
            } catch {
                tracked = []
            }
            attributedPath = tracked
                .filter { $0.conflictID == conflictID }
                .map(\.path)
                .sorted()
                .first
        }

        return Resolution(
            conflictID: conflictID,
            path: attributedPath,
            preimage: preimage,
            postimage: postimage,
            diff: unifiedDiff(path: attributedPath, old: preimage, new: postimage))
    }

    // MARK: - The preimage → postimage diff

    /// One line of the edit script between the two sides.
    private enum DiffOp {
        case same
        case deleted
        case added
    }

    /// Computes the unified diff `old` → `new` in `git rerere diff`'s shape:
    /// `--- a/<path>` / `+++ b/<path>` headers (when a path is known) and
    /// `@@ -a,b +c,d @@` hunks with three lines of context, `-`/`+`/` `
    /// body markers, and `\ No newline at end of file` where a side's last
    /// line lacks its terminating newline.
    ///
    /// Not byte-equal to `git rerere diff` by contract — git's xdiff makes
    /// slightly different context-merge choices — but the same shape, and
    /// the recorded resolution it displays is the cached bytes themselves.
    /// Either side over 2000 lines falls back to a single whole-file
    /// replacement hunk: the DP below is O(n·m), and a resolution diff that
    /// large would not be readable in the Detail pane anyway.
    private static func unifiedDiff(path: String?, old: Data, new: Data) -> [FileDiff] {
        // Non-UTF-8 sides are reported, not diffed — the same verdict
        // `FileDiff.isBinary` carries for git's own binary output.
        guard let oldLines = lines(of: old), let newLines = lines(of: new) else {
            let displayPath = path ?? "unknown"
            return [FileDiff(
                path: displayPath,
                oldMode: nil, newMode: nil, isBinary: true,
                headerText: "diff --git a/\(displayPath) b/\(displayPath)\n",
                hunks: [])]
        }

        // A side's last line carries its newline-termination: the sentinel
        // suffix makes "ends with newline" and "does not" differ as LINE
        // CONTENT, which is what git's own diff reports (a missing trailing
        // newline is a real change, rendered with the `\ No newline at end
        // of file` marker after the line).
        func keys(_ lines: FileLines) -> [String] {
            var result = lines.lines
            if let last = result.indices.last, !lines.endsWithNewline {
                result[last] += Self.newlineSentinel
            }
            return result
        }
        let oldKeys = keys(oldLines)
        let newKeys = keys(newLines)

        let script: [(op: DiffOp, key: String)]
        if oldKeys.count > Self.diffLineCap || newKeys.count > Self.diffLineCap {
            script = wholeFileReplacement(old: oldKeys, new: newKeys)
        } else {
            script = editScript(old: oldKeys, new: newKeys)
        }

        let displayPath = path ?? "rr-cache (path not attributed)"
        let headerText = "diff --git a/\(displayPath) b/\(displayPath)\n"
            + "--- a/\(displayPath)\n+++ b/\(displayPath)\n"
        return [FileDiff(
            path: displayPath,
            oldMode: nil,
            newMode: nil,
            isBinary: false,
            headerText: headerText,
            hunks: hunks(from: script, path: displayPath))]
    }

    /// Suffix marking a line that lacks its terminating newline. The NUL
    /// byte cannot appear in a text file line, so it can never collide with
    /// real content.
    private static let newlineSentinel = "\u{0}"

    /// Lines past which the O(n·m) diff falls back to a whole-file hunk.
    private static let diffLineCap = 2_000

    private struct FileLines {
        var lines: [String]
        var endsWithNewline: Bool
    }

    /// Splits file bytes into lines on `\n`, strictly UTF-8 — `nil` when the
    /// bytes are not text. A trailing `\n` terminates the last line and is
    /// not content; its absence is (see `keys`).
    private static func lines(of data: Data) -> FileLines? {
        guard String(bytes: data, encoding: .utf8) != nil else { return nil }
        var lines: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0x0A {
                lines.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(byte)
            }
        }
        var endsWithNewline = false
        if !current.isEmpty {
            lines.append(String(decoding: current, as: UTF8.self))
        } else if !lines.isEmpty {
            endsWithNewline = true
        }
        return FileLines(lines: lines, endsWithNewline: endsWithNewline)
    }

    /// The LCS edit script: `.same` runs interleaved with `.deleted` (old
    /// side) and `.added` (new side) runs, in output order.
    private static func editScript(old: [String], new: [String]) -> [(op: DiffOp, key: String)] {
        if old.isEmpty && new.isEmpty { return [] }
        let width = new.count + 1
        // LCS length table; Int32 keeps a 2000×2000 comparison under 16 MB.
        var table = [Int32](repeating: 0, count: (old.count + 1) * width)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i * width + j] = old[i] == new[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var script: [(op: DiffOp, key: String)] = []
        var i = 0
        var j = 0
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                script.append((.same, old[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                script.append((.deleted, old[i]))
                i += 1
            } else {
                script.append((.added, new[j]))
                j += 1
            }
        }
        while i < old.count { script.append((.deleted, old[i])); i += 1 }
        while j < new.count { script.append((.added, new[j])); j += 1 }
        return script
    }

    /// The oversized-input fallback: one hunk replacing the whole old side
    /// with the whole new side. Every line is real; only the LCS's minimal
    /// common-line alignment is given up, which for inputs this large is
    /// unreadable anyway.
    private static func wholeFileReplacement(
        old: [String], new: [String]
    ) -> [(op: DiffOp, key: String)] {
        var script: [(op: DiffOp, key: String)] = old.map { (.deleted, $0) }
        script += new.map { (.added, $0) }
        return script
    }

    /// Groups the edit script into `@@` hunks with three lines of context,
    /// merging changes separated by no more than `2 × context` shared lines
    /// — the grouping git's own output uses.
    private static func hunks(from script: [(op: DiffOp, key: String)], path: String) -> [Hunk] {
        let context = 3
        // Index every change, then extend each change run by the context on
        // both sides and merge runs whose extended ranges touch or overlap.
        var changeRuns: [Range<Int>] = []
        var index = 0
        while index < script.count {
            guard script[index].op != .same else { index += 1; continue }
            let start = index
            while index < script.count, script[index].op != .same { index += 1 }
            changeRuns.append(start..<index)
        }
        guard !changeRuns.isEmpty else { return [] }

        var hunkRanges: [Range<Int>] = []
        for run in changeRuns {
            let extended = max(run.lowerBound - context, 0)..<min(run.upperBound + context, script.count)
            if !hunkRanges.isEmpty, extended.lowerBound <= hunkRanges[hunkRanges.count - 1].upperBound {
                let previous = hunkRanges.removeLast()
                hunkRanges.append(previous.lowerBound..<extended.upperBound)
            } else {
                hunkRanges.append(extended)
            }
        }

        // Body lines: the `\`-marker after a line whose key carried the
        // newline sentinel, ` ` / `-` / `+` prefixes for the rest.
        func render(_ entry: (op: DiffOp, key: String)) -> [String] {
            let marker: String
            switch entry.op {
            case .same: marker = " "
            case .deleted: marker = "-"
            case .added: marker = "+"
            }
            var output = [marker + entry.key]
            if entry.key.hasSuffix(Self.newlineSentinel) {
                output.append("\\ No newline at end of file")
            }
            return output
        }

        var hunks: [Hunk] = []
        var seenBodies: [String: Int] = [:]
        for range in hunkRanges {
            var oldStartInScript = 0
            var newStartInScript = 0
            for entry in script[..<range.lowerBound] {
                if entry.op != .added { oldStartInScript += 1 }
                if entry.op != .deleted { newStartInScript += 1 }
            }
            var body: [String] = []
            var oldCount = 0
            var newCount = 0
            for entry in script[range] {
                switch entry.op {
                case .same: oldCount += 1; newCount += 1
                case .deleted: oldCount += 1
                case .added: newCount += 1
                }
                body += render(entry)
            }
            // git's header convention: a 1-line side prints without `,1`,
            // and an empty side prints line 0 at the position the change
            // abuts (`@@ -3,0 +4,2 @@`).
            let oldHeader = oldCount == 0
                ? "\(oldStartInScript),0"
                : "\(oldStartInScript + 1)" + (oldCount == 1 ? "" : ",\(oldCount)")
            let newHeader = newCount == 0
                ? "\(newStartInScript),0"
                : "\(newStartInScript + 1)" + (newCount == 1 ? "" : ",\(newCount)")
            let header = "@@ -\(oldHeader) +\(newHeader) @@"

            // The stable content-derived id `Hunk` carries everywhere else,
            // with the same `-N` suffix for repeated bodies as `HunkParser`.
            let digest = HunkParser.hunkID(path: path, body: body)
            let occurrence = (seenBodies[digest] ?? 0) + 1
            seenBodies[digest] = occurrence
            hunks.append(Hunk(
                id: occurrence == 1 ? digest : "\(digest)-\(occurrence)",
                path: path,
                oldStart: oldCount == 0 ? oldStartInScript : oldStartInScript + 1,
                oldCount: oldCount,
                newStart: newCount == 0 ? newStartInScript : newStartInScript + 1,
                newCount: newCount,
                header: header,
                body: body))
        }
        return hunks
    }
}
