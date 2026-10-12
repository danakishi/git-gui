import Foundation
import GitCore
import Hosting
import Observation

/// PRs/MRs and CI statuses for a single repository.
///
/// Refreshed not on every FSEvents event but on open, after
/// fetch/pull/push, on ⌘R, and on a timer: one API request at a time.
@MainActor
@Observable
final class HostingState {
    private(set) var provider: (any HostingProvider)?
    /// The remote used to detect the hosting provider (usually `origin`).
    private(set) var remoteName: String?
    /// Why there is no integration when the hosting provider is recognized but can't be used.
    private(set) var unavailableReason: String?

    private(set) var pullRequests: [PullRequest] = []
    private(set) var ciStatus: [String: CIStatus] = [:]
    /// PRs keyed by the sha of the commit their branch points to.
    private(set) var pullRequestsByCommit: [String: [PullRequest]] = [:]

    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var error: String?
    /// Increments on every data change; the table uses it to decide whether to redraw.
    private(set) var version = 0

    /// How many of the most recent history commits to query in addition to branches.
    static let recentCommits = 30

    var displayName: String? { provider?.displayName }

    /// Re-reads the remote, the token, and the data from the server.
    func refresh(repo: GitRepository, head: String?, refs: [Ref], commits: [Commit]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await configure(repo: repo)
        guard let provider else {
            if !pullRequests.isEmpty || !ciStatus.isEmpty {
                pullRequests = []
                ciStatus = [:]
                version += 1
                relink(refs: refs, commits: commits)
            }
            return
        }

        let wanted = commitsToQuery(head: head, refs: refs, commits: commits)
        do {
            let snapshot = try await provider.snapshot(commits: wanted)
            // Drop incomplete statuses for which the server returned nothing;
            // final ones are kept while the window is open.
            for sha in wanted where ciStatus[sha]?.isFinal == false { ciStatus[sha] = nil }
            ciStatus.merge(snapshot.ciStatus) { _, new in new }
            pullRequests = snapshot.pullRequests
            lastUpdated = .now
            error = nil
            version += 1
        } catch {
            self.error = String(describing: error)
        }
        relink(refs: refs, commits: commits)
    }

    /// Links PRs to commits. Also called after the repository is re-read,
    /// since branches may have moved.
    func relink(refs: [Ref], commits: [Commit]) {
        let loaded = Set(commits.map(\.id))
        var map: [String: [PullRequest]] = [:]
        for pr in pullRequests {
            // First the commit the server considers the PR head; if we don't have it
            // (no fetch yet), then the remote's branch with the same name.
            var sha: String? = loaded.contains(pr.headSHA) ? pr.headSHA : nil
            if sha == nil, !pr.isCrossRepository, let remote = remoteName {
                sha = refs.first { $0.kind == .remoteBranch && $0.shortName == "\(remote)/\(pr.sourceBranch)" }?.target
            }
            if let sha { map[sha, default: []].append(pr) }
        }
        guard map != pullRequestsByCommit else { return }
        pullRequestsByCommit = map
        version += 1
    }

    /// The PR opened from a branch. For a local branch, we look at its upstream.
    func pullRequest(for ref: Ref) -> PullRequest? {
        guard let name = serverBranch(for: ref) else { return nil }
        return pullRequests.first { !$0.isCrossRepository && $0.sourceBranch == name }
    }

    /// Branch name on the server: `x` for `origin/x` and for a local branch whose upstream is `origin/x`.
    func serverBranch(for ref: Ref) -> String? {
        guard let remote = remoteName else { return nil }
        let prefix = remote + "/"
        switch ref.kind {
        case .remoteBranch where ref.shortName.hasPrefix(prefix):
            return String(ref.shortName.dropFirst(prefix.count))
        case .localBranch:
            guard let up = ref.upstream, up.hasPrefix(prefix) else { return nil }
            return String(up.dropFirst(prefix.count))
        default:
            return nil
        }
    }

    // MARK: Internals

    private func configure(repo: GitRepository) async {
        let remotes = (try? await repo.remotes()) ?? []
        let name = remotes.first { $0 == "origin" } ?? remotes.first
        let info: RemoteInfo?
        if let name, let url = try? await repo.remoteURL(name) {
            info = RemoteInfo.parse(remoteURL: url)
        } else {
            info = nil
        }
        remoteName = name

        guard let info else {
            setProvider(nil, reason: nil)
            return
        }
        switch info.kind {
        case .github:
            if let token = await Accounts.shared.gitHubToken() {
                // The provider is stateless and cheap to recreate; this is how a new token gets picked up.
                setProvider(GitHubProvider(remote: info, token: token), reason: nil)
            } else {
                setProvider(nil, reason: "No GitHub token: run `gh auth login` or add a token in Settings (⌘,)")
            }
        case .gitlab:
            setProvider(nil, reason: "GitLab is not supported yet")
        case .unknown:
            setProvider(nil, reason: nil)
        }
    }

    private func setProvider(_ p: (any HostingProvider)?, reason: String?) {
        provider = p
        unavailableReason = reason
        if p == nil { error = nil }
    }

    /// HEAD, local branches, the first commits of the history, and remote branches,
    /// in that order, skipping commits that already have a final status.
    private func commitsToQuery(head: String?, refs: [Ref], commits: [Commit]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        func add(_ sha: String?) {
            guard let sha, ciStatus[sha]?.isFinal != true, seen.insert(sha).inserted else { return }
            result.append(sha)
        }
        add(head)
        refs.filter { $0.kind == .localBranch }.forEach { add($0.target) }
        commits.prefix(Self.recentCommits).forEach { add($0.id) }
        if let remote = remoteName {
            refs.filter { $0.kind == .remoteBranch && $0.shortName.hasPrefix(remote + "/") }.forEach { add($0.target) }
        }
        return Array(result.prefix(GitHubProvider.maxCommitsPerQuery))
    }
}
