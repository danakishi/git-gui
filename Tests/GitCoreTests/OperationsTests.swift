import Foundation
import Testing
@testable import GitCore

/// Stage 2 operations on real git in a temporary directory.
@Suite("Git operations", .serialized)
struct OperationsTests {
    /// An empty repository with one commit and a configured author.
    private func makeRepo() async throws -> (GitRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "gitgui-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = GitRepository(dir)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Test"])
        try await repo.run(["config", "user.email", "test@example.com"])
        try write(dir, "a.txt", lines(1...10))
        try await repo.stageAll()
        try await repo.commit(message: "init")
        return (repo, dir)
    }

    private func lines(_ r: ClosedRange<Int>) -> String {
        r.map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    private func write(_ dir: URL, _ name: String, _ text: String) throws {
        try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func stageUnstageAndCommit() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir, "a.txt", lines(1...11))
        try write(dir, "new.txt", "hello\n")
        var status = try await repo.status()
        #expect(status.entries.count == 2)
        #expect(status.entries.allSatisfy { !$0.isStaged })

        try await repo.stage(["new.txt"])
        status = try await repo.status()
        #expect(status.entries.first { $0.path == "new.txt" }?.index == .added)
        #expect(status.entries.first { $0.path == "a.txt" }?.isStaged == false)

        try await repo.unstage(["new.txt"])
        status = try await repo.status()
        #expect(status.entries.first { $0.path == "new.txt" }?.index == .untracked)

        try await repo.stageAll()
        try await repo.commit(message: "second\n\nbody line")
        status = try await repo.status()
        #expect(status.entries.isEmpty)
        let msg = try await repo.message(of: "HEAD")
        #expect(msg.trimmingCharacters(in: .newlines) == "second\n\nbody line")

        try await repo.commit(message: "second, amended", amend: true)
        let log = try await repo.log()
        #expect(log.count == 2)
        #expect(log[0].subject == "second, amended")
    }

    @Test func stageAndUnstageSingleHunk() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two changes far apart produce two hunks.
        var text = (1...10).map { "line \($0)" }
        text[0] = "LINE 1"
        text[9] = "LINE 10"
        try write(dir, "a.txt", text.joined(separator: "\n") + "\n")

        let file = try #require(DiffParser.parse(try await repo.workingDiff(staged: false)).first)
        #expect(file.hunks.count == 2)

        try await repo.apply(patch: file.patch(hunk: file.hunks[0]), toIndex: true, reverse: false)
        let staged = try #require(DiffParser.parse(try await repo.workingDiff(staged: true)).first)
        #expect(staged.hunks.count == 1)
        #expect(staged.hunks[0].lines.contains { $0.kind == .addition && $0.text == "LINE 1" })
        let unstaged = try #require(DiffParser.parse(try await repo.workingDiff(staged: false)).first)
        #expect(unstaged.hunks.count == 1)
        #expect(unstaged.hunks[0].lines.contains { $0.kind == .addition && $0.text == "LINE 10" })

        // And back out of the index.
        try await repo.apply(patch: staged.patch(hunk: staged.hunks[0]), toIndex: true, reverse: true)
        #expect(try await repo.workingDiff(staged: true).isEmpty)

        // Discard a single hunk in the working tree.
        let again = try #require(DiffParser.parse(try await repo.workingDiff(staged: false)).first)
        try await repo.apply(patch: again.patch(hunk: again.hunks[1]), toIndex: false, reverse: true)
        let rest = try #require(DiffParser.parse(try await repo.workingDiff(staged: false)).first)
        #expect(rest.hunks.count == 1)
        #expect(rest.hunks[0].lines.contains { $0.text == "LINE 1" })
    }

    @Test func discardFiles() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir, "a.txt", "changed\n")
        try write(dir, "junk.txt", "x\n")
        let status = try await repo.status()
        try await repo.discard(status.entries)
        #expect(try await repo.status().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "junk.txt").path))
        #expect(try String(contentsOf: dir.appending(path: "a.txt"), encoding: .utf8) == lines(1...10))
    }

    @Test func branchesAndTags() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await repo.createBranch("feature", checkout: true)
        #expect(try await repo.head() == .branch(name: "feature", sha: try await repo.head().sha!))
        try write(dir, "f.txt", "f\n")
        try await repo.stageAll()
        try await repo.commit(message: "feature work")

        try await repo.renameBranch("feature", to: "feature-2")
        var refs = try await repo.refs()
        #expect(refs.contains { $0.kind == .localBranch && $0.shortName == "feature-2" && $0.isHead })

        try await repo.createTag("v1", message: "release one")
        try await repo.createTag("light")
        refs = try await repo.refs()
        let v1 = try #require(refs.first { $0.shortName == "v1" })
        #expect(v1.kind == .tag)
        #expect(v1.target == (try await repo.head().sha))

        try await repo.checkout(branch: "main")
        // The branch isn't merged: a soft delete must fail, a hard one must succeed.
        await #expect(throws: GitError.self) { try await repo.deleteBranch("feature-2", force: false) }
        try await repo.deleteBranch("feature-2", force: true)
        try await repo.deleteTag("light")
        refs = try await repo.refs()
        #expect(!refs.contains { $0.shortName == "feature-2" })
        #expect(!refs.contains { $0.shortName == "light" })

        let sha = try #require(try await repo.head().sha)
        try await repo.checkout(commit: sha)
        #expect(try await repo.head() == .detached(sha: sha))
    }

    @Test func stash() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir, "a.txt", "stashed\n")
        try write(dir, "u.txt", "untracked\n")
        try await repo.stashPush(message: "my work")
        #expect(try await repo.status().entries.isEmpty)

        let list = try await repo.stashList()
        #expect(list.count == 1)
        #expect(list[0].index == 0)
        #expect(list[0].message.hasSuffix("my work"))
        #expect(list[0].ref == "stash@{0}")

        // A stash diff is shown the same way as a commit.
        let patch = try await repo.diff(of: list[0].ref)
        #expect(patch.contains("+stashed"))

        try await repo.stashApply(list[0], pop: false)
        #expect(try await repo.status().entries.count == 2)
        try await repo.discard(try await repo.status().entries)

        try await repo.stashDrop(list[0])
        #expect(try await repo.stashList().isEmpty)
    }

    @Test func observerSeesInvocations() async throws {
        let (repo, dir) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let box = InvocationBox()
        GitRunner.observer = { box.append($0) }
        defer { GitRunner.observer = nil }
        try await repo.stageAll()
        _ = try await repo.status()
        // The observer is global: parallel test suites write to it too.
        // We take only our own directory — which also checks that it was recorded.
        let seen = box.all.filter { $0.directory == dir }
        #expect(seen.contains { $0.arguments.first == "add" && $0.isMutating })
        #expect(seen.contains { $0.arguments.first == "status" && !$0.isMutating })
    }

    @Test func readOnlySubcommandsAreNotMutating() {
        func inv(_ args: [String]) -> GitInvocation {
            GitInvocation(id: UUID(), date: .now, arguments: args, directory: nil, exitCode: 0, stderr: "", duration: 0)
        }
        #expect(!inv(["stash", "list", "--format=x"]).isMutating)
        #expect(inv(["stash", "push", "-q"]).isMutating)
        #expect(!inv(["remote"]).isMutating)
        #expect(!inv(["remote", "-v"]).isMutating)
        #expect(inv(["remote", "add", "o", "url"]).isMutating)
        #expect(!inv(["remote", "get-url", "origin"]).isMutating)
        #expect(!inv(["tag", "-l"]).isMutating)
        #expect(inv(["tag", "v1"]).isMutating)
        #expect(inv(["branch", "-D", "x"]).isMutating)
        #expect(!inv(["log", "-1"]).isMutating)
    }
}

private final class InvocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitInvocation] = []
    func append(_ i: GitInvocation) { lock.lock(); items.append(i); lock.unlock() }
    var all: [GitInvocation] { lock.lock(); defer { lock.unlock() }; return items }
}
