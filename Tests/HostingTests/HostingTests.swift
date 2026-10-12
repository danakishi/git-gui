import Foundation
import Testing
@testable import Hosting

@Suite("Remote URL")
struct RemoteInfoTests {
    @Test(arguments: [
        ("https://github.com/cli/cli.git", RemoteKind.github, "github.com", "cli", "cli"),
        ("git@github.com:paparrot/furniture-app.git", .github, "github.com", "paparrot", "furniture-app"),
        ("ssh://git@github.com/owner/repo", .github, "github.com", "owner", "repo"),
        ("https://user@GitHub.com/owner/repo/", .github, "github.com", "owner", "repo"),
        ("https://gitlab.example.com/acme/platform.git", .gitlab, "gitlab.example.com", "acme", "platform"),
        ("ssh://git@gitlab.example.com:2824/jdoe/app.git", .gitlab, "gitlab.example.com", "jdoe", "app"),
        ("git@gitlab.example.com:group/sub/project.git", .gitlab, "gitlab.example.com", "group/sub", "project"),
        ("https://git.example.com:8443/a/b.git", .unknown, "git.example.com", "a", "b"),
    ])
    func parses(url: String, kind: RemoteKind, host: String, owner: String, repo: String) throws {
        let info = try #require(RemoteInfo.parse(remoteURL: url))
        #expect(info.kind == kind)
        #expect(info.host == host)
        #expect(info.owner == owner)
        #expect(info.repo == repo)
    }

    @Test func knowsOwnGitLabHosts() throws {
        let url = "git@git.example.com:team/app.git"
        #expect(RemoteInfo.parse(remoteURL: url)?.kind == .unknown)
        #expect(RemoteInfo.parse(remoteURL: url, gitlabHosts: ["git.example.com"])?.kind == .gitlab)
    }

    @Test func rejectsGarbage() {
        #expect(RemoteInfo.parse(remoteURL: "/local/path/repo") == nil)
        #expect(RemoteInfo.parse(remoteURL: "https://github.com/only-owner") == nil)
    }
}

/// HTTP stub: remembers requests and returns responses in order (the last one repeats).
final class Stub: @unchecked Sendable {
    var requests: [URLRequest] = []
    var request: URLRequest? { requests.last }
    var status = 200
    var headers: [String: String] = [:]
    var bodies: [Data] = []
    var body: Data {
        get { bodies.first ?? Data() }
        set { bodies = [newValue] }
    }

    var transport: HTTPTransport {
        { [self] request in
            let n = requests.count
            requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (bodies.isEmpty ? Data() : bodies[min(n, bodies.count - 1)], response)
        }
    }

    /// Request body: the GraphQL query and variables.
    func json(_ i: Int) -> (query: String, variables: [String: String]) {
        let obj = (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:]
        return (obj["query"] as? String ?? "", obj["variables"] as? [String: String] ?? [:])
    }
}

@Suite("GitHub")
struct GitHubProviderTests {
    let remote = RemoteInfo(kind: .github, host: "github.com", owner: "cli", repo: "cli")
    let headA = String(repeating: "a", count: 40)
    let headB = String(repeating: "b", count: 40)
    let tip = String(repeating: "c", count: 40)
    let missing = String(repeating: "d", count: 40)

    @Test func buildsSnapshotFromOneQuery() async throws {
        let stub = Stub()
        stub.body = Data("""
        {"data":{"repository":{
          "pullRequests":{"nodes":[
            {"number":12,"title":"Fix","url":"https://github.com/cli/cli/pull/12","isDraft":false,
             "isCrossRepository":false,"headRefName":"feature/x","baseRefName":"trunk","headRefOid":"\(headA)",
             "author":{"login":"alice"},
             "commits":{"nodes":[{"commit":{"oid":"\(headA)","statusCheckRollup":{"state":"FAILURE"}}}]}},
            {"number":13,"title":"WIP","url":"https://github.com/cli/cli/pull/13","isDraft":true,
             "isCrossRepository":true,"headRefName":"patch-1","baseRefName":"trunk","headRefOid":"\(headB)",
             "author":null,"commits":{"nodes":[{"commit":{"oid":"\(headB)","statusCheckRollup":null}}]}}
          ]},
          "c0":{"oid":"\(tip)","statusCheckRollup":{"state":"SUCCESS"}},
          "c1":null,
          "c2":{}
        }}}
        """.utf8)
        let provider = GitHubProvider(remote: remote, token: "t0ken", transport: stub.transport)

        let snapshot = try await provider.snapshot(commits: [tip, missing, headB, "not-a-sha"])

        #expect(snapshot.pullRequests.map(\.id) == [12, 13])
        #expect(snapshot.pullRequests[0].reference == "#12")
        let pr = snapshot.pullRequests[0]
        #expect(pr.sourceBranch == "feature/x")
        #expect(pr.author == "alice")
        #expect(pr.ciStatus == .failed)
        #expect(snapshot.pullRequests[1].isDraft)
        #expect(snapshot.pullRequests[1].isCrossRepository)
        #expect(snapshot.pullRequests[1].ciStatus == nil)
        #expect(snapshot.ciStatus == [tip: .success, headA: .failed])

        let request = try #require(stub.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        let json = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: String])
        // Garbage instead of a sha does not make it into the request.
        #expect(variables == ["owner": "cli", "name": "cli", "c0": tip, "c1": missing, "c2": headB])
        #expect((json["query"] as? String)?.contains("c2: object(oid: $c2)") == true)
    }

    @Test func reportsBadToken() async {
        let stub = Stub()
        stub.status = 401
        let provider = GitHubProvider(remote: remote, token: "x", transport: stub.transport)
        await #expect(throws: HostingError.self) { try await provider.snapshot(commits: []) }
    }

    @Test func reportsRateLimit() async throws {
        let stub = Stub()
        stub.status = 403
        stub.headers = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000"]
        let provider = GitHubProvider(remote: remote, token: "x", transport: stub.transport)
        do {
            _ = try await provider.snapshot(commits: [])
            Issue.record("expected an error")
        } catch let e as HostingError {
            #expect(e.message.lowercased().contains("limit"))
        }
    }

    @Test func reportsMissingRepository() async {
        let stub = Stub()
        stub.body = Data(#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve"}]}"#.utf8)
        let provider = GitHubProvider(remote: remote, token: "x", transport: stub.transport)
        await #expect(throws: HostingError.self) { try await provider.snapshot(commits: []) }
    }

    @Test func webURLs() {
        let provider = GitHubProvider(remote: remote, token: "x")
        #expect(provider.webURL(forCommit: tip).absoluteString == "https://github.com/cli/cli/commit/\(tip)")
        #expect(provider.webURL(forBranch: "feature/x").absoluteString == "https://github.com/cli/cli/tree/feature/x")
        #expect(provider.newPullRequestURL(source: "feature/x").absoluteString
                == "https://github.com/cli/cli/compare/feature/x?expand=1")
    }
}

/// Live request to GitHub with the `gh` token. Run: `GITGUI_LIVE_GITHUB=1 swift test --filter Live`.
@Suite("GitHub live", .enabled(if: ProcessInfo.processInfo.environment["GITGUI_LIVE_GITHUB"] == "1"))
struct LiveGitHubTests {
    @Test func cliRepository() async throws {
        let token = try #require(await GitHubCLI.token(), "requires `gh auth login`")
        let remote = try #require(RemoteInfo.parse(remoteURL: "https://github.com/cli/cli.git"))
        let provider = GitHubProvider(remote: remote, token: token)

        let first = try await provider.snapshot(commits: [])
        #expect(!first.pullRequests.isEmpty)

        // PR heads, queried as regular commits, return the same status.
        let heads = first.pullRequests.prefix(5).map(\.headSHA)
        let second = try await provider.snapshot(commits: heads)
        for pr in first.pullRequests.prefix(5) {
            #expect(second.ciStatus[pr.headSHA] == pr.ciStatus)
        }
        #expect(try await GitHubProvider.viewerLogin(token: token).isEmpty == false)
    }
}

@Suite("GitLab")
struct GitLabProviderTests {
    let remote = RemoteInfo(kind: .gitlab, host: "gitlab.example.com", owner: "group/sub", repo: "app")

    static func sha(_ i: Int) -> String { String(format: "%040x", i) }

    @Test func splitsCommitsIntoBatches() async throws {
        let stub = Stub()
        let head = Self.sha(999)
        stub.bodies = [
            Data("""
            {"data":{"project":{
              "mergeRequests":{"nodes":[
                {"iid":"7","title":"Feature","webUrl":"https://gitlab.example.com/group/sub/app/-/merge_requests/7",
                 "draft":true,"sourceBranch":"feature","targetBranch":"dev","diffHeadSha":"\(head)",
                 "sourceProjectId":2,"targetProjectId":2,"author":{"username":"bob"},"headPipeline":{"status":"RUNNING"}},
                {"iid":"8","title":"Fork","webUrl":"https://gitlab.example.com/group/sub/app/-/merge_requests/8",
                 "draft":false,"sourceBranch":"main","targetBranch":"dev","diffHeadSha":null,
                 "sourceProjectId":5,"targetProjectId":2,"author":null,"headPipeline":null}
              ]},
              "c0":{"nodes":[{"status":"SUCCESS"}]},
              "c1":{"nodes":[]},
              "c2":{"nodes":[{"status":"MANUAL"}]}
            }}}
            """.utf8),
            Data(#"{"data":{"project":{"c0":{"nodes":[{"status":"FAILED"}]},"c4":{"nodes":[{"status":"CANCELED"}]}}}}"#.utf8),
        ]
        let provider = GitLabProvider(remote: remote, token: "glpat", transport: stub.transport)
        let shas = (0..<40).map(Self.sha)

        let snapshot = try await provider.snapshot(commits: shas)

        // 40 commits: 35 in the first request together with MRs, 5 in the second without them.
        #expect(stub.requests.count == 2)
        #expect(stub.requests[0].url?.absoluteString == "https://gitlab.example.com/api/graphql")
        #expect(stub.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer glpat")
        let first = stub.json(0), second = stub.json(1)
        #expect(first.query.contains("mergeRequests"))
        #expect(!second.query.contains("mergeRequests"))
        #expect(first.variables["path"] == "group/sub/app")
        #expect(first.variables["c34"] == shas[34])
        #expect(second.variables["c0"] == shas[35])
        #expect(second.variables["c5"] == nil)

        #expect(snapshot.ciStatus[shas[0]] == .success)
        #expect(snapshot.ciStatus[shas[1]] == nil)
        #expect(snapshot.ciStatus[shas[2]] == .pending)
        #expect(snapshot.ciStatus[shas[35]] == .failed)
        #expect(snapshot.ciStatus[shas[39]] == .canceled)
        #expect(snapshot.ciStatus[head] == .running)

        let mr = try #require(snapshot.pullRequests.first)
        #expect(mr.id == 7)
        #expect(mr.reference == "!7")
        #expect(mr.isDraft)
        #expect(!mr.isCrossRepository)
        #expect(mr.ciStatus == .running)
        #expect(snapshot.pullRequests[1].isCrossRepository)
    }

    @Test func reportsMissingProject() async {
        let stub = Stub()
        stub.body = Data(#"{"data":{"project":null}}"#.utf8)
        let provider = GitLabProvider(remote: remote, token: "x", transport: stub.transport)
        await #expect(throws: HostingError.self) { try await provider.snapshot(commits: []) }
        // With no commits: one request, MRs only.
        #expect(stub.requests.count == 1)
    }

    @Test func webURLs() {
        let provider = GitLabProvider(remote: remote, token: "x")
        let sha = Self.sha(1)
        #expect(provider.webURL(forCommit: sha).absoluteString == "https://gitlab.example.com/group/sub/app/-/commit/\(sha)")
        #expect(provider.webURL(forBranch: "feature/x").absoluteString
                == "https://gitlab.example.com/group/sub/app/-/tree/feature/x")
        #expect(provider.newPullRequestURL(source: "feature/x").absoluteString
                == "https://gitlab.example.com/group/sub/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature/x")
    }
}

/// Live request to GitLab with the `glab` token.
/// Run: `GITGUI_LIVE_GITLAB=https://gitlab.example.com/group/project swift test --filter Live`.
@Suite("GitLab live", .enabled(if: ProcessInfo.processInfo.environment["GITGUI_LIVE_GITLAB"] != nil))
struct LiveGitLabTests {
    @Test func project() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["GITGUI_LIVE_GITLAB"])
        let remote = try #require(RemoteInfo.parse(remoteURL: url, gitlabHosts: [URL(string: url)?.host() ?? ""]))
        let token = try #require(await GitLabCLI.token(host: remote.host), "requires `glab auth login`")
        let provider = GitLabProvider(remote: remote, token: token)

        let first = try await provider.snapshot(commits: [])
        let heads = first.pullRequests.map(\.headSHA).filter { !$0.isEmpty }
        // More than one batch, to check the complexity limit on a real server.
        let commits = Array((heads + heads + heads).prefix(40))
        let second = try await provider.snapshot(commits: commits)
        for pr in first.pullRequests where pr.ciStatus != nil {
            #expect(second.ciStatus[pr.headSHA] == pr.ciStatus)
        }
        #expect(try await GitLabProvider.viewerLogin(host: remote.host, token: token).isEmpty == false)
    }
}
