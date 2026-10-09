import Foundation
import Testing
@testable import GitCore
@testable import GraphLayout

@Suite("GraphLayout")
struct GraphLayoutTests {
    func commit(_ id: String, parents: [String]) -> Commit {
        Commit(id: id, parents: parents, authorName: "", authorEmail: "",
               authorDate: .now, commitDate: .now, subject: id)
    }

    @Test func producesOneRowPerCommit() {
        let commits = [commit("c", parents: ["b"]), commit("b", parents: ["a"]), commit("a", parents: [])]
        let rows = GraphLayout.layout(commits)
        #expect(rows.map(\.commitID) == ["c", "b", "a"])
    }
}
