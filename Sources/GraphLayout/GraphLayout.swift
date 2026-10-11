import GitCore

/// Commit graph layout by lanes.
///
/// The input is commits in topological order (children before parents), as
/// produced by `git log --topo-order`. For each commit we get the node's lane
/// number and the lines to draw in its row. The row is split into an
/// upper half (lines coming in from above) and a lower half (going out downward).
///
/// The engine is incremental: history is loaded in pages, and `append` continues
/// the layout from where it left off.
public struct GraphLayout: Sendable {
    /// A line in one half of a row.
    public struct Line: Sendable, Hashable {
        /// Lane at the row's edge (top for incoming, bottom for outgoing).
        public let lane: Int
        /// Color index: one per chain of first parents.
        public let color: Int
    }

    public struct Row: Sendable, Hashable {
        public let commitID: String
        /// The node's lane.
        public let lane: Int
        public let color: Int
        /// Lines coming into the node from above.
        public let incoming: [Line]
        /// Lines going out of the node downward, to its parents.
        public let outgoing: [Line]
        /// Lines passing straight through the row without touching the node.
        public let passing: [Line]

        /// How many lanes the row occupies (for the column width).
        public var width: Int {
            let all = [lane] + incoming.map(\.lane) + outgoing.map(\.lane) + passing.map(\.lane)
            return (all.max() ?? 0) + 1
        }
    }

    /// A pending lane: which commit will appear in it next.
    private struct Slot: Sendable { let sha: String; let color: Int }

    private var lanes: [Slot?] = []
    private var nextColor = 0
    public private(set) var rows: [Row] = []
    /// Maximum width across all rows.
    public private(set) var maxWidth = 0

    public init() {}

    /// Lays out the whole list.
    public static func layout(_ commits: [Commit]) -> [Row] {
        var engine = GraphLayout()
        engine.append(commits)
        return engine.rows
    }

    /// Continues the layout with the next page of commits.
    public mutating func append(_ commits: [Commit]) {
        rows.reserveCapacity(rows.count + commits.count)
        for commit in commits {
            rows.append(place(commit))
        }
    }

    private mutating func place(_ commit: Commit) -> Row {
        // Lanes that were waiting for this commit: the node takes the first of them,
        // the rest merge into it from above.
        let waiting = lanes.indices.filter { lanes[$0]?.sha == commit.id }
        let lane: Int
        let color: Int
        if let first = waiting.first, let slot = lanes[first] {
            lane = first
            color = slot.color
        } else {
            lane = firstFreeLane()
            color = nextColor
            nextColor += 1
        }
        let incoming = waiting.map { Line(lane: $0, color: lanes[$0]!.color) }

        // Passing lines: all occupied lanes except those that merged into the node.
        var passing: [Line] = []
        for (i, slot) in lanes.enumerated() {
            if let slot, slot.sha != commit.id {
                passing.append(Line(lane: i, color: slot.color))
            }
        }

        // Free the merged lanes and place the node on its own.
        for i in waiting { lanes[i] = nil }
        if lane >= lanes.count { lanes.append(contentsOf: Array(repeating: nil, count: lane - lanes.count + 1)) }

        // Parents: the first inherits the node's lane and color, the others go
        // to the lane already waiting for them or to the first free one.
        var outgoing: [Line] = []
        lanes[lane] = nil
        for (n, parent) in commit.parents.enumerated() {
            let existing = lanes.firstIndex(where: { $0?.sha == parent })
            if let existing, let slot = lanes[existing], n > 0 || existing < lane {
                // The parent is already awaited: draw the line there. For the first parent,
                // only if that lane is to the left, otherwise our line would have stayed
                // straight while the branch on the left jumped to the right.
                outgoing.append(Line(lane: existing, color: slot.color))
            } else if n == 0 {
                lanes[lane] = Slot(sha: parent, color: color)
                outgoing.append(Line(lane: lane, color: color))
            } else {
                let free = firstFreeLane(after: lane)
                let c = nextColor
                nextColor += 1
                if free >= lanes.count { lanes.append(nil) }
                lanes[free] = Slot(sha: parent, color: c)
                outgoing.append(Line(lane: free, color: c))
            }
        }
        // A tail of empty lanes isn't needed.
        while let last = lanes.last, last == nil { lanes.removeLast() }

        let row = Row(commitID: commit.id, lane: lane, color: color,
                      incoming: incoming, outgoing: outgoing, passing: passing)
        maxWidth = max(maxWidth, row.width)
        return row
    }

    private func firstFreeLane(after: Int = -1) -> Int {
        for i in lanes.indices where i > after && lanes[i] == nil { return i }
        return max(lanes.count, after + 1)
    }
}
