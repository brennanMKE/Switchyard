// CommitTemplate.swift — the text `commit.template` would start a message with (#0562)

import Foundation

/// `commit.template`, read the way git's editor would show it and cleaned
/// the way git would commit it (guide §11 decision 45). `git commit -m`
/// ignores the template (measured), so the Changes view starts its editor
/// with it instead.
public enum CommitTemplate {

    /// The template's text with comment lines and surrounding blank lines
    /// removed (`git stripspace --strip-comments`, which honors
    /// `core.commentChar`), or `nil` when `commit.template` is unset, names
    /// no readable file, or holds only comments.
    ///
    /// `git config --path` expands `~`; a relative path is read relative to
    /// the worktree at `path`, as `git commit` run there would. The file is
    /// the user's, not the repository's — reading it is not reading
    /// `$GIT_DIR`.
    public static func read(
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> String? {
        // Exit 1 when unset.
        let configured = try git.capture(
            ["config", "--path", "commit.template"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).text.trimmingCharacters(in: .newlines)
        guard !configured.isEmpty else { return nil }
        let url = URL(fileURLWithPath: configured, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
        guard let contents = try? Data(contentsOf: url) else { return nil }
        let stripped = try git.run(
            ["stripspace", "--strip-comments"],
            workingDirectory: path, standardInput: contents, extraEnvironment: extraEnvironment
        ).text.trimmingCharacters(in: .newlines)
        return stripped.isEmpty ? nil : stripped
    }
}
