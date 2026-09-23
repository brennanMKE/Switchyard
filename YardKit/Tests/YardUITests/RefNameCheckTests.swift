// RefNameCheckTests.swift — #0397: the name prompts' surface refusals.
//
// The pure validator's rules — empty, every invalid git-check-ref-format
// rule the sheet checks, branch and tag collision wording — and the sheet's
// disabled-with-reason derivation per prompt kind, asserted as exact
// strings and booleans. No repository needed: RefNameCheck is pure Swift.

import Foundation
import Testing
@testable import YardUI

@MainActor
@Suite("RefNameCheck")
struct RefNameCheckTests {

    // MARK: - The validator: empty

    @Test func emptyNameRefusesWithEnterAName() {
        #expect(RefNameCheck.problem(name: "", kind: .branch, existing: ["main"]) == "Enter a name")
        #expect(RefNameCheck.problem(name: "", kind: .tag, existing: ["v1"]) == "Enter a name")
    }

    @Test func whitespaceOnlyNameRefusesWithEnterAName() {
        #expect(
            RefNameCheck.problem(name: "   ", kind: .branch, existing: []) == "Enter a name")
        #expect(
            RefNameCheck.problem(name: "\n\t ", kind: .tag, existing: []) == "Enter a name")
    }

    // MARK: - The validator: every invalid rule

    /// One name per git-check-ref-format rule #0397 lists, each asserting
    /// the exact invalid sentence — a rule removed from `isInvalid` fails
    /// its entry here.
    @Test func everyInvalidRuleRefusesWithTheInvalidSentence() {
        let invalidNames = [
            "-leading-dash",
            ".leading-dot",
            "trailing-slash/",
            "trailing-dot.",
            "trailing.lock",
            "double..dot",
            "tilde~",
            "caret^",
            "colon:",
            "question?",
            "star*",
            "bracket[",
            "back\\slash",
            "space name",
            "at@{brace",
            "double//slash",
        ]
        #expect(!invalidNames.isEmpty)
        for name in invalidNames {
            #expect(
                RefNameCheck.problem(name: name, kind: .branch, existing: [])
                    == "“\(name)” is not a valid name",
                "expected “\(name)” to be refused as invalid")
        }
    }

    @Test func namesWithinTheRulesAreAccepted() {
        let validNames = [
            "main", "feature/login", "feature/foo-1.2.3", "v1.0", "user@host", "a-b_c",
        ]
        #expect(!validNames.isEmpty)
        for name in validNames {
            #expect(
                RefNameCheck.problem(name: name, kind: .branch, existing: []) == nil,
                "expected “\(name)” to be accepted")
        }
    }

    // MARK: - The validator: collision

    @Test func branchCollisionRefusesWithTheBranchWording() {
        #expect(
            RefNameCheck.problem(name: "main", kind: .branch, existing: ["main", "side"])
                == "A branch named “main” already exists")
    }

    @Test func tagCollisionRefusesWithTheTagWording() {
        #expect(
            RefNameCheck.problem(name: "v1", kind: .tag, existing: ["v1"])
                == "A tag named “v1” already exists")
    }

    @Test func collisionComparesTheTrimmedName() {
        #expect(
            RefNameCheck.problem(name: "  main  ", kind: .branch, existing: ["main"]) != nil)
    }

    @Test func aNameAbsentFromTheListIsAccepted() {
        #expect(RefNameCheck.problem(name: "topic", kind: .branch, existing: ["main"]) == nil)
        #expect(RefNameCheck.problem(name: "v2", kind: .tag, existing: ["v1"]) == nil)
    }

    // MARK: - The sheet's per-kind routing

    private let branches = ["main", "topic"]
    private let tags = ["v1"]

    @Test func createBranchRefusesBranchAndTagCollisions() {
        #expect(
            RefNameCheck.problem(
                for: .createBranch(commit: "c3", subject: "s"), name: "main",
                existingBranches: branches, existingTags: tags)
                == "A branch named “main” already exists")
        #expect(
            RefNameCheck.problem(
                for: .createBranch(commit: "c3", subject: "s"), name: "v1",
                existingBranches: branches, existingTags: tags)
                == "A branch named “v1” already exists")
    }

    @Test func addTagRefusesTagCollisionsButIgnoresBranches() {
        #expect(
            RefNameCheck.problem(
                for: .addTag(commit: "c3", subject: "s"), name: "v1",
                existingBranches: branches, existingTags: tags)
                == "A tag named “v1” already exists")
        #expect(
            RefNameCheck.problem(
                for: .addTag(commit: "c3", subject: "s"), name: "main",
                existingBranches: branches, existingTags: tags) == nil)
    }

    @Test func renameAllowsItsOwnNameButRefusesTheOtherBranches() {
        let prompt = CommitActionPrompt.renameBranch(
            old: "topic", commit: "c3", subject: "s")
        #expect(
            RefNameCheck.problem(
                for: prompt, name: "topic",
                existingBranches: branches, existingTags: tags) == nil)
        #expect(
            RefNameCheck.problem(
                for: prompt, name: "main",
                existingBranches: branches, existingTags: tags)
                == "A branch named “main” already exists")
    }

    @Test func messagePromptsNeverRefuseAName() {
        for prompt in [
            CommitActionPrompt.editMessage(commit: "c3", subject: "s", message: "m"),
            .squash(commit: "c3", subject: "s", message: "m"),
        ] {
            #expect(
                RefNameCheck.problem(
                    for: prompt, name: "anything",
                    existingBranches: branches, existingTags: tags) == nil)
        }
    }

    // MARK: - The sheet's disabled derivation

    @Test func createBranchSheetDisablesOnCollisionAndInvalidAndEmpty() {
        let sheet = CommitActionPromptSheet(
            prompt: .createBranch(commit: "c3", subject: "s"),
            existingBranches: branches, existingTags: tags,
            onRequest: { _ in }, onCancel: {})
        // The @State name starts empty, so a fresh sheet is disabled with a
        // reason — and the typed-name cases ride the pure routing above.
        #expect(sheet.nameProblem == "Enter a name")
        #expect(sheet.confirmDisabled)
    }

    @Test func renameSheetPrefillsItsOldNameAndEnablesTheButton() {
        let sheet = CommitActionPromptSheet(
            prompt: .renameBranch(old: "topic", commit: "c3", subject: "s"),
            existingBranches: branches, existingTags: tags,
            onRequest: { _ in }, onCancel: {})
        #expect(sheet.nameProblem == nil)
        #expect(!sheet.confirmDisabled)
    }

    @Test func addTagSheetStartsDisabledWithTheEmptyReason() {
        let sheet = CommitActionPromptSheet(
            prompt: .addTag(commit: "c3", subject: "s"),
            existingBranches: branches, existingTags: tags,
            onRequest: { _ in }, onCancel: {})
        #expect(sheet.nameProblem == "Enter a name")
        #expect(sheet.confirmDisabled)
    }

    @Test func messagePromptsLeaveTheDisabledConditionToTheMessageRules() {
        let unchanged = CommitActionPromptSheet(
            prompt: .editMessage(commit: "c3", subject: "s", message: "same"),
            existingBranches: branches, existingTags: tags,
            onRequest: { _ in }, onCancel: {})
        #expect(unchanged.nameProblem == nil)
        // The message equals the original: the engine's .nothingToDo refusal,
        // which the old composedRequest == nil half already covered.
        #expect(unchanged.confirmDisabled)
    }
}
