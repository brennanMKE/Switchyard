// CommitDraftStore.swift
//
// #0564: the Changes view's unsaved commit message, kept per repository in
// user defaults, so closing the window or quitting does not lose it (guide
// §11 decision 45). `ContentView` restores it when a window opens a
// repository and saves it on every edit; a commit or an amend clears it.

import Foundation

/// Reads and writes one repository's draft. `nonisolated`: a plain value
/// over `UserDefaults`, which is thread-safe.
public nonisolated struct CommitDraftStore {
    /// Every key starts with this, then the repository's path.
    public static let keyPrefix = "commitDraft:"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The draft saved for `repositoryPath`, or `nil` when none is.
    public func load(for repositoryPath: String) -> String? {
        defaults.string(forKey: Self.key(for: repositoryPath))
    }

    /// Saves `text` for `repositoryPath`; a blank `text` removes the entry,
    /// so a committed or emptied draft leaves nothing behind.
    public func save(_ text: String, for repositoryPath: String) {
        let key = Self.key(for: repositoryPath)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    static func key(for repositoryPath: String) -> String { keyPrefix + repositoryPath }
}
