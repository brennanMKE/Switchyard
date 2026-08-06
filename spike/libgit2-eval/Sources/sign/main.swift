// SPIKE — throwaway. Deleted by #0005.
//
// #0002: can we produce an SSH-signed commit through libgit2 that git reports
// as verified?
//
// Shape under test:
//   1. git_commit_create_buffer  — build the commit content
//   2. ssh-keygen -Y sign        — sign that buffer externally (libgit2 does
//                                  not produce signatures, only attaches them)
//   3. git_commit_create_with_signature — write it, header field "gpgsig"
//      (git stores SSH signatures under the same header as GPG)
//
// Everything runs against a throwaway repo and a throwaway key in a temp dir.
// The user's real git config and ~/.ssh are never touched.

import Clibgit2
import Foundation

@MainActor
func run(_ launch: String, _ args: [String], cwd: String? = nil,
         stdin: String? = nil) -> (out: String, err: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    if let stdin {
        let inPipe = Pipe()
        p.standardInput = inPipe
        try? p.run()
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    } else {
        try? p.run()
    }
    let o = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (o, e, p.terminationStatus)
}

func lastError() -> String {
    guard let e = git_error_last(), let m = e.pointee.message else { return "unknown" }
    return String(cString: m)
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: sign <workdir>"); exit(2) }
let work = args[1]
let repoPath = "\(work)/repo"
let keyPath = "\(work)/id_test"

var failed = 0
@MainActor func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if !ok { failed += 1 }
    print("  [\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
}

// --- set up throwaway key and repo --------------------------------------
try? FileManager.default.removeItem(atPath: work)
try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)

let keygen = run("/usr/bin/ssh-keygen", ["-t", "ed25519", "-f", keyPath, "-N", "", "-C", "spike@test", "-q"])
check("generate throwaway ed25519 key", keygen.code == 0, keygen.err.trimmingCharacters(in: .whitespacesAndNewlines))

_ = run("/usr/bin/git", ["init", "-q", repoPath])
_ = run("/usr/bin/git", ["-C", repoPath, "config", "user.name", "Spike"])
_ = run("/usr/bin/git", ["-C", repoPath, "config", "user.email", "spike@test"])
FileManager.default.createFile(atPath: "\(repoPath)/file.txt", contents: "hello\n".data(using: .utf8))
_ = run("/usr/bin/git", ["-C", repoPath, "add", "-A"])
_ = run("/usr/bin/git", ["-C", repoPath, "commit", "-q", "-m", "base"])

git_libgit2_init()
defer { git_libgit2_shutdown() }

var repo: OpaquePointer?
guard git_repository_open(&repo, repoPath) == 0, let repo else {
    print("cannot open spike repo"); exit(1)
}
defer { git_repository_free(repo) }

// --- build the commit buffer --------------------------------------------
var headOid = git_oid()
_ = git_reference_name_to_id(&headOid, repo, "HEAD")
var parent: OpaquePointer?
_ = git_commit_lookup(&parent, repo, &headOid)

var treeOid = git_oid()
var index: OpaquePointer?
_ = git_repository_index(&index, repo)
_ = git_index_write_tree(&treeOid, index)
var tree: OpaquePointer?
_ = git_tree_lookup(&tree, repo, &treeOid)

var sig: UnsafeMutablePointer<git_signature>?
_ = git_signature_now(&sig, "Spike", "spike@test")

var buf = git_buf()
var parents: [OpaquePointer?] = [parent]
let bufRC = parents.withUnsafeMutableBufferPointer { pp -> Int32 in
    git_commit_create_buffer(&buf, repo, sig, sig, nil,
                             "signed via libgit2 spike\n", tree, 1,
                             pp.baseAddress)
}
let content = bufRC == 0 ? String(cString: buf.ptr) : ""
check("git_commit_create_buffer", bufRC == 0 && !content.isEmpty,
      bufRC == 0 ? "\(content.utf8.count) bytes" : lastError())

// --- sign the buffer with ssh-keygen ------------------------------------
let payloadPath = "\(work)/payload"
try? content.write(toFile: payloadPath, atomically: true, encoding: .utf8)
let signRC = run("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", keyPath, "-n", "git", payloadPath])
let sigText = (try? String(contentsOfFile: "\(payloadPath).sig", encoding: .utf8)) ?? ""
check("ssh-keygen -Y sign", signRC.code == 0 && sigText.contains("SSH SIGNATURE"),
      signRC.code == 0 ? "\(sigText.utf8.count) bytes" : signRC.err.trimmingCharacters(in: .whitespacesAndNewlines))

// --- attach it -----------------------------------------------------------
var signedOid = git_oid()
let attachRC = git_commit_create_with_signature(&signedOid, repo, content, sigText, "gpgsig")
var shortOid = ""
if attachRC == 0 {
    var b = [CChar](repeating: 0, count: 41)
    git_oid_fmt(&b, &signedOid)
    shortOid = String(cString: b)
}
check("git_commit_create_with_signature", attachRC == 0,
      attachRC == 0 ? String(shortOid.prefix(10)) : lastError())

// Move HEAD to the signed commit so git can inspect it.
if attachRC == 0 {
    _ = run("/usr/bin/git", ["-C", repoPath, "reset", "--hard", shortOid, "-q"])
}

// --- verify with git -----------------------------------------------------
// git needs an allowed-signers file to call an SSH signature "good".
let pub = (try? String(contentsOfFile: "\(keyPath).pub", encoding: .utf8)) ?? ""
let allowed = "spike@test \(pub)"
try? allowed.write(toFile: "\(work)/allowed_signers", atomically: true, encoding: .utf8)
_ = run("/usr/bin/git", ["-C", repoPath, "config", "gpg.ssh.allowedSignersFile", "\(work)/allowed_signers"])
_ = run("/usr/bin/git", ["-C", repoPath, "config", "gpg.format", "ssh"])

let show = run("/usr/bin/git", ["-C", repoPath, "log", "--show-signature", "-1"])
let combined = show.out + show.err
let goodSig = combined.contains("Good \"git\" signature")
check("git log --show-signature reports Good", goodSig,
      combined.split(separator: "\n").first { $0.contains("signature") }.map(String.init) ?? "no signature line")

// --- verify the raw round trip with ssh-keygen ---------------------------
let verify = run("/usr/bin/ssh-keygen",
                 ["-Y", "verify", "-f", "\(work)/allowed_signers",
                  "-I", "spike@test", "-n", "git", "-s", "\(payloadPath).sig"],
                 stdin: content)
check("ssh-keygen -Y verify round trip", verify.code == 0,
      verify.code == 0 ? "verified" : (verify.err + verify.out).trimmingCharacters(in: .whitespacesAndNewlines))

// --- confirm the header actually landed ----------------------------------
let raw = run("/usr/bin/git", ["-C", repoPath, "cat-file", "-p", "HEAD"])
check("commit object carries gpgsig header", raw.out.contains("gpgsig"),
      raw.out.contains("gpgsig") ? "present" : "absent")

print(failed == 0 ? "  ALL PROBES PASSED" : "  \(failed) PROBE(S) FAILED")
exit(failed == 0 ? 0 : 1)
