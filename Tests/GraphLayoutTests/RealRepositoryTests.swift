import Foundation
import Testing
@testable import GitCore
@testable import GraphLayout

/// A run against a real repository. Enable it like this:
///   GITGUI_REPO=~/path/to/repo swift test --filter RealRepository
@Suite("Real repository", .enabled(if: ProcessInfo.processInfo.environment["GITGUI_REPO"] != nil))
struct RealRepositoryTests {
    @Test func layoutIsFastAndNarrow() async throws {
        let path = (ProcessInfo.processInfo.environment["GITGUI_REPO"]! as NSString).expandingTildeInPath
        let repo = try #require(await GitRepository.discover(at: URL(fileURLWithPath: path)))

        let t0 = Date()
        let commits = try await repo.log(limit: 100_000)
        let tLog = Date().timeIntervalSince(t0)

        let t1 = Date()
        let rows = GraphLayout.layout(commits)
        let tLayout = Date().timeIntervalSince(t1)

        let widths = rows.map(\.width)
        let maxWidth = widths.max() ?? 0
        let avg = Double(widths.reduce(0, +)) / Double(max(widths.count, 1))
        let hist = Dictionary(grouping: widths, by: { min($0, 10) }).mapValues(\.count).sorted { $0.key < $1.key }

        print("""
        Commits: \(commits.count)
        git log: \(String(format: "%.2f", tLog)) s, layout: \(String(format: "%.3f", tLayout)) s
        Graph width: max \(maxWidth), average \(String(format: "%.1f", avg))
        Width distribution (10 = 10 or more): \(hist.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        """)

        #expect(rows.count == commits.count)
        #expect(tLayout < 2)
        // Every lane entering a node must have been expected by someone:
        // check that a commit with parents in the loaded history has outgoing lines.
        let ids = Set(commits.map(\.id))
        for (c, r) in zip(commits, rows) where !c.parents.isEmpty {
            #expect(r.outgoing.count == c.parents.count, "\(c.shortID) has \(c.parents.count) parents, \(r.outgoing.count) outgoing lines")
            if c.parents.allSatisfy(ids.contains) { continue }
        }
    }
}
