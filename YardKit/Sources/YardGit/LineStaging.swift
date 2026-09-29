// LineStaging.swift — patches for selected lines of one hunk (#0476)

import Foundation

/// Which way a line patch is applied, which decides what the unselected
/// lines become (guide §11 decision 35).
///
/// A patch has a fixed side — the one `git apply` matches against the file
/// it changes — and a result side. The fixed side must stay exactly as the
/// listing printed it, so every line on it is kept; only the result side
/// loses the unselected changes.
enum LinePatchDirection: Sendable {
    /// `git apply` (stage): the old side is fixed. An unselected `-` line
    /// stays, as context; an unselected `+` line is dropped.
    case forward
    /// `git apply --reverse` (unstage, discard): the new side is fixed. An
    /// unselected `+` line stays, as context; an unselected `-` line is
    /// dropped.
    case reverse
}

/// One body line of a partial hunk: its marker, the text after it, and
/// whether git printed `\ No newline at end of file` after it.
private struct PatchLine {
    var marker: Character
    var text: Substring
    var noNewline: Bool
}

/// The patch for the body lines `lines` of `hunk`, one hunk of `file`: the
/// file's header, then one hunk that makes only the selected changes.
/// `lines` are indices into `hunk.body`, and each must be a `+` or `-` line;
/// anything else throws `StagingError.notAChangedLine` before any text is
/// built. Selecting every changed line yields the hunk's own patch text.
///
/// Three rules beyond "unselected changes vanish", each measured against
/// `git apply` (2026-09-29, git 2.54.0; the table in #0476):
///
/// - **Counts are recounted, starts are kept.** The fixed side's lines are
///   all kept, so its start is still right; git positions a reverse patch
///   by the new start, a forward one by the old.
/// - **`\ No newline at end of file` stays on the last line of its side.**
///   A line that lost its newline can only be the last line of a side. When
///   the selection puts lines after it — a line added after a last line
///   whose newline change was not selected — a context line is split into
///   `-L` and `+L`, the marker kept only on the side where `L` is still
///   last, and a changed line on the result side drops its marker. Without
///   this `git apply` joins the two lines silently (`b` and `c` became
///   `bc`, exit 0).
/// - **A partial new or deleted file is an ordinary modification.** A new
///   file's patch cannot keep context on its old side, nor a deletion's on
///   its new side: git refuses (`new file f depends on old contents`,
///   `deleted file f still has contents`). When that side ends up
///   non-empty, the `new file mode` / `deleted file mode` line is dropped
///   and `/dev/null` is replaced by the path. Both halves are needed:
///   dropping only the mode line makes `git apply --cached --reverse` exit
///   0 and remove the whole index entry.
func linePatch(
    file: FileDiff, hunk: Hunk, lines: Set<Int>, direction: LinePatchDirection
) throws -> String {
    for index in lines.sorted() {
        // The marker is the line's first *scalar*: a line opening with a
        // combining mark fuses with it into one `Character` (#0488).
        let marker = hunk.body.indices.contains(index) ? hunk.body[index].unicodeScalars.first : nil
        guard marker == "+" || marker == "-" else {
            throw StagingError.notAChangedLine(hunkID: hunk.id, line: index)
        }
    }

    // What each line becomes; `nil` drops it.
    var kept: [PatchLine] = []
    var droppedLast = false
    for (index, raw) in hunk.body.enumerated() {
        guard let scalar = raw.unicodeScalars.first else { continue }
        let marker = Character(scalar)
        if marker == "\\" {
            if !droppedLast, !kept.isEmpty { kept[kept.count - 1].noNewline = true }
            continue
        }
        let selected = lines.contains(index)
        let becomes: Character? = switch (marker, direction) {
        case (" ", _): " "
        case ("-", .forward): selected ? "-" : " "
        case ("+", .forward): selected ? "+" : nil
        case ("-", .reverse): selected ? "-" : nil
        case ("+", .reverse): selected ? "+" : " "
        default: nil
        }
        droppedLast = becomes == nil
        if let becomes {
            kept.append(PatchLine(marker: becomes, text: Substring(raw.unicodeScalars.dropFirst()), noNewline: false))
        }
    }

    // `\ No newline` may only mark the last line of its side.
    let lastOld = kept.lastIndex { $0.marker != "+" }
    let lastNew = kept.lastIndex { $0.marker != "-" }
    var body: [PatchLine] = []
    for (index, line) in kept.enumerated() {
        guard line.noNewline else { body.append(line); continue }
        let isLastOld = index == lastOld, isLastNew = index == lastNew
        switch line.marker {
        case " " where !(isLastOld && isLastNew):
            body.append(PatchLine(marker: "-", text: line.text, noNewline: isLastOld))
            body.append(PatchLine(marker: "+", text: line.text, noNewline: isLastNew))
        case "-" where !isLastOld, "+" where !isLastNew:
            body.append(PatchLine(marker: line.marker, text: line.text, noNewline: false))
        default:
            body.append(line)
        }
    }

    let oldCount = body.count { $0.marker != "+" }
    let newCount = body.count { $0.marker != "-" }
    var header = file.headerText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if header.last == "" { header.removeLast() }
    if oldCount > 0, header.contains(where: { $0.hasPrefix("new file mode ") }),
       let plus = header.first(where: { $0.hasPrefix("+++ b/") }) {
        header.removeAll { $0.hasPrefix("new file mode ") }
        header = header.map { $0 == "--- /dev/null" ? "--- a/" + plus.dropFirst("+++ b/".count) : $0 }
    }
    if newCount > 0, header.contains(where: { $0.hasPrefix("deleted file mode ") }),
       let minus = header.first(where: { $0.hasPrefix("--- a/") }) {
        header.removeAll { $0.hasPrefix("deleted file mode ") }
        header = header.map { $0 == "+++ /dev/null" ? "+++ b/" + minus.dropFirst("--- a/".count) : $0 }
    }

    var text = header.joined(separator: "\n") + "\n"
    text += "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@"
        + hunkHeaderSection(hunk.header) + "\n"
    for line in body {
        text += String(line.marker) + line.text + "\n"
        if line.noNewline { text += "\\ No newline at end of file\n" }
    }
    return text
}

/// What follows the closing `@@` of a hunk header — git's function-context
/// text, with its leading space — or "" when there is none.
private func hunkHeaderSection(_ header: String) -> Substring {
    guard header.count > 2,
          let close = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
    else { return "" }
    return header[close.upperBound...]
}

/// Finds `hunkID` in `files` and builds `linePatch` for it. An id that is
/// not in the listing throws `StagingError.unknownHunkIDs`, and a combined
/// (`diff --cc`) block `StagingError.combinedHunkNotStageable` — the two
/// refusals `selectPatch` makes for whole hunks, for the same reasons.
func selectLinePatch(
    hunkID: String, lines: Set<Int>, from files: [FileDiff], area: DiffArea,
    direction: LinePatchDirection
) throws -> String {
    for file in files {
        guard let hunk = file.hunks.first(where: { $0.id == hunkID }) else { continue }
        if file.headerText.hasPrefix("diff --cc ") {
            throw StagingError.combinedHunkNotStageable(path: file.path)
        }
        return try linePatch(file: file, hunk: hunk, lines: lines, direction: direction)
    }
    throw StagingError.unknownHunkIDs(ids: [hunkID], area: area)
}

// MARK: - Journaled entry points (#0477)

/// Stages the selected lines of one unstaged hunk: the index gains exactly
/// those `+` and `-` lines. `hunkID` comes from `listHunks(at:area:
/// .unstaged)` and `lines` are indices into that hunk's `body`.
///
/// Like `stageHunks`, the listing is re-taken inside the call, so the patch
/// is built from fresh headers. A hunk id names its body exactly (it is a
/// hash of path and body), so the same id means the same lines at the same
/// indices; a hunk whose lines changed since it was listed has a new id and
/// is refused as `StagingError.unknownHunkIDs`. A selected index that is
/// not a changed line throws `StagingError.notAChangedLine`. Both are
/// thrown before `git apply` runs, so nothing is staged; the checkpoint is
/// already written by then, as for `stageHunks`, and its undo is a no-op.
///
/// An empty `lines` is a no-op with no entry. **Writes exactly one journal
/// entry per call**, operation `stage`, so Edit ▸ Undo reads "Undo Stage".
public func stageLines(
    hunkID: String,
    lines: [Int],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    guard !lines.isEmpty else { return }
    try JournalCheckpoint.around(operation: "stage", at: path, git: git) { git in
        let files = try listHunks(at: path, area: .unstaged, git: git)
        let patch = try selectLinePatch(
            hunkID: hunkID, lines: Set(lines), from: files, area: .unstaged, direction: .forward)
        try applyPatchToIndex(patch, at: path, git: git)
    }
}

/// Unstages the selected lines of one staged hunk: the index loses exactly
/// those `+` and `-` lines, the worktree is untouched. `hunkID` comes from
/// `listHunks(at:area: .staged)`. The patch is applied with `git apply
/// --cached --reverse`, the mechanism `unstageHunks` uses. Refusals, the
/// empty no-op and the single entry (operation `unstage`) are as for
/// `stageLines`.
public func unstageLines(
    hunkID: String,
    lines: [Int],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    guard !lines.isEmpty else { return }
    try JournalCheckpoint.around(operation: "unstage", at: path, git: git) { git in
        let files = try listHunks(at: path, area: .staged, git: git)
        let patch = try selectLinePatch(
            hunkID: hunkID, lines: Set(lines), from: files, area: .staged, direction: .reverse)
        try git.run(["apply", "--cached", "--reverse"],
                    workingDirectory: path,
                    standardInput: Data(patch.utf8))
    }
}
