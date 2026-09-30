// RemoteConfig.swift — list, add and re-point remotes (guide §11 decision 41)

import Foundation

/// The repository's remotes as configuration: which exist, where they point,
/// and the Add Remote… / Edit URL… mutations (guide §11 decision 41).
///
/// Every call shells out to `git remote`, so git's own rules decide and
/// `GitProcess`'s environment forbids every prompt. Nothing here touches the
/// network. Names and URLs are checked in Swift first (`nameProblem`,
/// `urlProblem`) so a sheet can say what is wrong before anything runs; git
/// refuses the same names anyway.
///
/// **Not journaled.** A remote lives in `git config`, which a journal entry
/// does not capture (`JournalCheckpoint` records refs, `HEAD`, the index,
/// the worktree, the sequencer and the stash). Adding a remote or changing
/// its URL moves no ref, so Edit ▸ Undo keeps naming the operation before it
/// and restoring that one leaves the new configuration alone. The sheets say
/// so. Rename and remove move refs as well, and are handled in
/// `RemoteRename.swift`.
public enum RemoteConfig {

    /// One configured remote, as `git remote -v` reports it: URLs after
    /// `url.<base>.insteadOf` rewriting, which is what git contacts.
    public struct Remote: Equatable, Sendable, Identifiable {
        public let name: String
        /// The fetch URL; `nil` when the remote has none (`remote.<name>.url`
        /// unset or empty).
        public let fetchURL: String?
        /// Every push URL, in configuration order. Equal to `[fetchURL]`
        /// unless `remote.<name>.pushurl` is set.
        public let pushURLs: [String]

        public var id: String { name }

        /// True when pushing goes somewhere other than the fetch URL.
        public var pushDiffers: Bool {
            pushURLs != (fetchURL.map { [$0] } ?? [])
        }

        public init(name: String, fetchURL: String?, pushURLs: [String]) {
            self.name = name
            self.fetchURL = fetchURL
            self.pushURLs = pushURLs
        }
    }

    /// A refusal decided before `git` runs; nothing was changed.
    public enum Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        /// `nameProblem` rejected the name; `reason` is its sentence.
        case invalidName(String, reason: String)
        /// A remote with this name already exists.
        case nameInUse(String)
        /// No remote has this name.
        case unknownRemote(String)
        /// The name nests with an existing remote's (`a` beside `a/b`): their
        /// remote-tracking branches would share `refs/remotes/a/`. `git
        /// remote add` refuses this (measured); `git remote rename` does not.
        case nestedName(String, existing: String)
        /// `urlProblem` rejected the URL; `reason` is its sentence.
        case invalidURL(reason: String)

        public var description: String {
            switch self {
            case let .invalidName(name, reason):
                "“\(name)” can’t be a remote name: \(reason) Nothing was changed."
            case let .nameInUse(name):
                "A remote named “\(name)” already exists. Nothing was changed."
            case let .unknownRemote(name):
                "There is no remote named “\(name)”. Nothing was changed."
            case let .nestedName(name, existing):
                "“\(name)” can’t be used beside the remote “\(existing)”: their branches would "
                    + "share a folder. Nothing was changed."
            case let .invalidURL(reason):
                "\(reason) Nothing was changed."
            }
        }
    }

    // MARK: - Validation

    /// Why git would refuse `name` as a remote name, or nil when it is
    /// acceptable. Git's rule (`valid_remote_name`) is that
    /// `refs/remotes/<name>/test` is a valid ref name; this mirrors
    /// `git check-ref-format` on that ref, measured against it by
    /// `RemoteConfigTests`, plus one rule of Switchyard's own: a leading `-`,
    /// which git accepts after `--` but every later `git fetch <name>` would
    /// read as an option.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.hasPrefix("-") { return "A remote name can’t start with “-”." }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "A remote name can’t contain control characters."
        }
        if name.contains(" ") { return "A remote name can’t contain spaces." }
        if let bad = name.first(where: { "~^:?*[\\".contains($0) }) {
            return "A remote name can’t contain “\(bad)”."
        }
        if name.contains("..") { return "A remote name can’t contain “..”." }
        if name.contains("@{") { return "A remote name can’t contain “@{”." }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") {
            return "A remote name can’t start or end with “/” or contain “//”."
        }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.hasPrefix(".") { return "No part of a remote name can start with “.”." }
            if component.hasSuffix(".lock") { return "No part of a remote name can end with “.lock”." }
        }
        return nil
    }

    /// Why `url` (already trimmed of surrounding whitespace) cannot be a
    /// remote URL, or nil. Git itself accepts anything, including an empty
    /// URL and one with a newline in it (measured: both `git remote add`
    /// exit 0, and the newline splits `git remote -v`'s line); a leading `-`
    /// is refused because a URL is an argument to `ssh` (CVE-2017-1000117).
    public static func urlProblem(_ url: String) -> String? {
        if url.isEmpty { return "Enter a URL." }
        if url.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "A URL can’t contain line breaks or control characters."
        }
        if url.hasPrefix("-") { return "A URL can’t start with “-”." }
        return nil
    }

    // MARK: - Reading

    /// Every configured remote, sorted by name, from one `git remote -v`.
    public static func list(at path: String, git: GitProcess = GitProcess()) async throws -> [Remote] {
        parseVerbose(try await git.run(["remote", "-v"], workingDirectory: path).lines)
    }

    /// Synchronous twin of `list(at:git:) async`.
    public static func list(at path: String, git: GitProcess = GitProcess()) throws -> [Remote] {
        parseVerbose(try git.run(["remote", "-v"], workingDirectory: path).lines)
    }

    /// Parses `git remote -v`: `<name>\t<url> (fetch)` then one
    /// `<name>\t<url> (push)` per push URL. A remote with no URL prints
    /// `<name>\t` and nothing else (measured). A line without a tab — the
    /// tail of a URL git stored with a newline in it — is skipped.
    static func parseVerbose(_ lines: [String]) -> [Remote] {
        var order: [String] = []
        var fetch: [String: String] = [:]
        var push: [String: [String]] = [:]
        for line in lines {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[..<tab])
            let rest = String(line[line.index(after: tab)...])
            if !order.contains(name) { order.append(name) }
            if rest.hasSuffix(" (fetch)") {
                let url = String(rest.dropLast(" (fetch)".count))
                if !url.isEmpty { fetch[name] = url }
            } else if rest.hasSuffix(" (push)") {
                push[name, default: []].append(String(rest.dropLast(" (push)".count)))
            }
        }
        return order.sorted().map {
            Remote(name: $0, fetchURL: fetch[$0], pushURLs: push[$0] ?? [])
        }
    }

    /// `remote.<name>.url` exactly as configured — before `insteadOf`
    /// rewriting — for Edit URL…'s field; nil when unset.
    public static func configuredURL(of name: String, at path: String, git: GitProcess = GitProcess()) throws -> String? {
        try RemoteSync.configValue("remote.\(name).url", at: path, git: git)
    }

    // MARK: - Mutations

    /// Add Remote…: `git remote add -- <name> <url>`. Refused before git
    /// runs when the name or URL is invalid or the name is taken. Nothing is
    /// fetched: the remote's branches appear after Fetch.
    public static func add(name: String, url: String, at path: String, git: GitProcess = GitProcess()) throws {
        let url = url.trimmingCharacters(in: .whitespaces)
        if let reason = nameProblem(name) { throw Refusal.invalidName(name, reason: reason) }
        if let reason = urlProblem(url) { throw Refusal.invalidURL(reason: reason) }
        if let refusal = conflict(for: name, among: try names(at: path, git: git)) { throw refusal }
        try git.run(["remote", "add", "--", name, url], workingDirectory: path)
    }

    /// Edit URL…: `git remote set-url -- <name> <url>`, the fetch URL. A
    /// separately configured push URL is left as it is.
    public static func setURL(_ url: String, forRemote name: String, at path: String, git: GitProcess = GitProcess()) throws {
        let url = url.trimmingCharacters(in: .whitespaces)
        if let reason = urlProblem(url) { throw Refusal.invalidURL(reason: reason) }
        guard try names(at: path, git: git).contains(name) else { throw Refusal.unknownRemote(name) }
        try git.run(["remote", "set-url", "--", name, url], workingDirectory: path)
    }

    /// Why `name` cannot be used beside the remotes `names`, or nil: a
    /// remote already has it, or it nests with one (`a` beside `a/b`).
    /// Pure, so a sheet can say so as the user types.
    public static func conflict(for name: String, among names: [String]) -> Refusal? {
        if names.contains(name) { return .nameInUse(name) }
        if let existing = names.first(where: { $0.hasPrefix(name + "/") || name.hasPrefix($0 + "/") }) {
            return .nestedName(name, existing: existing)
        }
        return nil
    }

    /// The configured remote names, as `git remote` lists them.
    static func names(at path: String, git: GitProcess) throws -> [String] {
        try git.run(["remote"], workingDirectory: path).lines.filter { !$0.isEmpty }
    }
}

/// Every refusal is the repository's own state or the caller's input,
/// decided before anything runs: guide §6 code 6, like `RemoteSync.Refusal`.
extension RemoteConfig.Refusal: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
