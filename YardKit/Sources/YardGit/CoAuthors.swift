// CoAuthors.swift — who a commit can credit with a Co-authored-by trailer (#0559)

import Foundation

/// The people the Changes view's Co-Author menu offers (guide §11 decision
/// 45): the authors of `HEAD`'s recent history and the co-authors those
/// commits already credit, most recent first, each once, without the
/// current user.
public enum CoAuthors {

    /// One person, as a `Co-authored-by` trailer names them.
    public struct Person: Equatable, Hashable, Sendable {
        public let name: String
        public let email: String

        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }

        /// `Name <email>`: the trailer's value and the menu item's title.
        public var identity: String { "\(name) <\(email)>" }

        /// The whole trailer line.
        public var trailer: String { "Co-authored-by: \(identity)" }
    }

    /// How many commits back `recent` reads. 0.06 s on git/git (measured).
    public static let scannedCommits = 500

    /// The people to offer, at most `limit`. Empty on an unborn branch.
    ///
    /// One `git log` over `HEAD`: `%aN`/`%aE` (so `.mailmap` applies) and
    /// every `Co-authored-by` value (`%(trailers:…)`, key matched without
    /// regard to case). People are the same when their emails match without
    /// regard to case; the first spelling seen wins. `user.email` is left
    /// out: nobody credits themselves.
    public static func recent(
        at path: String,
        limit: Int = 20,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> [Person] {
        let head = try git.capture(
            ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        guard head.exitCode == 0 else { return [] }
        let log = try git.run(
            ["log", "-n", "\(scannedCommits)", "--no-show-signature",
             "--format=%aN%x00%aE%x00%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x01)%x1e",
             "HEAD", "--"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).text
        // `git config` exits 1 when user.email is unset: nobody to leave out.
        let me = try git.capture(
            ["config", "user.email"], workingDirectory: path, extraEnvironment: extraEnvironment
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return parse(log, excluding: me, limit: limit)
    }

    /// `recent`'s parser: records end in U+001E (git puts a newline between
    /// them), fields are split by NUL, co-authors by U+0001.
    static func parse(_ log: String, excluding email: String, limit: Int) -> [Person] {
        var seen: Set<String> = [email.lowercased()]
        var people: [Person] = []
        func add(_ person: Person) {
            guard people.count < limit, !person.email.isEmpty,
                  seen.insert(person.email.lowercased()).inserted else { return }
            people.append(person)
        }
        for record in log.split(separator: "\u{1E}") {
            let fields = record.drop { $0 == "\n" }.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            add(Person(name: String(fields[0]), email: String(fields[1])))
            for value in fields[2].split(separator: "\u{01}") {
                if let person = identity(String(value)) { add(person) }
            }
        }
        return people
    }

    /// `Name <email>` → a person; `nil` for any other shape.
    static func identity(_ value: String) -> Person? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(">"), let open = value.lastIndex(of: "<") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        let email = value[value.index(after: open)..<value.index(before: value.endIndex)]
        guard !name.isEmpty, !email.isEmpty else { return nil }
        return Person(name: name, email: String(email))
    }
}
