// BranchMapView.swift
//
// #0413 (umbrella #0410): the History pane's branch map. Every labelled
// lane's tip sits on the top row under a slanted branch label that stays
// pinned while the map scrolls vertically; each branch's own commits run
// down its lane; fork and merge edges run to the commits they join.
// `BranchMapLayout` places the commits and `BranchMapGeometry` turns cells
// into points; this view only draws and routes input.
//
// Rows are drawn by one `Canvas` strip each inside a `LazyVStack`, so a
// 5,000-commit history realises only the strips on screen. Each strip
// draws the edges `BranchMapGeometry.edgesByRow` lists for it -- an edge
// spanning many rows is drawn piecewise by every strip it crosses -- and
// carries one invisible square target per commit on its row. The target is
// what the pointer, the context menu and accessibility see: one static-text
// element per commit whose label is `CommitRowAccessibility.label`, the
// label #0399's History rows spoke, so VoiceOver and the UI tests read the
// same words.

import SwiftUI
import YardGit

struct BranchMapView: View {
    let layout: BranchMapLayout
    let entriesByOid: [String: CommitLogEntry]
    let chipsByOid: [String: [RefChip]]
    let headOid: String?
    /// #0368: commits a local tip reaches; `nil` treats every commit as local.
    let localOids: Set<String>?
    /// #0402: the filter's matches; `nil` when the filter is off.
    let matches: Set<String>?
    let branchName: String?
    let menuStates: ((String) -> [CommitActionState])?
    let perform: ((CommitAction, String) -> Void)?
    let onOpenChanges: ((String) -> Void)?
    /// Scrolls the map to centre this commit when it changes.
    let focusRequest: HistoryScrollRequest?
    @Binding var selection: String?

    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero

    var body: some View {
        let content = BranchMapGeometry.contentSize(layout)
        let edgesByRow = BranchMapGeometry.edgesByRow(layout)
        let nodesByRow = BranchMapGeometry.nodesByRow(layout)
        let nodeRowByOid = Dictionary(
            layout.nodes.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<layout.rowCount, id: \.self) { row in
                        strip(row: row, width: content.width, edges: edgesByRow[row], nodes: nodesByRow[row])
                    }
                } header: {
                    BranchMapHeader(layout: layout, width: content.width)
                }
            }
            .frame(width: content.width, alignment: .leading)
        }
        // A 2-D scroll view otherwise opens centred; the map reads from
        // `HEAD`'s lane at the top left (measured in the VM, 2026-09-23).
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { _, size in
            viewport = size
        }
        .onChange(of: focusRequest) { _, request in
            guard let request, let node = nodeRowByOid[request.oid] else { return }
            scroll(to: node, content: content)
        }
        .focusable()
        .focusEffectDisabled()
        // #0377: with a commit selected, Edit ▸ Copy puts its full oid on
        // the pasteboard.
        .copyable(selection.map { [$0] } ?? [])
        // Up and down step through the selected commit's lane. Modified
        // arrows pass through, so the Commit menu's ⌥⌘↑ and ⌥⌘↓ still reach
        // the menu bar (#0383).
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers.isEmpty, let selection, let current = nodeRowByOid[selection] else {
                return .ignored
            }
            let step = press.key == .upArrow ? -1 : 1
            guard let next = layout.nodes.first(where: { $0.lane == current.lane && $0.row == current.row + step })
            else { return .handled }
            self.selection = next.oid
            scroll(to: next, content: content)
            return .handled
        }
    }

    private func scroll(to node: BranchMapLayout.Node, content: CGSize) {
        let offset = BranchMapGeometry.scrollOffset(
            centering: BranchMapGeometry.point(node.point), viewport: viewport, content: content)
        withAnimation { position.scrollTo(point: offset) }
    }

    private func strip(row: Int, width: CGFloat, edges: [Int], nodes: [Int]) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.translateBy(x: 0, y: -CGFloat(row) * BranchMapGeometry.rowHeight)
                for index in edges {
                    draw(edge: layout.edges[index], in: context)
                }
                if row == 0 {
                    for header in layout.headers where header.isStub {
                        drawStubMarker(header, in: context)
                    }
                }
                for index in nodes {
                    draw(node: layout.nodes[index], in: context)
                }
            }
            .frame(width: width, height: BranchMapGeometry.rowHeight)
            .accessibilityHidden(true)
            ForEach(nodes, id: \.self) { index in
                nodeTarget(layout.nodes[index])
            }
        }
        .frame(width: width, height: BranchMapGeometry.rowHeight, alignment: .topLeading)
    }

    // MARK: Drawing

    private func laneColor(_ lane: Int) -> Color {
        guard lane < layout.headers.count, let chip = layout.headers[lane].chips.first else { return .secondary }
        return BranchColor.color(for: chip)
    }

    private func draw(edge: BranchMapLayout.Edge, in context: GraphicsContext) {
        let points = BranchMapGeometry.polyline(edge)
        var path = Path()
        path.addLines(points)
        let color = laneColor(edge.kind == .merge ? edge.to.lane : edge.from.lane)
        let dashed = edge.childOid.map { oid in localOids.map { !$0.contains(oid) } ?? false } ?? true
        context.stroke(
            path, with: .color(color),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : []))
    }

    private func drawStubMarker(_ header: BranchMapLayout.Header, in context: GraphicsContext) {
        let center = BranchMapGeometry.point(BranchMapLayout.Point(lane: header.lane, row: 0))
        let radius: CGFloat = 3.5
        let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        context.fill(ring, with: .color(laneColor(header.lane)))
    }

    private func draw(node: BranchMapLayout.Node, in context: GraphicsContext) {
        var context = context
        if let matches, !matches.contains(node.oid) {
            context.opacity = 0.25
        } else if let localOids, !localOids.contains(node.oid) {
            context.opacity = 0.6
        }
        let center = BranchMapGeometry.point(node.point)
        let radius = BranchMapGeometry.nodeRadius
        let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
        let color = laneColor(node.lane)
        if (entriesByOid[node.oid]?.parents.count ?? 0) > 1 {
            var clearing = context
            clearing.blendMode = .clear
            clearing.fill(dot, with: .color(.black))
            context.stroke(dot, with: .color(color), lineWidth: 2)
        } else {
            context.fill(dot, with: .color(color))
        }
        if node.oid == headOid {
            let ring = radius + 3
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                with: .color(.primary), lineWidth: 1.5)
        }
        if node.oid == selection {
            let ring = radius + 5.5
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                with: .color(.accentColor), lineWidth: 2.5)
        }
    }

    // MARK: Targets

    private func nodeTarget(_ node: BranchMapLayout.Node) -> some View {
        let oid = node.oid
        let side = BranchMapGeometry.nodeTarget
        let label = entriesByOid[oid].map {
            CommitRowAccessibility.label(entry: $0, chips: chipsByOid[oid] ?? [])
        } ?? oid
        return Rectangle()
            .fill(Color.clear)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selection = oid
                onOpenChanges?(oid)
            }
            .onTapGesture {
                selection = oid
            }
            .contextMenu {
                BranchMapNodeMenu(
                    oid: oid, branchName: branchName, menuStates: menuStates, perform: perform)
            }
            .help(entriesByOid[oid]?.subject ?? oid)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selection == oid ? [.isStaticText, .isSelected] : .isStaticText)
            // The tap gestures make the target a Button to accessibility
            // (measured in the VM); a static text keeps #0399's element
            // type, which `historyRows(containing:)` queries.
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAction { selection = oid }
            .padding(.leading, BranchMapGeometry.x(lane: node.lane) - side / 2)
            .padding(.top, (BranchMapGeometry.rowHeight - side) / 2)
    }
}

/// #0359's context menu for one commit: Copy Commit ID, then the same
/// `CommitActionMenuItems` the menu bar's Commit menu renders. A view of
/// its own so `menuStates` runs when the menu is built, not for every
/// commit on every redraw.
private struct BranchMapNodeMenu: View {
    let oid: String
    let branchName: String?
    let menuStates: ((String) -> [CommitActionState])?
    let perform: ((CommitAction, String) -> Void)?

    var body: some View {
        Button("Copy Commit ID") {
            CommitIDPasteboard.copy(oid)
        }
        if let menuStates, let perform {
            Divider()
            CommitActionMenuItems(
                states: menuStates(oid), branchName: branchName,
                perform: { perform($0, oid) })
        }
    }
}

/// The pinned row of slanted branch labels, one per labelled lane, each
/// starting at its lane's centre and rising to the right.
struct BranchMapHeader: View {
    let layout: BranchMapLayout
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(layout.headers, id: \.lane) { header in
                BranchMapLabel(header: header)
                    .rotationEffect(.degrees(-45), anchor: .bottomLeading)
                    .padding(.leading, BranchMapGeometry.x(lane: header.lane) - 2)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: width, height: BranchMapGeometry.headerHeight, alignment: .bottomLeading)
        .background(.background)
    }
}

private struct BranchMapLabel: View {
    let header: BranchMapLayout.Header

    var body: some View {
        let isHead = header.chips.first?.isHead == true
        Text(BranchMapLabels.title(header.chips))
            .font(.caption.weight(isHead ? .bold : .regular))
            .italic(header.isRemoteOnly)
            .lineLimit(1)
            .fixedSize()
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(header.chips.first.map { BranchColor.color(for: $0) } ?? .secondary)
                    .frame(height: 1.5)
            }
            .help(header.chips.map(\.name).joined(separator: ", "))
            .accessibilityLabel(BranchMapLabels.accessibilityLabel(header.chips))
    }
}

public nonisolated enum BranchMapLabels {
    /// A lane's slanted label: its first two ref names, then "+N" for the
    /// rest (#0409: fold, never truncate a name).
    public static func title(_ chips: [RefChip], limit: Int = 2) -> String {
        let names = chips.prefix(limit).map(\.name).joined(separator: ", ")
        return chips.count > limit ? "\(names) +\(chips.count - limit)" : names
    }

    /// What VoiceOver says for a lane label -- every name, and never just a
    /// bare name, so a UI test's exact-name query for a sidebar row cannot
    /// match a lane label instead.
    public static func accessibilityLabel(_ chips: [RefChip]) -> String {
        "Lane " + chips.map(\.name).joined(separator: ", ")
    }
}
