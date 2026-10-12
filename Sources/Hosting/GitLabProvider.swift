import Foundation

/// GitLab (including self-hosted) via the GraphQL API.
///
/// GitLab limits query "complexity" (300 points on 19.x), and a commit's pipeline
/// status costs ~6 points. So commits go in batches:
/// the first together with the MR list, the rest in separate queries.
public struct GitLabProvider: HostingProvider {
    public let remote: RemoteInfo
    private let client: GraphQLClient

    /// Commits per query, leaving some headroom below the complexity limit.
    static let commitsPerQuery = 35

    public init(remote: RemoteInfo, token: String, transport: @escaping HTTPTransport = HTTP.urlSession) {
        self.remote = remote
        self.client = GraphQLClient(service: remote.host, endpoint: Self.endpoint(host: remote.host),
                                    token: token, transport: transport)
    }

    public var displayName: String { "GitLab" }
    public var pullRequestName: String { "merge request" }
    public var pullRequestShortName: String { "MR" }

    public func snapshot(commits: [String]) async throws -> HostingSnapshot {
        let shas = commits.filter(GitHubProvider.isSHA)
        var chunks = stride(from: 0, to: shas.count, by: Self.commitsPerQuery).map {
            Array(shas[$0..<min($0 + Self.commitsPerQuery, shas.count)])
        }
        if chunks.isEmpty { chunks = [[]] }

        var ci: [String: CIStatus] = [:]
        var mergeRequests: [PullRequest] = []
        for (n, chunk) in chunks.enumerated() {
            let withMRs = n == 0
            let data: ProjectData = try await client.query(
                Self.snapshotQuery(commitCount: chunk.count, mergeRequests: withMRs),
                variables: Self.variables(remote, chunk)
            )
            guard let project = data.project else {
                throw HostingError("Project \(remote.fullName) not found on \(remote.host), or you don't have access")
            }
            for (index, status) in project.pipelines where index < chunk.count {
                ci[chunk[index]] = status
            }
            if withMRs {
                mergeRequests = (project.mergeRequests?.nodes ?? []).compactMap { node in
                    guard let iid = Int(node.iid), let url = URL(string: node.webUrl) else { return nil }
                    let headCI = node.headPipeline?.ciStatus
                    if let headCI, let sha = node.diffHeadSha { ci[sha] = headCI }
                    return PullRequest(
                        id: iid, reference: "!\(iid)", title: node.title,
                        sourceBranch: node.sourceBranch, targetBranch: node.targetBranch,
                        headSHA: node.diffHeadSha ?? "", author: node.author?.username ?? "",
                        webURL: url, isDraft: node.draft,
                        isCrossRepository: node.sourceProjectId != node.targetProjectId,
                        ciStatus: headCI
                    )
                }
            }
        }
        return HostingSnapshot(pullRequests: mergeRequests, ciStatus: ci)
    }

    /// The token owner's name, used to validate the token in Settings.
    public static func viewerLogin(host: String, token: String,
                                   transport: @escaping HTTPTransport = HTTP.urlSession) async throws -> String {
        let client = GraphQLClient(service: host, endpoint: endpoint(host: host), token: token, transport: transport)
        let data: ViewerData = try await client.query("query { currentUser { username } }", variables: [:])
        guard let name = data.currentUser?.username else {
            throw HostingError("\(host) rejected the token")
        }
        return name
    }

    public func webURL(forCommit sha: String) -> URL {
        remote.webURL.appending(path: "-/commit/\(sha)")
    }

    public func webURL(forBranch name: String) -> URL {
        remote.webURL.appending(path: "-/tree/\(name)")
    }

    public func newPullRequestURL(source branch: String) -> URL {
        // Without a target branch, GitLab fills in the default branch.
        var c = URLComponents(url: remote.webURL.appending(path: "-/merge_requests/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "merge_request[source_branch]", value: branch)]
        return c.url!
    }

    // MARK: Request

    static func endpoint(host: String) -> URL {
        URL(string: "https://\(host)/api/graphql")!
    }

    static func snapshotQuery(commitCount: Int, mergeRequests: Bool) -> String {
        let params = (0..<commitCount).map { ", $c\($0): String!" }.joined()
        let pipelines = (0..<commitCount).map {
            "    c\($0): pipelines(sha: $c\($0), first: 1) { nodes { status } }\n"
        }.joined()
        let mrs = !mergeRequests ? "" : """
            mergeRequests(state: opened, first: 100, sort: UPDATED_DESC) {
              nodes {
                iid title webUrl draft sourceBranch targetBranch diffHeadSha
                sourceProjectId targetProjectId
                author { username }
                headPipeline { status }
              }
            }

        """
        return """
        query($path: ID!\(params)) {
          project(fullPath: $path) {
        \(mrs)\(pipelines)  }
        }
        """
    }

    static func variables(_ remote: RemoteInfo, _ shas: [String]) -> [String: String] {
        var v = ["path": remote.fullName]
        for (i, sha) in shas.enumerated() { v["c\(i)"] = sha }
        return v
    }
}

// MARK: Response models

private struct ViewerData: Decodable {
    struct User: Decodable { let username: String }
    let currentUser: User?
}

private struct ProjectData: Decodable {
    let project: ProjectNode?
}

private struct Pipeline: Decodable {
    let status: String

    /// Manual runs (`MANUAL`) and scheduled ones count as pending: the pipeline may still start.
    var ciStatus: CIStatus? {
        switch status {
        case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "PENDING", "SCHEDULED", "WAITING_FOR_CALLBACK", "MANUAL":
            .pending
        case "RUNNING", "CANCELING": .running
        case "SUCCESS": .success
        case "FAILED": .failed
        case "CANCELED": .canceled
        case "SKIPPED": .skipped
        default: nil
        }
    }
}

private struct MergeRequestNode: Decodable {
    struct Author: Decodable { let username: String }
    struct HeadPipeline: Decodable {
        let status: String
        var ciStatus: CIStatus? { Pipeline(status: status).ciStatus }
    }

    let iid: String
    let title: String
    let webUrl: String
    let draft: Bool
    let sourceBranch: String
    let targetBranch: String
    let diffHeadSha: String?
    let sourceProjectId: Int?
    let targetProjectId: Int?
    let author: Author?
    let headPipeline: HeadPipeline?
}

/// `project` with fields `c0`, `c1`…: the latest pipeline for each requested commit.
private struct ProjectNode: Decodable {
    struct MergeRequests: Decodable { let nodes: [MergeRequestNode] }
    struct Pipelines: Decodable { let nodes: [Pipeline] }

    let mergeRequests: MergeRequests?
    /// The commit's index in the batch and the status of its pipeline.
    let pipelines: [(Int, CIStatus)]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        mergeRequests = try c.decodeIfPresent(MergeRequests.self, forKey: DynamicKey(stringValue: "mergeRequests"))
        var pipelines: [(Int, CIStatus)] = []
        for key in c.allKeys {
            guard let index = key.commitIndex,
                  let list = (try? c.decodeIfPresent(Pipelines.self, forKey: key)) ?? nil,
                  let status = list.nodes.first?.ciStatus else { continue }
            pipelines.append((index, status))
        }
        self.pipelines = pipelines
    }
}
