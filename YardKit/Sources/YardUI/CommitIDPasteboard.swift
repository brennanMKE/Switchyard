// CommitIDPasteboard.swift
//
// #0377: puts a full commit id on the general pasteboard. The full oid is
// unambiguous in any repository and is what every git command accepts; the
// short id stays visible in the history row for reading.

import AppKit

/// #0377: puts a full commit id on the general pasteboard.
public enum CommitIDPasteboard {
    /// Copies `oid` to the general pasteboard, replacing whatever was there:
    /// `clearContents` first so a prior copy's types cannot linger beside it.
    public static func copy(_ oid: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(oid, forType: .string)
    }
}
