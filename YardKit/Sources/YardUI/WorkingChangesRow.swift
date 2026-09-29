// WorkingChangesRow.swift
//
// #0446: the History pane's first row — "Uncommitted Changes" — which
// selects the Detail pane's Changes view (guide §11 decision 30). The
// branch map has no row above its tips to put it in, so it sits pinned
// above the map, the way other clients put the working tree above HEAD.

import SwiftUI

public struct WorkingChangesRow: View {
    /// How many files `git status` lists; 0 reads "Working tree clean".
    private let fileCount: Int
    /// Whether the Changes view is what the Detail pane shows.
    private let isSelected: Bool
    private let onSelect: () -> Void

    public init(fileCount: Int, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.fileCount = fileCount
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    /// The row's secondary text. Pure and public so it is unit-tested.
    public static func countText(fileCount: Int) -> String {
        switch fileCount {
        case 0: "Working tree clean"
        case 1: "1 changed file"
        default: "\(fileCount) changed files"
        }
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: fileCount == 0 ? "checkmark.circle" : "pencil.circle.fill")
                    .foregroundStyle(fileCount == 0 ? Color.secondary : Color.accentColor)
                Text("Uncommitted Changes")
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                Text(Self.countText(fileCount: fileCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("working-changes-row")
        .help("Show the changes not yet committed")
    }
}
