// Commands.swift
//
// #0084: the File menu's repository-opening commands. Both routes -- the
// Open… panel and the Open Recent menu -- end in `RepositoryOpener`, the
// same funnel the drag-and-drop, URL, and XPC entry points use, so there is
// exactly one focus-or-open rule (#0079) in the app.
//
// The recent-repositories menu has no persistence of its own: the open tabs
// ARE the recents for focus purposes, so the menu reads
// `RepositoryTabs.shared.tabs` and re-opening an entry re-selects that tab
// through `open(path:)`. A persistent recents store is a later issue's, not
// a second open path invented here.
//
// Declaration-thin per guide §11 decision 10: the behaviour lives in YardUI.

import SwiftUI
import YardUI

struct SwitchyardCommands: Commands {
    let store = RepositoryTabs.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") {
                RepositoryOpener.chooseAndOpen(store: store)
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(store.tabs) { tab in
                    Button(tab.displayName) {
                        RepositoryOpener.open(path: tab.openPath, store: store)
                    }
                }
            }
            .disabled(store.tabs.isEmpty)
        }
    }
}
