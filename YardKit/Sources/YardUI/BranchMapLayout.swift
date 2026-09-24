// BranchMapLayout.swift
//
// #0411 (umbrella #0410): where every commit sits in the branch map. Pure --
// graph rows and refs in, lanes and rows out -- so `swift test` pins it.
//
// The model, in our own words (docs: issues/0410.md "Design"):
//
// - Every tip commit a local branch, remote-tracking branch or detached
//   `HEAD` names gets one labelled lane. Refs at the same commit share it.
//   `HEAD`'s lane is first; other lanes with a local branch follow, most
//   recent first (topo position of the tip); a lane holding only
//   remote-tracking refs sits right after the lane of its local namesake
//   (`origin/feature` after `feature`), or at the end when it has none.
// - Lanes claim history in that order: each walks its tip's first-parent
//   chain and takes every commit nobody took before it. Those commits are
//   the lane's own and stack from row 0 down, one row each, so every
//   labelled lane starts on the top row. The first already-taken commit the
//   walk meets is the lane's fork point.
// - A lane whose tip an earlier lane already took (the branch is behind, or
//   fast-forward merged) owns nothing: it is a stub -- a marker on row 0 and
//   a fork edge to its tip commit.
// - Commits no labelled lane takes (history merged in from deleted
//   branches) form unlabelled runs, each starting one row below the lowest
//   child that points at it. Runs pack into shared tracks right of the
//   labelled lanes; a track is reused once the previous run's rows (and
//   its fork edge) have ended.

import YardGit

public nonisolated struct BranchMapLayout: Equatable, Sendable {
    /// A (lane, row) cell. Row 0 is the top row.
    public struct Point: Hashable, Sendable {
        public let lane: Int
        public let row: Int

        public init(lane: Int, row: Int) {
            self.lane = lane
            self.row = row
        }
    }

    /// One labelled lane: the refs naming one tip commit.
    public struct Header: Equatable, Sendable {
        public let lane: Int
        public let tipOid: String
        /// Display order: the `HEAD` chip first, then local branches by
        /// name, then remote-tracking branches by name.
        public let chips: [RefChip]
        /// The tip belongs to an earlier lane; this lane draws a marker on
        /// row 0 and a fork edge to it.
        public let isStub: Bool

        public init(lane: Int, tipOid: String, chips: [RefChip], isStub: Bool) {
            self.lane = lane
            self.tipOid = tipOid
            self.chips = chips
            self.isStub = isStub
        }

        /// Only remote-tracking refs name this tip.
        public var isRemoteOnly: Bool { chips.allSatisfy { $0.kind == .remoteBranch } }
    }

    public struct Node: Equatable, Sendable {
        public let oid: String
        public let lane: Int
        public let row: Int

        public init(oid: String, lane: Int, row: Int) {
            self.oid = oid
            self.lane = lane
            self.row = row
        }

        public var point: Point { Point(lane: lane, row: row) }
    }

    public enum EdgeKind: Equatable, Sendable {
        /// A first parent on the next row of the same lane.
        case chain
        /// The last commit of a lane's run (or a stub's marker) to the
        /// commit it forked from.
        case fork
        /// A merge commit to a parent other than its first.
        case merge
    }

    public struct Edge: Equatable, Sendable {
        public let kind: EdgeKind
        public let from: Point
        public let to: Point
        /// `nil` for a stub's marker, which is not a commit.
        public let childOid: String?
        public let parentOid: String

        public init(kind: EdgeKind, from: Point, to: Point, childOid: String?, parentOid: String) {
            self.kind = kind
            self.from = from
            self.to = to
            self.childOid = childOid
            self.parentOid = parentOid
        }
    }

    /// Labelled lanes, lane `i` at index `i`.
    public let headers: [Header]
    /// One node per input row that was placed, in input order.
    public let nodes: [Node]
    public let edges: [Edge]
    /// Labelled lanes plus unlabelled tracks.
    public let laneCount: Int
    /// One past the lowest row used; 0 for an empty map.
    public let rowCount: Int

    public init(headers: [Header], nodes: [Node], edges: [Edge], laneCount: Int, rowCount: Int) {
        self.headers = headers
        self.nodes = nodes
        self.edges = edges
        self.laneCount = laneCount
        self.rowCount = rowCount
    }

    /// Lays out `rows` (topological order, children first -- what
    /// `graphRows` returns) under the lanes `refs` names. `nil` refs (the
    /// sidebar has not loaded) gives no labelled lanes: every commit then
    /// sits in an unlabelled run.
    public static func make(rows: [GraphRow], refs: RefSnapshot?) -> BranchMapLayout {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let topoIndex = Dictionary(
            rows.enumerated().map { ($1.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [String]] = [:]
        for row in rows {
            for parent in row.parents where byOid[parent] != nil {
                children[parent, default: []].append(row.oid)
            }
        }

        let groups = refs.map { orderedGroups(refs: $0, topoIndex: topoIndex) } ?? []

        var lane: [String: Int] = [:]
        var rowOf: [String: Int] = [:]
        var headers: [Header] = []
        var edges: [Edge] = []
        var maxRow = -1

        // Labelled lanes claim their first-parent chains in order.
        for (index, group) in groups.enumerated() {
            if lane[group.tip] != nil, let tipRow = rowOf[group.tip], let tipLane = lane[group.tip] {
                headers.append(Header(lane: index, tipOid: group.tip, chips: group.chips, isStub: true))
                edges.append(Edge(
                    kind: .fork, from: Point(lane: index, row: 0), to: Point(lane: tipLane, row: tipRow),
                    childOid: nil, parentOid: group.tip))
                maxRow = max(maxRow, 0)
                continue
            }
            headers.append(Header(lane: index, tipOid: group.tip, chips: group.chips, isStub: false))
            var next: String? = group.tip
            var row = 0
            while let oid = next, let graphRow = byOid[oid], lane[oid] == nil {
                lane[oid] = index
                rowOf[oid] = row
                maxRow = max(maxRow, row)
                row += 1
                next = graphRow.parents.first
            }
        }

        // Unlabelled runs, in topological order of their first commit, so
        // every child of a run's first commit already has a row.
        let firstTrack = headers.count
        var trackEnds: [Int] = []
        for graphRow in rows where lane[graphRow.oid] == nil {
            var members: [String] = []
            var next: String? = graphRow.oid
            while let oid = next, let member = byOid[oid], lane[oid] == nil {
                members.append(oid)
                next = member.parents.first
            }
            let childRows = (children[graphRow.oid] ?? []).compactMap { rowOf[$0] }
            let start = (childRows.max() ?? -1) + 1
            let last = start + members.count - 1
            let forkRow = next.flatMap { rowOf[$0] }
            let occupiedFrom = childRows.isEmpty ? start : start - 1
            let occupiedTo = max(last, forkRow ?? last)
            let track: Int
            if let free = trackEnds.firstIndex(where: { $0 < occupiedFrom }) {
                track = free
                trackEnds[free] = occupiedTo
            } else {
                track = trackEnds.count
                trackEnds.append(occupiedTo)
            }
            for (offset, oid) in members.enumerated() {
                lane[oid] = firstTrack + track
                rowOf[oid] = start + offset
            }
            maxRow = max(maxRow, last)
        }

        // Nodes and commit edges, in input order.
        var nodes: [Node] = []
        nodes.reserveCapacity(rows.count)
        for graphRow in rows {
            guard let childLane = lane[graphRow.oid], let childRow = rowOf[graphRow.oid] else { continue }
            nodes.append(Node(oid: graphRow.oid, lane: childLane, row: childRow))
            for (index, parent) in graphRow.parents.enumerated() {
                guard let parentLane = lane[parent], let parentRow = rowOf[parent] else { continue }
                let kind: EdgeKind
                if index > 0 {
                    kind = .merge
                } else if parentLane == childLane && parentRow == childRow + 1 {
                    kind = .chain
                } else {
                    kind = .fork
                }
                edges.append(Edge(
                    kind: kind, from: Point(lane: childLane, row: childRow),
                    to: Point(lane: parentLane, row: parentRow),
                    childOid: graphRow.oid, parentOid: parent))
            }
        }

        return BranchMapLayout(
            headers: headers, nodes: nodes, edges: edges,
            laneCount: firstTrack + trackEnds.count, rowCount: maxRow + 1)
    }

    private struct Group {
        let tip: String
        let chips: [RefChip]
    }

    /// One group per distinct tip commit inside the loaded rows, in lane
    /// order (see the file header).
    private static func orderedGroups(refs: RefSnapshot, topoIndex: [String: Int]) -> [Group] {
        var tips: [String] = []
        var detached: String?
        if case let .detached(oid) = refs.head {
            detached = oid
            tips.append(oid)
        }
        for entry in refs.refs where entry.name.hasPrefix("refs/heads/")
            || (entry.name.hasPrefix("refs/remotes/") && !entry.name.hasSuffix("/HEAD")) {
            tips.append(entry.oid)
        }
        var seen: Set<String> = []
        let groups: [Group] = tips.compactMap { oid in
            guard topoIndex[oid] != nil, seen.insert(oid).inserted else { return nil }
            var chips = RefChips.make(oid: oid, refs: refs, decoration: "")
            if oid == detached {
                chips.insert(RefChip(name: "HEAD", kind: .detachedHead, isHead: true), at: 0)
            }
            return chips.isEmpty ? nil : Group(tip: oid, chips: chips)
        }
        func recency(_ group: Group) -> Int { topoIndex[group.tip] ?? Int.max }

        let head = groups.filter { $0.chips.contains(where: \.isHead) }
        let locals = groups
            .filter { group in
                !group.chips.contains(where: \.isHead) && group.chips.contains { $0.kind == .localBranch }
            }
            .sorted { recency($0) < recency($1) }
        let remotes = groups
            .filter { group in group.chips.allSatisfy { $0.kind == .remoteBranch } }
            .sorted { recency($0) < recency($1) }

        let anchored = head + locals
        var after: [[Group]] = Array(repeating: [], count: anchored.count)
        var unanchored: [Group] = []
        for remote in remotes {
            let names = Set(remote.chips.map { BranchTip(name: $0.name, oid: "", isRemote: true).colorKey })
            if let anchor = anchored.firstIndex(where: { group in
                group.chips.contains { $0.kind == .localBranch && names.contains($0.name) }
            }) {
                after[anchor].append(remote)
            } else {
                unanchored.append(remote)
            }
        }
        var ordered: [Group] = []
        for (index, group) in anchored.enumerated() {
            ordered.append(group)
            ordered += after[index]
        }
        return ordered + unanchored
    }
}
