// EngineServingSupport.swift — helpers for the guide §11 decision 37 arm
// tests: run an arm, decode its envelope, read git state, count journal
// entries.

import Foundation
import Testing
import YardGit
import YardKit
@testable import YardCommands

/// Runs `arguments` through `runEngineCommand`, failing loudly when no arm
/// claims them — a nil here would make every later assertion vacuous.
func runArm(_ arguments: [String], in directory: String) throws -> EngineReply {
    try #require(runEngineCommand(arguments: arguments, workingDirectory: directory),
                 "no engine arm claimed \(arguments)")
}

/// The reply's stdout as a JSON object, failing loudly when it is not one.
func envelope(_ reply: EngineReply) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8))
    return try #require(object as? [String: Any], "stdout must be a JSON object: \(reply.stdout)")
}

/// The success payload, failing loudly when the envelope is not `ok: true`.
func payload(_ reply: EngineReply) throws -> [String: Any] {
    let object = try envelope(reply)
    #expect(object["ok"] as? Bool == true, "expected ok:true, got \(reply.stdout)")
    return try #require(object["result"] as? [String: Any], "no result in \(reply.stdout)")
}

/// The failure envelope's `error.code`.
func errorCode(_ reply: EngineReply) throws -> String {
    let object = try envelope(reply)
    #expect(object["ok"] as? Bool == false, "expected ok:false, got \(reply.stdout)")
    let error = try #require(object["error"] as? [String: Any])
    return try #require(error["code"] as? String)
}

/// `git <arguments>` in `directory`, stdout trimmed of its final newline.
@discardableResult
func git(_ arguments: [String], in directory: String) throws -> String {
    var text = try GitProcess().run(arguments, workingDirectory: directory).text
    while text.hasSuffix("\n") { text.removeLast() }
    return text
}

/// How many journal entries the repository holds.
func journalCount(in directory: String) throws -> Int {
    try git(["for-each-ref", "--format=%(refname)", ServiceNames.journalRefPrefix], in: directory)
        .split(separator: "\n").count
}

/// A fresh empty directory that is not a repository — where every usage
/// refusal must hold, because the refusal precedes any repository access.
func nonRepositoryDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("yard-arm-non-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// Writes `contents` to `path` inside `repo`, creating directories.
func write(_ contents: String, to path: String, in repo: FixtureRepository) throws {
    try repo.writeUntracked([path: contents])
}
