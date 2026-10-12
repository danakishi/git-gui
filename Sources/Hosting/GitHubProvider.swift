import Foundation

/// GitHub via the GraphQL API: open PRs and CI statuses come in a single request
/// costing one point of the rate limit, however many commits we ask about.
public struct GitHubProvider: HostingProvider {
    public let remote: RemoteInfo
    private let token: String
    private let endpoint: URL
    private let transport: HTTPTransport

    /// We don't ask about more commits in one request; the rest wait for the next one.
    public static let maxCommitsPerQuery = 100

    public init(
        remote: RemoteInfo,
        token: String,
        endpoint: URL = URL(string: "https://api.github.com/graphql")!,
        transport: @escaping HTTPTransport = HTTP.urlSession
    ) {
        self.remote = remote
        self.token = token
        self.endpoint = endpoint
        self.transport = transport
    }

    public var displayName: String { "GitHub" }

    public func snapshot(commits: [String]) async throws -> HostingSnapshot {
        let shas = Array(commits.filter(Self.isSHA).prefix(Self.maxCommitsPerQuery))
        let data: SnapshotData = try await query(Self.snapshotQuery(commitCount: shas.count), variables: Self.variables(remote, shas))
        guard let repo = data.repository else {
            throw HostingError("Repository \(remote.fullName) was not found on GitHub, or access is denied")
        }

        var ci: [String: CIStatus] = [:]
        for (sha, status) in repo.commits { ci[sha] = status }

        let prs = repo.pullRequests.nodes.compactMap { node -> PullRequest? in
            guard let url = URL(string: node.url) else { return nil }
            let headCI = node.commits.nodes.first?.commit.statusCheckRollup?.status
            if let headCI { ci[node.headRefOid] = headCI }
            return PullRequest(
                id: node.number, title: node.title,
                sourceBranch: node.headRefName, targetBranch: node.baseRefName,
                headSHA: node.headRefOid, author: node.author?.login ?? "",
                webURL: url, isDraft: node.isDraft, isCrossRepository: node.isCrossRepository,
                ciStatus: headCI
            )
        }
        return HostingSnapshot(pullRequests: prs, ciStatus: ci)
    }

    /// The login of the token's owner, used to verify the token in Settings.
    public static func viewerLogin(token: String, transport: @escaping HTTPTransport = HTTP.urlSession) async throws -> String {
        let probe = GitHubProvider(remote: RemoteInfo(kind: .github, host: "github.com", owner: "", repo: ""),
                                   token: token, transport: transport)
        let data: ViewerData = try await probe.query("query { viewer { login } }", variables: [:])
        return data.viewer.login
    }

    public func webURL(forCommit sha: String) -> URL {
        remote.webURL.appending(path: "commit/\(sha)")
    }

    public func webURL(forBranch name: String) -> URL {
        remote.webURL.appending(path: "tree/\(name)")
    }

    public func newPullRequestURL(source branch: String) -> URL {
        // Without a base, GitHub fills in the default branch itself.
        var c = URLComponents(url: remote.webURL.appending(path: "compare/\(branch)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "expand", value: "1")]
        return c.url!
    }

    // MARK: Request

    static func snapshotQuery(commitCount: Int) -> String {
        let params = (0..<commitCount).map { ", $c\($0): GitObjectID!" }.joined()
        let objects = (0..<commitCount).map {
            "    c\($0): object(oid: $c\($0)) { ... on Commit { oid statusCheckRollup { state } } }\n"
        }.joined()
        return """
        query($owner: String!, $name: String!\(params)) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft isCrossRepository
                headRefName baseRefName headRefOid
                author { login }
                commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
              }
            }
        \(objects)  }
        }
        """
    }

    static func variables(_ remote: RemoteInfo, _ shas: [String]) -> [String: String] {
        var v = ["owner": remote.owner, "name": remote.repo]
        for (i, sha) in shas.enumerated() { v["c\(i)"] = sha }
        return v
    }

    static func isSHA(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy(\.isHexDigit)
    }

    private func query<T: Decodable>(_ query: String, variables: [String: String]) async throws -> T {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitGui", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        request.timeoutInterval = 30

        let (body, response) = try await transport(request)
        switch response.statusCode {
        case 200: break
        case 401:
            throw HostingError("GitHub rejected the token: it is invalid or has been revoked")
        case 403, 429:
            throw HostingError(Self.rateLimitMessage(response) ?? "GitHub denied access (\(response.statusCode))")
        default:
            throw HostingError("GitHub responded with \(response.statusCode)")
        }

        let decoded: GraphQLResponse<T>
        do {
            decoded = try JSONDecoder().decode(GraphQLResponse<T>.self, from: body)
        } catch {
            throw HostingError("Could not parse the GitHub response: \(error)")
        }
        // If there is no data at all, show the error. Partial errors (for example,
        // NOT_FOUND for a single object) don't affect the rest of the response.
        if let data = decoded.data { return data }
        let messages = (decoded.errors ?? []).map(\.message)
        if decoded.errors?.contains(where: { $0.type == "RATE_LIMITED" }) == true {
            throw HostingError("GitHub API rate limit exceeded")
        }
        throw HostingError("GitHub error: " + (messages.isEmpty ? "empty response" : messages.joined(separator: "; ")))
    }

    private static func rateLimitMessage(_ response: HTTPURLResponse) -> String? {
        guard response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" else { return nil }
        if let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) {
            let time = Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened)
            return "GitHub API rate limit exceeded until \(time)"
        }
        return "GitHub API rate limit exceeded"
    }
}

// MARK: Response models

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
    let type: String?
}

private struct ViewerData: Decodable {
    struct Viewer: Decodable { let login: String }
    let viewer: Viewer
}

private struct SnapshotData: Decodable {
    let repository: RepositoryNode?
}

private struct Rollup: Decodable {
    let state: String

    /// `EXPECTED`: the check is required but hasn't started yet.
    var status: CIStatus? {
        switch state {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failed
        case "PENDING", "EXPECTED": .pending
        default: nil
        }
    }
}

private struct CommitNode: Decodable {
    let oid: String
    let statusCheckRollup: Rollup?
}

private struct PullRequestNode: Decodable {
    struct Author: Decodable { let login: String }
    struct Commits: Decodable {
        struct Item: Decodable { let commit: CommitNode }
        let nodes: [Item]
    }

    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let isCrossRepository: Bool
    let headRefName: String
    let baseRefName: String
    let headRefOid: String
    let author: Author?
    let commits: Commits
}

/// `repository` with fields `c0`, `c1`, …, one per requested commit.
private struct RepositoryNode: Decodable {
    struct PullRequests: Decodable { let nodes: [PullRequestNode] }

    let pullRequests: PullRequests
    let commits: [(String, CIStatus)]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        pullRequests = try c.decode(PullRequests.self, forKey: Key(stringValue: "pullRequests"))
        var commits: [(String, CIStatus)] = []
        for key in c.allKeys where key.stringValue.hasPrefix("c") && key.stringValue.dropFirst().allSatisfy(\.isNumber) {
            // If the commit isn't on the server, it's null; if it isn't a commit (a tree, blob), it's an empty object.
            guard let node = (try? c.decodeIfPresent(CommitNode.self, forKey: key)) ?? nil,
                  let status = node.statusCheckRollup?.status else { continue }
            commits.append((node.oid, status))
        }
        self.commits = commits
    }
}
