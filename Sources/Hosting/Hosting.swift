import Foundation
import GitCore

/// The repository's hosting provider: GitHub or GitLab (including self-hosted).
/// The implementations are in stage 3.
public protocol HostingProvider: Sendable {
    var displayName: String { get }

    /// Open PRs/MRs, keyed by source branch name.
    func openPullRequests() async throws -> [PullRequest]

    /// CI status for a commit.
    func ciStatus(for sha: String) async throws -> CIStatus?

    /// A browser link to a commit, branch, or PR.
    func webURL(forCommit sha: String) -> URL
    func webURL(forBranch name: String) -> URL
}

public struct PullRequest: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let sourceBranch: String
    public let targetBranch: String
    public let author: String
    public let webURL: URL
    public let isDraft: Bool
}

public enum CIStatus: String, Sendable {
    case pending, running, success, failed, canceled, skipped
}

/// Determines the hosting provider from the remote's URL.
public enum RemoteKind: Sendable, Hashable {
    case github
    case gitlab(host: String)
    case unknown

    /// Parses `https://host/owner/repo.git` and `git@host:owner/repo.git`.
    public static func detect(remoteURL: String) -> (kind: RemoteKind, owner: String, repo: String)? {
        var s = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s.removeLast(4) }

        let host: String
        let path: String
        if let r = s.range(of: "://") {
            // https://host/owner/repo
            let rest = s[r.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash]).split(separator: "@").last.map(String.init) ?? ""
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = s.firstIndex(of: ":") {
            // git@host:owner/repo
            host = String(s[..<colon]).split(separator: "@").last.map(String.init) ?? ""
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let repo = parts.last else { return nil }
        let owner = parts.dropLast().joined(separator: "/")
        let kind: RemoteKind = host == "github.com" ? .github
            : host.contains("gitlab") ? .gitlab(host: host) : .unknown
        return (kind, owner, repo)
    }
}
