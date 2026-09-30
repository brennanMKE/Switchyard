// MessageTrailers.swift — add a trailer to a commit message the way git does (#0560)

import Foundation

/// Adds a trailer (`Co-authored-by: Name <email>`) to a draft commit message
/// through `git interpret-trailers`, so git's own rules decide where the
/// trailer block is and whether one already exists (guide §11 decision 45).
public enum MessageTrailers {

    /// `message` with `trailer` at the end of its trailer block, or in a new
    /// block after a blank line. A trailer already present is not added
    /// twice. A blank `message` gives `"\n\n<trailer>\n"`: the subject line
    /// stays empty for the user to type, and the blank line keeps the
    /// trailer out of it — `git interpret-trailers` alone gives
    /// `"\n<trailer>\n"`, and a subject typed on that first line would join
    /// the trailer's paragraph (measured).
    ///
    /// Every placement option is passed explicitly, so `trailer.where`,
    /// `trailer.ifexists` and `trailer.ifmissing` in the user's config
    /// cannot move or drop it (`trailer.ifmissing=doNothing` drops it,
    /// measured). `--no-divider`: a commit message is not a patch, so a
    /// `---` line in it is text, not the end of the message.
    public static func adding(
        _ trailer: String,
        to message: String,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> String {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\n\n\(trailer)\n"
        }
        return try git.run(
            ["interpret-trailers", "--no-divider", "--where", "end",
             "--if-exists", "addIfDifferent", "--if-missing", "add", "--trailer", trailer],
            workingDirectory: path, standardInput: Data(message.utf8),
            extraEnvironment: extraEnvironment
        ).text
    }
}
