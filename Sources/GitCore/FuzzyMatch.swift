import Foundation

/// Fuzzy search for the command palette: the query letters appear in the text in order,
/// not necessarily consecutively. "fp" finds "Fetch Pull", "gfe" finds "git-gui/feature".
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        /// Higher means a better match.
        public let score: Int
        /// Positions of the matched characters in the text (`Character` indices), for highlighting.
        public let positions: [Int]
    }

    /// `nil` if not all query letters were found. Spaces in the query are ignored,
    /// as are case and diacritics.
    public static func match(_ query: String, in text: String) -> Result? {
        let q = Array(fold(query).filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        let t = Array(fold(text))
        guard q.count <= t.count else { return nil }

        // Greedy from each possible start, keeping the best result:
        // "main" in "origin/main" should match at the end, not as a scattered "m…a…i…n".
        var best: Result?
        for start in t.indices where t[start] == q[0] {
            guard let r = greedy(q, t, from: start) else { break }
            if best == nil || r.score > best!.score { best = r }
        }
        return best
    }

    private static func greedy(_ q: [Character], _ t: [Character], from start: Int) -> Result? {
        var positions: [Int] = []
        var qi = 0
        var ti = start
        while qi < q.count, ti < t.count {
            if t[ti] == q[qi] {
                positions.append(ti)
                qi += 1
            }
            ti += 1
        }
        guard qi == q.count else { return nil }

        var score = 0
        for (k, p) in positions.enumerated() {
            score += 1
            if p == 0 { score += 8 }
            else if isBoundary(t[p - 1]) { score += 6 }
            if k > 0, positions[k - 1] == p - 1 { score += 4 }
        }
        // Slightly penalize scatter and long text: when otherwise equal, short and dense ranks higher.
        score -= (positions.last! - positions.first!) - (positions.count - 1)
        score -= t.count / 16
        return Result(score: score, positions: positions)
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c == " " || c == "/" || c == "-" || c == "_" || c == "." || c == ":" || c == "("
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
