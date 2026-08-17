import YardKit

/// Runs a command that needs the engine, returning the rendered envelope and
/// the exit code — the same pair `runYard` returns, so the app can try this
/// first and fall back to `runYard` for the commands that need no repository.
///
/// Returning `nil` means "not one of mine": it is what lets the app compose
/// this with `runYard` without either side enumerating the other's commands.
/// There are no engine arms yet, so this returns `nil` for every input — see
/// #0124, which is where the first arm lands.
public func runEngineCommand(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode)? {
    nil
}
