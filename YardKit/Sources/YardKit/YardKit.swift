// YardKit.swift

/// Shared surface between the app, the broker agent, and the CLI.
///
/// Everything worth testing lives here rather than in the app target: XPC
/// protocols and message types, `ServiceNames`, and the CLI installer. The app
/// target owns only SwiftUI views, agent embedding, `SMAppService`
/// registration, and the presentation of results.
public enum YardKit {
    /// Package version, distinct from the app's marketing version.
    public static let version = "0.0.1"
}
