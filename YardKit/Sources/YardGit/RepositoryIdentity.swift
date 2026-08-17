// RepositoryIdentity.swift — a durable, opaque repository identity (#0149)

import Foundation

/// A repository's durable identity: an opaque id stored **inside** the
/// repository, at `<commonDir>/switchyard/repository-id`.
///
/// It lives in the repository because that is the only store that moves with
/// it. A path-keyed registry cannot tell "moved" from "deleted, plus an
/// unrelated new repository at the same path"; an id the repository carries
/// along can. #0029's registry consumes it as a plain `String`, so neither
/// package imports the other.
public enum RepositoryIdentity {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unreadable(path: String, detail: String)
        case unwritable(path: String, detail: String)

        public var description: String {
            switch self {
            case let .unreadable(path, detail):
                "cannot read the repository id at \(path): \(detail)"
            case let .unwritable(path, detail):
                "cannot write the repository id at \(path): \(detail)"
            }
        }
    }

    /// The id for this repository, creating one on first call.
    ///
    /// **A malformed or empty file is replaced, not reported.** The id is
    /// opaque and carries no information, so regenerating loses nothing except
    /// the link to registry rows that referenced the old value -- and a
    /// truncated id would break that link anyway while looking valid. The
    /// alternative, failing, would make every command in the repository fail
    /// on a one-byte corruption in a file nothing else needs.
    public static func resolve(
        in context: WorktreeContext,
        uuid: () -> String = { UUID().uuidString }
    ) throws -> String {
        let fm = FileManager.default
        let directory = RepositoryLayout.stateDirectory(in: context)
        let path = context.commonDir + "/" + RepositoryLayout.repositoryIDRelativePath

        // Shared by the initial read and the post-write race check below, so
        // both apply the identical validity rule: non-empty, decodable UTF-8.
        func readValidID() -> String? {
            guard let data = fm.contents(atPath: path),
                  let existing = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !existing.isEmpty
            else { return nil }
            return existing
        }

        if let existing = readValidID() {
            return existing
        }

        let generated = uuid()
        do {
            try fm.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Written to a staging file and renamed into place: two
            // invocations in different worktrees can reach this line at once,
            // and a rename is the only step that cannot interleave.
            let staging = path + ".\(ProcessInfo.processInfo.processIdentifier)"
            try Data(generated.utf8).write(to: URL(fileURLWithPath: staging))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging)
            // Someone may have won the race and written a VALID id while we
            // were generating ours -- defer to it. A file that merely EXISTS
            // at `path` is not necessarily a winner: it may be the same
            // malformed/empty file that failed `readValidID()` above (nothing
            // deleted it), and looping on that would recurse forever. Only a
            // file that now reads back valid counts as "someone else won".
            if let winner = readValidID() {
                try? fm.removeItem(atPath: staging)
                return winner
            }
            // Nothing valid is there -- replace whatever is (a stale/empty
            // file, or nothing at all). `moveItem` refuses when the
            // destination exists, so clear it first.
            _ = try? fm.removeItem(atPath: path)
            try fm.moveItem(atPath: staging, toPath: path)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.unwritable(path: path, detail: String(describing: error))
        }
        return generated
    }
}
