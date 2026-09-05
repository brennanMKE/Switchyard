// ResolveApplyMapping.swift — the wire choice's engine apply (#0057 round 2)
//
// The boundary between the wire's `PathChoice` (YardKit) and the engine's
// `ResolveResolution` (YardGit): YardGit links neither wire type, so the
// mapping lives here in YardCommands, where both sides of the boundary are
// visible. The resolve pane's apply seam (YardUI) is wired through this by
// the app target's bridge — one checkpointed action per path, never a
// second apply implementation.

import Foundation
import YardGit
import YardKit

public enum ResolveApplyMapping {

    /// The engine resolution a wire resolution applies as. The vocabulary is
    /// one-to-one; `editedContent` carries the human's text, which must be
    /// present by the time this maps — a pane composes it before staging.
    public static func engineResolution(for resolution: PathResolution) -> ResolveResolution {
        switch resolution.choice {
        case .useOurs: .useOurs
        case .useTheirs: .useTheirs
        case .editedContent: .editedContent(resolution.editedContent ?? "")
        case .keepDeletion: .keepDeletion
        case .keepModification: .keepModification
        case .renameTakeOurs: .renameTakeOurs
        case .renameTakeTheirs: .renameTakeTheirs
        }
    }

    /// Applies one wire resolution at `repoPath`: the engine apply — the
    /// chosen content written and the path staged, one journal checkpoint
    /// per call (#0027/#0212 discipline), individually undoable.
    public static func apply(_ resolution: PathResolution, at repoPath: String) throws {
        try ResolveApply.apply(
            resolution: engineResolution(for: resolution),
            path: resolution.path,
            at: repoPath)
    }
}
