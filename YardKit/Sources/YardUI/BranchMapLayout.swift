// BranchMapLayout.swift
//
// #0411 (umbrella #0410) placed every commit in the branch map; #0426
// (umbrella #0425, guide §11 decision 29) re-shapes it as a staircase tree.
// Pure -- graph rows and refs in, lanes and rows out -- so `swift test` pins
// it.
//
// The model, in our own words (decision 29):
//
// - Every branch tip gets one labelled lane: each distinct tip a local
//   branch or a detached `HEAD` names, and each remote-tracking branch that
//   does not fold into its local namesake. `origin/x` folds into `x`'s lane
//   (a chip on that lane) when its tip is on `x`'s first-parent chain --
//   the same commit, or behind; ahead or diverged, it gets a lane of its own.
// - The root lane is the default branch's (`defaultBranch`, else the
//   literal `main`), else `HEAD`'s. Lanes claim history in order: the root
//   first, then every other lane by how many first-parent commits it has
//   that the root does not reach, fewest first. A lane takes every commit
//   on its tip's first-parent chain nobody took before it; the first
//   already-taken commit is its fork point, and the lane owning that commit
//   is its parent. A lane whose tip was already taken is a stub: a marker
//   on row 0 and its connector.
// - Lanes form a tree. Each child sits immediately right of its parent and
//   its subtree, siblings ordered nearest-fork-first (ties: newer tip first),
//   so no connector crosses a lane. A lane with no fork point in the loaded
//   rows (an unrelated history) is another root, placed after the first
//   root's tree.
// - Rows are a staircase: each lane's commits stack from row 0 down, one row
//   each, except that a commit a child forks from is pushed down to one row
//   below the child's lowest row. Every tip starts on the top row unless a
//   child forks from the tip itself.
// - Folding (#0427): a run of three or more commits in a lane that no
//   child forks from folds into one row -- a lane's tip, its last commit
//   (unless it is a root) and every fork point never fold. A fold whose
//   first commit is in `expandedFolds` shows its commits instead.
// - Recency (#0429): with `shownTips`, only lanes whose tip is in it show,
//   plus the root lane and `HEAD`'s lane always. A hidden lane that a shown
//   lane needs in order to connect to the root shows too, as context. A
//   hidden lane's commits are not drawn.
// - Exactly one horizontal per branch: its connector, from the lane's last
//   row down its own lane to the fork row, then across to the parent lane.
//   Merge edges and commits no lane takes (history merged in from deleted
//   branches) are not drawn.

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
        /// name, then remote-tracking branches by name -- the refs at the
        /// tip, then a folded `origin/x` that is behind it.
        public let chips: [RefChip]
        /// The tip belongs to an earlier lane; this lane draws a marker on
        /// row 0 and its connector.
        public let isStub: Bool
        /// The lane this lane's connector joins; `nil` for a root lane.
        public let parentLane: Int?
        /// #0429: the recency filter hides this lane's tip, but a shown lane
        /// connects through it; drawn greyed.
        public let isContext: Bool

        public init(
            lane: Int, tipOid: String, chips: [RefChip], isStub: Bool, parentLane: Int?, isContext: Bool = false
        ) {
            self.lane = lane
            self.tipOid = tipOid
            self.chips = chips
            self.isStub = isStub
            self.parentLane = parentLane
            self.isContext = isContext
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
        /// A lane's vertical, row 0 to its last row.
        case lane
        /// A lane's one connector: from its last row (a stub's marker)
        /// down its own lane to the fork row, then across to the parent.
        case fork
    }

    public struct Edge: Equatable, Sendable {
        public let kind: EdgeKind
        /// Always in the edge's own lane.
        public let from: Point
        public let to: Point

        public init(kind: EdgeKind, from: Point, to: Point) {
            self.kind = kind
            self.from = from
            self.to = to
        }
    }

    /// #0427: a run of quiet commits drawn as one "⋯ N" row.
    public struct Fold: Equatable, Sendable {
        public let lane: Int
        public let row: Int
        /// The folded commits, newest first.
        public let oids: [String]

        public init(lane: Int, row: Int, oids: [String]) {
            self.lane = lane
            self.row = row
            self.oids = oids
        }

        /// What `expandedFolds` holds to show this fold's commits: its
        /// newest commit, which stays the same while the lane grows.
        public var key: String { oids[0] }
        public var count: Int { oids.count }
        public var point: Point { Point(lane: lane, row: row) }
    }

    /// The shortest run of quiet commits that folds.
    public static let minimumFold = 3

    /// Labelled lanes, lane `i` at index `i`.
    public let headers: [Header]
    /// One node per placed commit, in input order.
    public let nodes: [Node]
    public let edges: [Edge]
    /// #0427: one per folded run, lane by lane.
    public let folds: [Fold]
    /// Labelled lanes, or 1 for the unlabelled lane `nil` refs lay out.
    public let laneCount: Int
    /// One past the lowest row used; 0 for an empty map.
    public let rowCount: Int

    public init(
        headers: [Header], nodes: [Node], edges: [Edge], folds: [Fold] = [], laneCount: Int, rowCount: Int
    ) {
        self.headers = headers
        self.nodes = nodes
        self.edges = edges
        self.folds = folds
        self.laneCount = laneCount
        self.rowCount = rowCount
    }

    /// Lays out `rows` (topological order, children first -- what
    /// `graphRows` returns) under the lanes `refs` names. `defaultBranch` is
    /// the short name of the root lane's branch (`nil` means the literal
    /// `main`); when no local branch has that name, `HEAD`'s lane is the
    /// root. `nil` refs (the sidebar has not loaded) lays out the first
    /// row's first-parent chain as one unlabelled lane. `expandedFolds`
    /// holds the `Fold.key`s the user opened. `shownTips` (#0429) is the
    /// recency filter's answer, tip oids; `nil` shows every lane.
    public static func make(
        rows: [GraphRow], refs: RefSnapshot?, defaultBranch: String? = nil, expandedFolds: Set<String> = [],
        shownTips: Set<String>? = nil
    ) -> BranchMapLayout {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let topoIndex = Dictionary(
            rows.enumerated().map { ($1.oid, $0) }, uniquingKeysWith: { first, _ in first })

        var groups = refs.map { makeGroups(refs: $0, byOid: byOid, topoIndex: topoIndex) } ?? []
        if refs == nil, let first = rows.first {
            groups = [Group(tip: first.oid, chips: [])]
        }
        guard !groups.isEmpty else {
            return BranchMapLayout(headers: [], nodes: [], edges: [], laneCount: 0, rowCount: 0)
        }

        // Claim order: the root, then fewest commits the root does not reach.
        let rootName = defaultBranch ?? "main"
        let rootIndex = groups.firstIndex { $0.chips.contains { $0.kind == .localBranch && $0.name == rootName } }
            ?? groups.firstIndex { $0.chips.contains(where: \.isHead) }
            ?? 0
        let reached = reachable(from: groups[rootIndex].tip, byOid: byOid)
        func ownLength(_ group: Group) -> Int {
            var count = 0
            var next: String? = group.tip
            while let oid = next, let row = byOid[oid], !reached.contains(oid) {
                count += 1
                next = row.parents.first
            }
            return count
        }
        let others = groups.indices.filter { $0 != rootIndex }
            .map { (index: $0, own: ownLength(groups[$0]), topo: topoIndex[groups[$0].tip] ?? Int.max) }
            .sorted { ($0.own, $0.topo) < ($1.own, $1.topo) }
            .map(\.index)
        let claimOrder = [rootIndex] + others

        // Claim first-parent chains. Everything below is indexed by claim
        // order, not by group.
        var owner: [String: Int] = [:]
        var commits: [[String]] = Array(repeating: [], count: groups.count)
        var parent: [Int?] = Array(repeating: nil, count: groups.count)
        var forkIndex: [Int] = Array(repeating: 0, count: groups.count)
        var isStub: [Bool] = Array(repeating: false, count: groups.count)
        var indexInLane: [String: Int] = [:]
        for (order, groupIndex) in claimOrder.enumerated() {
            var next: String? = groups[groupIndex].tip
            while let oid = next, let row = byOid[oid], owner[oid] == nil {
                owner[oid] = order
                indexInLane[oid] = commits[order].count
                commits[order].append(oid)
                next = row.parents.first
            }
            if let fork = next, let forkOwner = owner[fork], forkOwner != order {
                parent[order] = forkOwner
                forkIndex[order] = indexInLane[fork] ?? 0
                isStub[order] = commits[order].isEmpty
            }
        }

        // Recency (#0429): a lane shows when its tip is shown, when it is the
        // root or HEAD's, or -- as context -- when a shown lane descends
        // from it.
        var visible = Array(repeating: shownTips == nil, count: groups.count)
        var isContext = Array(repeating: false, count: groups.count)
        if let shownTips {
            for order in claimOrder.indices {
                let group = groups[claimOrder[order]]
                guard order == 0 || group.chips.contains(where: \.isHead) || shownTips.contains(group.tip) else {
                    continue
                }
                visible[order] = true
                isContext[order] = false
                var ancestor = parent[order]
                while let current = ancestor, !visible[current] {
                    visible[current] = true
                    isContext[current] = true
                    ancestor = parent[current]
                }
            }
        }

        // Tree: children per lane, nearest fork first, newer tip first.
        var children: [[Int]] = Array(repeating: [], count: groups.count)
        for order in claimOrder.indices where visible[order] {
            if let parentOrder = parent[order] { children[parentOrder].append(order) }
        }
        for order in claimOrder.indices {
            children[order].sort { a, b in
                (forkIndex[a], topoIndex[groups[claimOrder[a]].tip] ?? Int.max)
                    < (forkIndex[b], topoIndex[groups[claimOrder[b]].tip] ?? Int.max)
            }
        }

        // Rows, bottom-up: a commit a child forks from sits one row below
        // that child's lowest row; a fold (#0427) takes one row.
        var rowsOf: [[Int]] = Array(repeating: [], count: groups.count)
        var bottom: [Int] = Array(repeating: 0, count: groups.count)
        var foldRuns: [(order: Int, run: Range<Int>)] = []
        func assignRows(_ order: Int) {
            for child in children[order] { assignRows(child) }
            var need: [Int: Int] = [:]
            for child in children[order] {
                need[forkIndex[child]] = max(need[forkIndex[child]] ?? 0, bottom[child] + 1)
            }
            let count = commits[order].count
            var kept: Set<Int> = [0]
            kept.formUnion(children[order].map { forkIndex[$0] })
            if parent[order] != nil { kept.insert(count - 1) }
            var rows = Array(repeating: 0, count: count)
            var previous = -1
            var index = 0
            while index < count {
                var end = index + 1
                if !kept.contains(index) {
                    while end < count, !kept.contains(end) { end += 1 }
                }
                if end - index >= minimumFold, !expandedFolds.contains(commits[order][index]) {
                    previous += 1
                    for member in index..<end { rows[member] = previous }
                    foldRuns.append((order, index..<end))
                } else {
                    for member in index..<end {
                        previous = max(previous + 1, need[member] ?? 0)
                        rows[member] = previous
                    }
                }
                index = end
            }
            rowsOf[order] = rows
            bottom[order] = rows.last ?? 0
        }

        // Lane order: depth-first from each root.
        var laneOf: [Int] = Array(repeating: 0, count: groups.count)
        var laneOrder: [Int] = []
        func place(_ order: Int) {
            laneOf[order] = laneOrder.count
            laneOrder.append(order)
            for child in children[order] { place(child) }
        }
        for order in claimOrder.indices where parent[order] == nil && visible[order] {
            assignRows(order)
            place(order)
        }

        var headers: [Header] = []
        var edges: [Edge] = []
        var maxRow = 0
        for order in laneOrder {
            let lane = laneOf[order]
            let group = groups[claimOrder[order]]
            if refs != nil {
                headers.append(Header(
                    lane: lane, tipOid: group.tip, chips: group.chips,
                    isStub: isStub[order], parentLane: parent[order].map { laneOf[$0] },
                    isContext: isContext[order]))
            }
            if bottom[order] > 0 {
                edges.append(Edge(
                    kind: .lane, from: Point(lane: lane, row: 0), to: Point(lane: lane, row: bottom[order])))
            }
            maxRow = max(maxRow, bottom[order])
            if let parentOrder = parent[order] {
                edges.append(Edge(
                    kind: .fork, from: Point(lane: lane, row: bottom[order]),
                    to: Point(lane: laneOf[parentOrder], row: rowsOf[parentOrder][forkIndex[order]])))
            }
        }

        var folded: Set<String> = []
        var folds: [Fold] = []
        for (order, run) in foldRuns.sorted(by: { (laneOf[$0.order], $0.run.lowerBound) < (laneOf[$1.order], $1.run.lowerBound) }) {
            let oids = Array(commits[order][run])
            folded.formUnion(oids)
            folds.append(Fold(lane: laneOf[order], row: rowsOf[order][run.lowerBound], oids: oids))
        }

        var nodes: [Node] = []
        nodes.reserveCapacity(rows.count)
        for row in rows where !folded.contains(row.oid) {
            guard let order = owner[row.oid], visible[order], let index = indexInLane[row.oid] else { continue }
            nodes.append(Node(oid: row.oid, lane: laneOf[order], row: rowsOf[order][index]))
        }

        return BranchMapLayout(
            headers: headers, nodes: nodes, edges: edges, folds: folds, laneCount: laneOrder.count,
            rowCount: maxRow + 1)
    }

    private struct Group {
        let tip: String
        var chips: [RefChip]
    }

    /// Every commit reachable from `tip` through any parent, inside the
    /// loaded rows.
    private static func reachable(from tip: String, byOid: [String: GraphRow]) -> Set<String> {
        var seen: Set<String> = []
        var stack = [tip]
        while let oid = stack.popLast() {
            guard let row = byOid[oid], seen.insert(oid).inserted else { continue }
            stack += row.parents
        }
        return seen
    }

    /// One group per distinct tip inside the loaded rows: a detached `HEAD`
    /// and local branches first, then every remote-tracking branch that does
    /// not fold into its local namesake (see the file header).
    private static func makeGroups(
        refs: RefSnapshot, byOid: [String: GraphRow], topoIndex: [String: Int]
    ) -> [Group] {
        let heads = "refs/heads/"
        let remotes = "refs/remotes/"
        var groups: [Group] = []
        var groupOfTip: [String: Int] = [:]
        func addGroup(_ oid: String) {
            guard byOid[oid] != nil, groupOfTip[oid] == nil else { return }
            var chips = RefChips.make(oid: oid, refs: refs, decoration: "")
            if case let .detached(detached) = refs.head, detached == oid {
                chips.insert(RefChip(name: "HEAD", kind: .detachedHead, isHead: true), at: 0)
            }
            groupOfTip[oid] = groups.count
            groups.append(Group(tip: oid, chips: chips))
        }
        if case let .detached(oid) = refs.head { addGroup(oid) }
        let locals = refs.refs.filter { $0.name.hasPrefix(heads) }
        for entry in locals { addGroup(entry.oid) }
        let localTip = Dictionary(
            locals.map { (String($0.name.dropFirst(heads.count)), $0.oid) }, uniquingKeysWith: { first, _ in first })

        for entry in refs.refs where entry.name.hasPrefix(remotes) && !entry.name.hasSuffix("/HEAD") {
            guard byOid[entry.oid] != nil, groupOfTip[entry.oid] == nil else { continue }
            let short = String(entry.name.dropFirst(remotes.count))
            let branch = short.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? short
            if let tip = localTip[branch], let group = groupOfTip[tip],
               isOnFirstParentChain(entry.oid, from: tip, byOid: byOid, topoIndex: topoIndex) {
                groups[group].chips.append(RefChip(name: short, kind: .remoteBranch, isHead: false))
            } else {
                addGroup(entry.oid)
            }
        }
        return groups.filter { !$0.chips.isEmpty }
    }

    /// Whether `target` is on `tip`'s first-parent chain. The walk stops once
    /// it passes `target`'s topological position, since a parent is never
    /// above its child.
    private static func isOnFirstParentChain(
        _ target: String, from tip: String, byOid: [String: GraphRow], topoIndex: [String: Int]
    ) -> Bool {
        guard let limit = topoIndex[target] else { return false }
        var next: String? = tip
        while let oid = next, let row = byOid[oid], let index = topoIndex[oid], index <= limit {
            if oid == target { return true }
            next = row.parents.first
        }
        return false
    }
}
