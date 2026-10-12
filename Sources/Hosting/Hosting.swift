import Foundation

/// The repository's hosting provider: GitHub or GitLab (including self-hosted).
public protocol HostingProvider: Sendable {
    var remote: RemoteInfo { get }
    var displayName: String { get }

    /// Open PRs/MRs and CI statuses for the given commits, in a single pass:
    /// the provider decides how to fit into the fewest requests.
    /// Commits that aren't on the server or have no CI are left out of the response.
    func snapshot(commits: [String]) async throws -> HostingSnapshot

    /// Links for "open in browser".
    func webURL(forCommit sha: String) -> URL
    func webURL(forBranch name: String) -> URL
    /// The page for creating a PR/MR from a branch into the default branch.
    func newPullRequestURL(source branch: String) -> URL
}

/// What is known about the repository on the hosting provider at the time of the request.
public struct HostingSnapshot: Sendable {
    public var pullRequests: [PullRequest]
    /// CI status by commit sha.
    public var ciStatus: [String: CIStatus]

    public init(pullRequests: [PullRequest], ciStatus: [String: CIStatus]) {
        self.pullRequests = pullRequests
        self.ciStatus = ciStatus
    }
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    /// The PR number (`#123`) or MR number (`!123`).
    public let id: Int
    public let title: String
    public let sourceBranch: String
    public let targetBranch: String
    /// The latest commit of the source branch on the server.
    public let headSHA: String
    public let author: String
    public let webURL: URL
    public let isDraft: Bool
    /// The source branch in a fork: we have no local branch with that name.
    public let isCrossRepository: Bool
    /// CI for the latest commit.
    public let ciStatus: CIStatus?

    public init(id: Int, title: String, sourceBranch: String, targetBranch: String, headSHA: String,
                author: String, webURL: URL, isDraft: Bool, isCrossRepository: Bool, ciStatus: CIStatus?) {
        self.id = id
        self.title = title
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.headSHA = headSHA
        self.author = author
        self.webURL = webURL
        self.isDraft = isDraft
        self.isCrossRepository = isCrossRepository
        self.ciStatus = ciStatus
    }
}

public enum CIStatus: String, Sendable {
    case pending, running, success, failed, canceled, skipped

    /// The status is final: it can be cached and no longer queried.
    public var isFinal: Bool {
        switch self {
        case .pending, .running: false
        case .success, .failed, .canceled, .skipped: true
        }
    }
}

/// An error from calling the hosting provider's API, with a user-facing message.
public struct HostingError: Error, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Which hosting provider a remote uses.
public enum RemoteKind: Sendable, Hashable {
    case github
    case gitlab
    case unknown
}

/// A parsed remote URL: host, owner (for GitLab, the group path), and project name.
public struct RemoteInfo: Sendable, Hashable {
    public let kind: RemoteKind
    /// The host without port and login: `github.com`, `gitlab.example.com`.
    public let host: String
    public let owner: String
    public let repo: String

    public init(kind: RemoteKind, host: String, owner: String, repo: String) {
        self.kind = kind
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    /// `owner/repo`.
    public var fullName: String { "\(owner)/\(repo)" }

    /// The project's address in the browser.
    public var webURL: URL {
        URL(string: "https://\(host)/\(fullName)")!
    }

    /// Parses `https://host/owner/repo.git`, `ssh://git@host:port/owner/repo.git`
    /// and `git@host:owner/repo.git`.
    public static func parse(remoteURL: String) -> RemoteInfo? {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }

        var host: String
        let path: String
        if let r = s.range(of: "://") {
            // https://user@host:port/owner/repo, ssh://git@host:port/owner/repo
            let rest = s[r.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            // In the URL form, a colon after the host is always a port.
            if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        } else if let colon = s.firstIndex(of: ":") {
            // git@host:owner/repo: after the colon comes the path.
            host = String(s[..<colon])
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        host = host.lowercased()

        let parts = path.split(separator: "/").map(String.init)
        guard !host.isEmpty, parts.count >= 2, let repo = parts.last else { return nil }
        let owner = parts.dropLast().joined(separator: "/")
        let kind: RemoteKind = host == "github.com" ? .github
            : host.contains("gitlab") ? .gitlab : .unknown
        return RemoteInfo(kind: kind, host: host, owner: owner, repo: repo)
    }
}
