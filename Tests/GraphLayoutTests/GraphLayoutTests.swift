import Foundation
import Testing
@testable import GitCore
@testable import GraphLayout

/// Fixtures are given as a string: `id: parent1 parent2`, one commit per line,
/// in topological order.
private func commits(_ spec: String) -> [Commit] {
    spec.split(separator: "\n").map { line in
        let parts = line.split(separator: ":", maxSplits: 1)
        let id = parts[0].trimmingCharacters(in: .whitespaces)
        let parents = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        return Commit(id: id, parents: parents, authorName: "", authorEmail: "",
                      authorDate: .now, commitDate: .now, subject: id)
    }
}

@Suite("GraphLayout")
struct GraphLayoutTests {
    @Test("Linear history: one lane, one color")
    func linear() {
        let rows = GraphLayout.layout(commits("""
        c: b
        b: a
        a
        """))
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(Set(rows.map(\.color)).count == 1)
        #expect(rows[0].incoming.isEmpty)
        #expect(rows[0].outgoing.map(\.lane) == [0])
        #expect(rows[1].incoming.map(\.lane) == [0])
        #expect(rows[2].outgoing.isEmpty)
        #expect(rows.allSatisfy { $0.passing.isEmpty })
    }

    @Test("Branch and merge: the second lane appears and is released")
    func branchAndMerge() {
        // m merges f into main; f branched off from a.
        let rows = GraphLayout.layout(commits("""
        m: b f
        f: a
        b: a
        a
        """))
        let m = rows[0], f = rows[1], b = rows[2], a = rows[3]
        #expect(m.lane == 0)
        #expect(m.outgoing.map(\.lane) == [0, 1])
        #expect(f.lane == 1)
        #expect(f.passing.map(\.lane) == [0])          // main passes by f
        #expect(b.lane == 0)
        #expect(b.passing.map(\.lane) == [1])          // f→a passes by b
        #expect(a.lane == 0)
        #expect(a.incoming.map(\.lane).sorted() == [0, 1]) // both lanes merge into a
        #expect(a.outgoing.isEmpty)
        #expect(f.color != m.color)                    // the branch has its own color
        #expect(b.color == m.color)                    // the first parent inherits the color
    }

    @Test("Octopus merge: three parents")
    func octopus() {
        let rows = GraphLayout.layout(commits("""
        m: a b c
        a
        b
        c
        """))
        #expect(rows[0].outgoing.map(\.lane) == [0, 1, 2])
        #expect(rows.map(\.lane) == [0, 0, 1, 2])
        #expect(GraphLayout.layout(commits("m: a b c\na\nb\nc")).map(\.width).max() == 3)
    }

    @Test("Two roots: independent histories don't cross")
    func twoRoots() {
        let rows = GraphLayout.layout(commits("""
        y: x
        x
        b: a
        a
        """))
        #expect(rows[0].lane == 0)
        #expect(rows[1].lane == 0)
        // x is a root, lane 0 is freed, and b takes it again.
        #expect(rows[2].lane == 0)
        #expect(rows[2].color != rows[0].color)
    }

    @Test("Parent beyond the page boundary: the lane keeps waiting")
    func incrementalAppend() {
        var engine = GraphLayout()
        engine.append(commits("c: b\nb: a"))
        #expect(engine.rows.count == 2)
        #expect(engine.rows[1].outgoing.map(\.lane) == [0])

        engine.append(commits("a"))
        #expect(engine.rows.count == 3)
        #expect(engine.rows[2].lane == 0)
        #expect(engine.rows[2].incoming.map(\.lane) == [0])
        #expect(engine.rows[2].color == engine.rows[0].color)
    }

    @Test("Merge into an already waiting lane doesn't create new ones")
    func mergeIntoExistingLane() {
        // m merges d; does d wait in lane 1 after f? No: f: d — d is already awaited in lane 1,
        // so m2: c d must draw an edge into lane 1 rather than open a third.
        let rows = GraphLayout.layout(commits("""
        m2: c d
        c: m
        m: b f
        f: d
        b: a
        d: a
        a
        """))
        let m2 = rows[0]
        #expect(m2.outgoing.count == 2)
        #expect(rows.map(\.width).max()! <= 3)
    }
}
