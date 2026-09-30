// CommitDraftTemplateTests.swift — an empty draft starts from commit.template (#0565)

import Testing
@testable import YardUI

private let staged = WorkingChanges(
    staged: [.init(side: .staged, path: "a.txt", state: .modified)], unstaged: [], conflicted: [])

@Test func aNewDraftStartsFromTheTemplateUnlessItHasAMessage() {
    #expect(CommitDraft(template: "Summary\n\nRefs:").message == "Summary\n\nRefs:")
    #expect(CommitDraft(message: "mine", template: "Summary").message == "mine")
    #expect(CommitDraft().message == "")
}

@Test func adoptingATemplateFillsOnlyAnEmptyDraftThatIsNotAmending() {
    var empty = CommitDraft()
    empty.adoptTemplate("Summary")
    #expect(empty.message == "Summary")

    var begun = CommitDraft(message: "begun")
    begun.adoptTemplate("Summary")
    #expect(begun.message == "begun")
    #expect(begun.template == "Summary")

    var amending = CommitDraft()
    amending.setAmending(true, headMessage: "")
    amending.adoptTemplate("Summary")
    #expect(amending.message == "")
}

@Test func anUneditedTemplateBlocksCommitUntilItIsEdited() {
    var draft = CommitDraft(template: "Summary\n\nRefs:")
    #expect(draft.blockedReason(for: staged, amendUnavailable: nil) == "Edit the message from commit.template")
    draft.message += " #42"
    #expect(draft.blockedReason(for: staged, amendUnavailable: nil) == nil)

    draft.message = "Summary\n\nRefs:\n"
    #expect(draft.blockedReason(for: staged, amendUnavailable: nil) == "Edit the message from commit.template",
            "a trailing newline is not an edit")
    draft.setAmending(true, headMessage: "Summary\n\nRefs:")
    #expect(draft.blockedReason(for: staged, amendUnavailable: nil) == nil, "amending ignores the template")
}
