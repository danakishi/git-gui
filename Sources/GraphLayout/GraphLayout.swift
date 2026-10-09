import GitCore

/// Commit graph layout by lanes (stage 1).
///
/// The input is commits in topological order; the output is, for each row,
/// the node's lane number and a list of edges to its parents.
public enum GraphLayout {
    public struct Row: Sendable, Hashable {
        public let commitID: String
        /// The node's lane (column), left to right from zero.
        public let lane: Int
        /// Edges passing through the row: (from, to) in lanes.
        public let edges: [Edge]
    }

    public struct Edge: Sendable, Hashable {
        public let fromLane: Int
        public let toLane: Int
        /// Sha of the parent the edge goes to.
        public let parentID: String
    }

    /// Stub: all nodes in lane zero. The real algorithm comes in stage 1.
    public static func layout(_ commits: [Commit]) -> [Row] {
        commits.map { Row(commitID: $0.id, lane: 0, edges: []) }
    }
}
