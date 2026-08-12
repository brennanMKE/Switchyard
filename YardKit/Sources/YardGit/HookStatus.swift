// HookStatus.swift — report what is actually installed, per observed hook

import Foundation

/// Reports the state of every `ObservedHook` in the *effective* hooks
/// directory — the one git actually runs from. Unlike install and uninstall,
/// a managed `core.hooksPath` is not a refusal here: status inspects the
/// managed directory and reports the override, because "what would actually
/// fire" is the question status answers.
public enum HookStatus {

    public enum State: String, Sendable, Codable, Equatable {
        /// No hook file at this name.
        case absent
        /// Ours, byte-identical to the script this engine writes.
        case installed
        /// Ours by marker, but not the current script — an older version,
        /// or hand-edited. `hooks install` refreshes it.
        case stale
        /// Present and not ours. Install would chain it, not clobber it.
        case foreign
    }

    public struct Entry: Sendable, Equatable {
        public let hook: ObservedHook
        public let state: State
        /// False when a present hook lacks the executable bit — git ignores
        /// it entirely (measured: `hint: … ignored because it's not set as
        /// executable`). Always false when absent.
        public let executable: Bool
        /// A chained-aside previous hook sits beside the wrapper. True with
        /// `state != .installed` means uninstall has a restore to do that
        /// install did not leave behind — worth surfacing.
        public let chainedPresent: Bool

        public init(hook: ObservedHook, state: State, executable: Bool, chainedPresent: Bool) {
            self.hook = hook
            self.state = state
            self.executable = executable
            self.chainedPresent = chainedPresent
        }
    }

    public struct Summary: Sendable, Equatable {
        /// The effective hooks directory, absolute.
        public let directory: String
        /// `core.hooksPath` when set — `entries` then describe the managed
        /// directory, and install/uninstall will refuse to touch it.
        public let managedPath: String?
        /// One entry per `ObservedHook`, in `allCases` order.
        public let entries: [Entry]

        public init(directory: String, managedPath: String?, entries: [Entry]) {
            self.directory = directory
            self.managedPath = managedPath
            self.entries = entries
        }
    }

    public static func run(
        context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Summary {
        let location = try HookInstall.location(context: context, git: git)
        let entries = ObservedHook.allCases.map { inspect($0, in: location.directory) }
        return Summary(
            directory: location.directory,
            managedPath: location.managedPath,
            entries: entries)
    }

    static func inspect(_ hook: ObservedHook, in directory: String) -> Entry {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: directory)
        let url = base.appendingPathComponent(hook.rawValue)
        let backup = base.appendingPathComponent(hook.rawValue + HookInstall.chainedSuffix)

        let backupPresent = (try? fm.attributesOfItem(atPath: backup.path)) != nil
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else {
            return Entry(hook: hook, state: .absent, executable: false,
                         chainedPresent: backupPresent)
        }

        let content = (try? Data(contentsOf: url)) ?? Data()
        let state: State
        if HookInstall.isOurs(content) {
            state = content == Data(HookInstall.script(for: hook).utf8)
                ? .installed : .stale
        } else {
            state = .foreign
        }
        return Entry(hook: hook, state: state,
                     executable: fm.isExecutableFile(atPath: url.path),
                     chainedPresent: backupPresent)
    }
}

// MARK: - Wire encoding

/// `Summary` is the whole `result` payload of `switchyard hooks status`.
/// Stable keys pinned; `ObservedHook` and `State` encode as their raw
/// strings.
extension HookStatus.Summary: Encodable {
    private enum CodingKeys: String, CodingKey {
        case directory, managedPath, entries
    }
}

extension HookStatus.Entry: Encodable {
    private enum CodingKeys: String, CodingKey {
        case hook, state, executable, chainedPresent
    }
}
