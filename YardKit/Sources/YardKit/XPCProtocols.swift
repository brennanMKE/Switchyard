// XPCProtocols.swift
//
// Ported from ../../RemoteControl/BridgeKit/Sources/BridgeKit/XPCProtocols.swift
// and ../../RemoteControl/BrokerAgent/main.swift (MIT, same author — see
// CLAUDE.md and issue #0046's planning update). Copyright the original
// author; substantial portions retained here under the same MIT terms as
// this project.

import Foundation

// MARK: - Broker

/// What the broker launch agent exposes on its mach service.
///
/// The agent is a bootstrap broker and nothing more: it holds the app's
/// anonymous listener endpoint so a CLI can find it. Once the CLI has the
/// endpoint, traffic goes directly to the app and the agent is out of the
/// path.
@objc public protocol BrokerProtocol {
    /// Liveness check that does not depend on the app running at all.
    ///
    /// This is the acceptance probe for #0048: it should succeed when
    /// launchd starts the agent on demand, with the app never having been
    /// launched.
    func brokerPing(reply: @escaping @Sendable (String) -> Void)

    /// Called by the app after it creates its anonymous listener.
    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint)

    /// Called by the CLI. Replies `nil` when no app has registered.
    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

/// What the app exposes to a CLI over the direct connection.
///
/// `appPing` is a liveness check; `perform` is the real wire — argv in, a
/// rendered envelope out. See guide §11 decision 15 for why the shape is
/// argv-in/envelope-out rather than a typed request/response per command:
/// this needs no per-command payload schema, so a new CLI command is not a
/// protocol change. Session state (`startSession` and friends) is #0213,
/// deliberately after this.
@objc public protocol AppServiceProtocol {
    /// Liveness check on the app itself, distinct from `brokerPing`: this one
    /// only answers when the direct connection is live.
    func appPing(reply: @escaping @Sendable (String) -> Void)

    /// Runs a CLI invocation and replies with exactly what the CLI should
    /// write to stdout, and the process exit code.
    ///
    /// - Parameters:
    ///   - arguments: `CommandLine.arguments` after the executable name —
    ///     the same array `runYard(arguments:)` takes.
    ///   - workingDirectory: the CLI process's working directory, explicit
    ///     and never inferred. The app's own working directory is meaningless
    ///     to a CLI invoked in some other repository, and passing it is what
    ///     lets one running app serve CLIs in many repositories at once
    ///     (guide §11 decision 15). Unused for now — `runYard` does not take
    ///     a working directory yet; wiring an engine-backed command that
    ///     needs it is #0124.
    ///   - reply: `Data` is the JSON envelope exactly as the CLI must print
    ///     it — `NSXPCInterface` cannot carry a Swift `String` with
    ///     guaranteed encoding fidelity across the boundary the way `Data`
    ///     does, and the CLI parses none of it. `Int32` is the exit code —
    ///     `ExitCode` is `Int`-backed, so `NSXPCInterface` (which will not
    ///     carry a Swift enum) needs an explicit `Int32` conversion on both
    ///     sides. This signature carries no `stderr`: it is pinned exactly
    ///     as guide §11 decision 15 states it, and `runYard`'s stderr text is
    ///     always a human-readable duplicate of information already present
    ///     in the stdout envelope's `error` object, so nothing is lost by
    ///     not carrying it separately over this wire.
    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    )

    /// Runs one `reference-transaction` hook invocation app-side (#0154).
    ///
    /// A separate method rather than a `perform` argument because the wire
    /// needs bytes this shape cannot carry as argv: the hook's stdin and its
    /// environment. The app-side body is `runReferenceTransactionHook` in
    /// `YardCommands` (the decision core, `ReferenceTransaction.decide`,
    /// lives in `YardGit`, which the CLI does not link).
    ///
    /// - Parameters:
    ///   - state: the hook's state argument, verbatim — `prepared`,
    ///     `committed`, `aborted`, or anything a future git adds. The
    ///     decision core re-derives every gate from it; the CLI's own gate
    ///     only decides whether stdin was worth draining.
    ///   - environment: the hook process's environment, shipped whole — the
    ///     decision core looks up its own marker variable in it. Property-
    ///     list-safe: `NSXPCInterface` carries `[String: String]` as an
    ///     `NSDictionary` of strings.
    ///   - standardInput: the hook's stdin bytes, already drained by the
    ///     CLI. The decision core re-derives whether stdin was worth reading
    ///     (own `committed` transactions skip it), so the CLI gating first
    ///     never drops data the core would have wanted.
    ///   - workingDirectory: the hook process's cwd — the invoking worktree's
    ///     top, per #0041's script. The app resolves the repository from it.
    ///   - reply: the process exit code the decision produced — always 0 by
    ///     #0042's totality invariant. The CLI arm exits 0 regardless, so a
    ///     future non-total reply still cannot abort a user's transaction.
    func performReferenceTransactionHook(
        state: String,
        environment: [String: String],
        standardInput: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Int32) -> Void
    )

    /// Opens a review request the human answers in the app (#0055).
    ///
    /// A separate method rather than a `perform` invocation because the call
    /// does not round-trip like a command: it stays open for minutes while
    /// the human decides, and its reply bytes are a ``ReviewOutcome`` — the
    /// typed answer, including "nobody answered" and "a newer request
    /// replaced this one" — not a rendered envelope. The exit-code mapping
    /// from outcome to process exit is the review arm's own policy
    /// (`ReviewArm.render`), the way `perform`'s mapping is the envelope's.
    ///
    /// - Parameters:
    ///   - request: the JSON-encoded ``ReviewRequest``. The CLI cannot
    ///     resolve the repository (it does not link the engine), so it sends
    ///     the request with `commonDir` empty.
    ///   - workingDirectory: the CLI process's working directory, explicit
    ///     and never inferred — the same rule as `perform`. The app-side body
    ///     (`runReviewRequest` in `YardCommands`) resolves the repository
    ///     from it and fills the request's `commonDir` before registering.
    ///   - reply: the JSON-encoded ``ReviewOutcome`` — decided, timedOut, or
    ///     superseded — or a JSON-encoded `EnvelopeFail` when the request
    ///     could not be served at all (undecodable bytes, no repository).
    ///     `Data` because `NSXPCInterface` carries no Swift struct with
    ///     guaranteed fidelity across the boundary; the reply block may be
    ///     called long after this method returns — that is the point.
    func performReview(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    )
}

/// `NSXPCInterface` values for ``BrokerProtocol`` and ``AppServiceProtocol``.
///
/// Both sides of a connection must configure `remoteObjectInterface` and
/// `exportedInterface` with matching interfaces *before* calling `resume()`.
/// Get it wrong and calls fail silently — no error, no reply, no crash. This
/// factory is the cheapest available defense against that.
public enum XPCInterfaces {
    public static var broker: NSXPCInterface {
        NSXPCInterface(with: BrokerProtocol.self)
    }

    public static var appService: NSXPCInterface {
        NSXPCInterface(with: AppServiceProtocol.self)
    }
}

// MARK: - Endpoint registry

/// Holds the most recently registered value, tracking which owner registered
/// it so only that owner can clear it.
///
/// Generic over both the stored value and the owner token so the type has no
/// dependency on XPC and is testable without a live connection. The broker
/// instantiates this as `EndpointRegistry<NSXPCListenerEndpoint>`, minting an
/// ``Owner`` per connection.
///
/// Guarded by a lock, not an actor: XPC invokes each connection's methods on
/// its own queue, so this is reachable from several queues concurrently, and
/// the `@objc` protocol methods it backs are synchronous — an actor would
/// force every accessor to be `async`, which `@objc` will not express.
public final class EndpointRegistry<Value: Sendable>: @unchecked Sendable {

    /// Identifies the party that registered a value, so a later `clear(owner:)`
    /// from a different party is rejected rather than silently discarding a
    /// live registration.
    public struct Owner: Hashable, Sendable {
        private let id = UUID()

        public init() {}
    }

    private let lock = NSLock()
    private var value: Value?
    private var owner: Owner?

    public init() {}

    /// The currently registered value, or `nil` if nothing has registered.
    public var current: Value? {
        lock.withLock { value }
    }

    /// Stores `newValue` and records `owner` as the party that registered it.
    /// A later `store` from a different owner replaces both the value and the
    /// owner — the registry only ever holds one registration.
    public func store(_ newValue: Value, owner: Owner) {
        lock.withLock {
            value = newValue
            self.owner = owner
        }
    }

    /// Clears the registration if `owner` is the party that registered it.
    ///
    /// Returns whether the clear happened. A CLI connection invalidating must
    /// not be able to discard a live app registration, so a clear from any
    /// owner other than the registering one is rejected rather than applied.
    @discardableResult
    public func clear(owner: Owner) -> Bool {
        lock.withLock {
            guard self.owner == owner else { return false }
            value = nil
            self.owner = nil
            return true
        }
    }
}
