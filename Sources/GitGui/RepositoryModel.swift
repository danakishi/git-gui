import Foundation
import GitCore
import Observation

/// State of one open repository: history, refs, HEAD, status.
@MainActor
@Observable
final class RepositoryModel {
    let repo: GitRepository

    private(set) var commits: [Commit] = []
    private(set) var refs: [Ref] = []
    private(set) var head: Head?
    private(set) var status: WorkingTreeStatus?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Refs grouped by commit sha: for the labels on rows.
    private(set) var refsByCommit: [String: [Ref]] = [:]

    static let pageSize = 1000
    private(set) var hasMore = true

    init(_ repo: GitRepository) {
        self.repo = repo
    }

    func reload() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let c = repo.log(limit: Self.pageSize)
            async let r = repo.refs()
            async let h = repo.head()
            async let s = repo.status()
            let (commits, refs, head, status) = try await (c, r, h, s)
            self.commits = commits
            self.refs = refs
            self.head = head
            self.status = status
            self.hasMore = commits.count == Self.pageSize
            self.refsByCommit = Dictionary(grouping: refs, by: \.target)
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Loads the next page of history.
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let more = try await repo.log(limit: Self.pageSize, skip: commits.count)
            commits.append(contentsOf: more)
            hasMore = more.count == Self.pageSize
        } catch {
            self.error = String(describing: error)
        }
    }

    func fetch() async {
        do {
            try await repo.fetch()
            await reload()
        } catch {
            self.error = String(describing: error)
        }
    }
}
