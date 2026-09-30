// DiffViewOptionsTests.swift — a diff view's options (#0538)

import Testing
@testable import YardGit
@testable import YardUI

private func file(_ path: String) -> FileDiff {
    FileDiff(path: path, oldMode: nil, newMode: nil, isBinary: false,
             headerText: "diff --git a/\(path) b/\(path)\n", hunks: [])
}

@Test
func theDefaultOptionsAreTheOnesStagingActsOn() {
    let options = DiffViewOptions()
    #expect(options.isStandard)
    #expect(options.diffOptions == .standard)
    #expect(options.summary == nil)
}

@Test
func eachOptionReachesGit() {
    #expect(DiffViewOptions(ignoresWhitespace: true).diffOptions == DiffOptions(ignoresWhitespace: true))
    #expect(DiffViewOptions(context: .ten).diffOptions.contextLines == 10)
    #expect(DiffViewOptions(context: .wholeFile).diffOptions.contextLines == DiffOptions.wholeFile)
    #expect(!DiffViewOptions(ignoresWhitespace: true).isStandard)
    #expect(!DiffViewOptions(context: .wholeFile).isStandard)
}

@Test
func theSummarySaysWhatIsDifferent() {
    #expect(DiffViewOptions(ignoresWhitespace: true).summary == "Whitespace ignored")
    #expect(DiffViewOptions(context: .ten).summary == "10 lines of context")
    #expect(DiffViewOptions(ignoresWhitespace: true, context: .wholeFile).summary
        == "Whitespace ignored · Whole file")
}

@Test
func aFileTheOptionsHidHasNothingToDraw() {
    let full = [file("a.txt"), file("ws.txt")]
    let shown = [file("a.txt")]
    #expect(DiffViewOptions.file(full[0], in: shown)?.path == "a.txt")
    #expect(DiffViewOptions.file(full[1], in: shown) == nil)
    #expect(DiffViewOptions.file(full[1], in: nil) == full[1], "standard options draw the file itself")
    #expect(DiffViewOptions.whitespaceOnlyNote(for: "ws.txt") == "Only whitespace changed in ws.txt")
}
