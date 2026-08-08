// JournalLock.swift — cross-process serialisation of journal writes (#0032)

import Foundation

/// Why a journal write could not take the lock.
public enum JournalLockError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Another process held the lock for the whole timeout. Carries the lock
    /// path so the message can name the repository, and the timeout that
    /// expired so a caller can distinguish "contended" from "misconfigured".
    case timedOut(path: String, timeout: Duration)
    /// The lock file could not be created or locked for a reason other than
    /// contention — permissions, a read-only filesystem, a deleted common dir.
    case ioFailure(path: String, operation: String, errno: Int32)

    public var description: String {
        switch self {
        case let .timedOut(path, timeout):
            return "journal lock at \(path) held by another process for \(timeout)"
        case let .ioFailure(path, operation, code):
            let detail = String(cString: strerror(code))
            return "journal lock \(operation) failed at \(path): \(detail) (errno \(code))"
        }
    }
}

/// Serialises journal writes across processes for one repository.
///
/// **What it serialises:** the journal's compound write — snapshot objects,
/// anchor ref, and the read-modify-write of `.git/switchyard/journal.json`
/// (#0027, #0028). Git already serialises its own ref writes (`update-ref`
/// takes a per-ref lock), and each entry's anchor ref has a unique name, so
/// refs need nothing from us. The metadata file is what git does not protect:
/// two concurrent read-modify-write cycles with atomic replace lose entries —
/// measured, 25 of 50 survive — because `.atomic` protects *readers* from
/// torn files, not *writers* from each other.
///
/// **The primitive is `flock(2)`, and stale locks therefore cannot exist.**
/// The kernel ties the lock to the open file description and releases it when
/// the last descriptor closes — including on `SIGKILL` and crashes. There is
/// no PID file, no liveness probe, and no recovery path, because there is no
/// state to go stale. The lock *file* is only an inode to lock: its presence
/// on disk means nothing, and it is deliberately **never unlinked** —
/// unlink-and-recreate lets a late waiter lock the old unlinked inode while a
/// newcomer locks the new file, and both then believe they hold the lock.
///
/// **The lock is per-repository, not per-worktree.** The journal lives in the
/// common dir, so the lock file is `<commonDir>/switchyard/journal.lock`,
/// resolved from `WorktreeContext.commonDir`. This is one of the two places
/// where building the path ourselves is correct rather than lazy:
/// `git rev-parse --git-path switchyard/journal.lock` resolves to the
/// **per-worktree** `$GIT_DIR/worktrees/<name>/switchyard/…` in a linked
/// worktree (measured on git 2.50.1), which would give every worktree its own
/// lock and serialise nothing. `switchyard/` is our directory, not git state;
/// the `$GIT_DIR` rule is about reading git's files, and this reads none.
public struct JournalLock: Sendable {

    /// Lock file name inside `<commonDir>/switchyard/`.
    public static let fileName = "journal.lock"

    /// How long to wait between acquisition attempts, in microseconds.
    static let pollIntervalMicroseconds: UInt32 = 10_000

    /// Absolute path of the lock file: `<commonDir>/switchyard/journal.lock`.
    public let lockFilePath: String

    /// The lock for the repository the context belongs to. Two contexts with
    /// the same `commonDir` — the main worktree and every linked worktree —
    /// resolve the same lock file.
    public init(context: WorktreeContext) {
        self.lockFilePath = context.commonDir + "/switchyard/" + Self.fileName
    }

    /// Runs `body` while holding the repository's exclusive journal lock,
    /// releasing it on both return and throw.
    ///
    /// Acquisition polls `flock(LOCK_EX | LOCK_NB)` every 10ms until the
    /// deadline, then throws `JournalLockError.timedOut` — it never blocks
    /// indefinitely, because nothing agent-facing may hang (guide §6). The
    /// default gives a journal write orders of magnitude more time than it
    /// needs; callers with a caller-supplied budget pass their own.
    public func withLock<T>(
        timeout: Duration = .seconds(10),
        _ body: () throws -> T
    ) throws -> T {
        let fd = try acquire(timeout: timeout)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    // MARK: - Acquisition

    private func acquire(timeout: Duration) throws -> Int32 {
        try ensureDirectory()
        // O_CLOEXEC so processes the engine spawns while holding the lock
        // (every GitProcess call) do not inherit the descriptor — an inherited
        // fd would keep the lock alive after we die, exactly the stale-lock
        // failure flock otherwise makes impossible.
        let fd = open(lockFilePath, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw JournalLockError.ioFailure(
                path: lockFilePath, operation: "open", errno: errno)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw JournalLockError.ioFailure(
                    path: lockFilePath, operation: "flock", errno: code)
            }
            guard clock.now < deadline else {
                close(fd)
                throw JournalLockError.timedOut(path: lockFilePath, timeout: timeout)
            }
            usleep(Self.pollIntervalMicroseconds)
        }
    }

    /// Creates `<commonDir>/switchyard/` if needed. Default permissions: the
    /// directory sits inside `.git`, whose permissions are the user's policy.
    private func ensureDirectory() throws {
        let directory = (lockFilePath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw JournalLockError.ioFailure(
                path: directory, operation: "mkdir", errno: Int32((error as NSError).code))
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Both cases are repository-state failures — guide §6 code 6. A held lock
/// means the repository's journal is busy with another process's write;
/// an ioFailure means the repository's `.git` cannot hold the lock file.
/// Neither is conflicts (8) nor signing (9), the engine's only other codes.
extension JournalLockError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
