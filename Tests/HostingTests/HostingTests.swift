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

    @Test func rejectsGarbage() {
        #expect(RemoteInfo.parse(remoteURL: "/local/path/repo") == nil)
        #expect(RemoteInfo.parse(remoteURL: "https://github.com/only-owner") == nil)
    }
}

@Suite("GitHub")
struct GitHubProviderTests {
    let remote = RemoteInfo(kind: .github, host: "github.com", owner: "cli", repo: "cli")
    let headA = String(repeating: "a", count: 40)
    let headB = String(repeating: "b", count: 40)
    let tip = String(repeating: "c", count: 40)
    let missing = String(repeating: "d", count: 40)

    /// Stub: remembers the request and returns the given response.
    final class Stub: @unchecked Sendable {
        var request: URLRequest?
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        var transport: HTTPTransport {
            { [self] request in
                self.request = request
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (body, response)
            }
        }
    }

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
        let pr = snapshot.pullRequests[0]
        #expect(pr.sourceBranch == "feature/x")
        #expect(pr.author == "alice")
        #expect(pr.ciStatus == .failed)
        #expect(snapshot.pullRequests[1].isDraft)
        #expect(snapshot.pullRequests[1].isCrossRepository)
        #expect(snapshot.pullRequests[1].ciStatus == nil)
        #expect(snapshot.ciStatus == [tip: .success, headA: .failed])

        let request = try #require(stub.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer t0ken")
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
