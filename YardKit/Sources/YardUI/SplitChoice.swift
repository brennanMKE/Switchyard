import Foundation
import YardGit

/// #0375: the arguments the Split sheet hands to `Split.run`.
public nonisolated struct SplitArguments: Equatable, Sendable {
    public let commit: String
    public let hunkID: String
    /// `nil` keeps the original message, `Split.run`'s own default.
    public let firstMessage: String?
    public let secondMessage: String?

    public init(commit: String, hunkID: String, firstMessage: String?, secondMessage: String?) {
        self.commit = commit
        self.hunkID = hunkID
        self.firstMessage = firstMessage
        self.secondMessage = secondMessage
    }
}

/// #0375: the Split sheet's state, pure so every rule is testable.
public nonisolated struct SplitChoice: Equatable, Sendable {
    public let commit: String
    public let originalMessage: String
    /// Every hunk the commit introduces, in file order then hunk order --
    /// the listing `Split.run` resolves `hunkID` against (`commitDiff`).
    public let hunks: [Hunk]
    public var selectedHunkID: String?
    public var firstMessage: String
    public var secondMessage: String

    public init(commit: String, message: String, files: [FileDiff]) {
        self.commit = commit
        self.originalMessage = message
        self.hunks = files.flatMap(\.hunks)
        self.selectedHunkID = nil
        self.firstMessage = message
        self.secondMessage = message
    }

    /// Why the sheet cannot split at all; `nil` when it can.
    public var unavailableReason: String? {
        hunks.count < 2 ? "This commit has only one change, so there’s nothing to split." : nil
    }

    /// `nil` until a listed hunk is selected and both messages are non-empty.
    public var arguments: SplitArguments? {
        guard unavailableReason == nil,
              let id = selectedHunkID, hunks.contains(where: { $0.id == id }),
              !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secondMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return SplitArguments(
            commit: commit, hunkID: id,
            firstMessage: firstMessage == originalMessage ? nil : firstMessage,
            secondMessage: secondMessage == originalMessage ? nil : secondMessage)
    }
}
