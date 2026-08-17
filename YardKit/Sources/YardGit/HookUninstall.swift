// HookUninstall.swift — reverse `hooks install`, restoring any chained hook

import Foundation

/// Reverses `HookInstall`: removes the wrapper scripts and puts any
/// chained-aside previous hook back under its original name, byte-for-byte
/// and mode-for-mode — rename is what chained it and rename is what restores
/// it.
public enum HookUninstall {

    public struct Report: Sendable, Equatable {
        public let hook: ObservedHook
        public let outcome: Outcome

        public init(hook: ObservedHook, outcome: Outcome) {
            self.hook = hook
            self.outcome = outcome
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Our script was removed; nothing had been chained.
        case removed
        /// The previously chained hook is back at its original name. Our
        /// script, when present, was removed first — and when it was not
        /// present (someone deleted the wrapper by hand), restoring the
        /// backup is still the right repair.
        case restored
        /// Neither our script nor a chained backup exists.
        case notInstalled
        /// The hook present is not ours and is left untouched. When a
        /// chained backup also exists it is retained rather than clobbering
        /// the foreign hook, and `backupRetained` says so.
        case foreignLeftInPlace(backupRetained: Bool)
        /// A filesystem operation failed.
        case failed(String)
    }

    /// Uninstalls every `ObservedHook`. Per-hook problems are reported,
    /// never thrown. Throws `HookInstall.Failure.hooksPathManaged` when
    /// `core.hooksPath` is set, symmetric with install: install never wrote
    /// under an override (and there is no per-invocation way to resolve the
    /// unmanaged directory — `git -c core.hooksPath= rev-parse --git-path
    /// hooks` is `fatal: The empty string is not a valid path`, measured),
    /// and `hooks status` reports the override so the situation is visible.
    @discardableResult
    public static func run(
        context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [Report] {
        let location = try HookInstall.location(context: context, git: git)
        if let managed = location.managedPath {
            throw HookInstall.Failure.hooksPathManaged(path: managed)
        }
        return ObservedHook.allCases.map { uninstall($0, in: location.directory) }
    }

    static func uninstall(_ hook: ObservedHook, in directory: String) -> Report {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: directory)
        let url = base.appendingPathComponent(hook.rawValue)
        let backup = base.appendingPathComponent(hook.rawValue + HookInstall.chainedSuffix)

        let hookPresent = (try? fm.attributesOfItem(atPath: url.path)) != nil
        let backupPresent = (try? fm.attributesOfItem(atPath: backup.path)) != nil

        do {
            if hookPresent {
                let existing = (try? Data(contentsOf: url)) ?? Data()
                guard HookInstall.isOurs(existing) else {
                    return Report(
                        hook: hook,
                        outcome: .foreignLeftInPlace(backupRetained: backupPresent))
                }
            }
            if backupPresent {
                if hookPresent {
                    // One step, not two. Removing the wrapper and then moving
                    // the user's hook back leaves the path empty in between,
                    // and loses their hook outright if the move fails.
                    _ = try fm.replaceItemAt(url, withItemAt: backup,
                                             options: .usingNewMetadataOnly)
                } else {
                    try fm.moveItem(at: backup, to: url)
                }
                return Report(hook: hook, outcome: .restored)
            }
            if hookPresent { try fm.removeItem(at: url) }
            return Report(hook: hook, outcome: hookPresent ? .removed : .notInstalled)
        } catch {
            return Report(hook: hook, outcome: .failed(String(describing: error)))
        }
    }
}

// MARK: - Wire encoding

extension HookUninstall.Report: Encodable {
    private enum CodingKeys: String, CodingKey {
        case hook, outcome
    }
}

/// Same frame as `HookInstall.Outcome`: `{"code": …}` plus per-case detail.
extension HookUninstall.Outcome: Encodable {
    private enum CodingKeys: String, CodingKey {
        case code
        case backupRetained
        case detail
    }

    private var wireCode: String {
        switch self {
        case .removed: "removed"
        case .restored: "restored"
        case .notInstalled: "notInstalled"
        case .foreignLeftInPlace: "foreignLeftInPlace"
        case .failed: "failed"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireCode, forKey: .code)
        switch self {
        case let .foreignLeftInPlace(backupRetained):
            try container.encode(backupRetained, forKey: .backupRetained)
        case let .failed(detail):
            try container.encode(detail, forKey: .detail)
        case .removed, .restored, .notInstalled:
            break
        }
    }
}
