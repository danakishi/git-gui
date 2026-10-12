import Foundation
import Testing
@testable import GitCore

/// Stage 4 operations on real git in a temporary directory.
@Suite("History: merge, rebase, undo", .serialized)
struct HistoryTests {
    /// A temporary repository: `main` with a single commit of file `a.txt`.
    struct Sandbox {
        let repo: GitRepository
        let dir: URL

        init() async throws {
            dir = FileManager.default.temporaryDirectory
                .appending(path: "gitgui-history-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            repo = GitRepository(dir)
            try await repo.run(["init", "-q", "-b", "main"])
            try await repo.run(["config", "user.name", "Test"])
            try await repo.run(["config", "user.email", "test@example.com"])
            try await commit("a.txt", "base\n", "init")
        }

        func write(_ name: String, _ text: String) throws {
            try text.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: dir.appending(path: name), encoding: .utf8)
        }

        func commit(_ name: String, _ text: String, _ message: String) async throws {
            try write(name, text)
            try await repo.stageAll()
            try await repo.commit(message: message)
        }

        func subjects(_ rev: String = "HEAD") async throws -> [String] {
            try await repo.run(["log", "--format=%s", rev]).text.split(separator: "\n").map(String.init)
        }

        func sha(_ rev: String) async throws -> String {
            try await repo.run(["rev-parse", rev]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// `main` and `feature` change `a.txt` differently; HEAD is on `main`.
        func diverge() async throws {
            try await repo.createBranch("feature", checkout: true)
            try await commit("a.txt", "feature\n", "feature change")
            try await repo.checkout(branch: "main")
            try await commit("a.txt", "main\n", "main change")
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func mergeConflictResolvedAndContinued() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.diverge()

        await #expect(throws: GitError.self) { try await s.repo.merge("feature") }
        let state = try #require(try await s.repo.operationState())
        #expect(state.kind == .merge)
        #expect(state.target == (try await s.sha("feature")))
        #expect(try await s.repo.status().entries.contains { $0.isConflict })

        try await s.repo.resolveConflict("a.txt", ours: false)
        try await s.repo.continueOperation(.merge)
        #expect(try await s.repo.operationState() == nil)
        #expect(try s.read("a.txt") == "feature\n")
        #expect(try await s.repo.log(limit: 1).first?.isMerge == true)
    }

    @Test func rebaseConflictReportsProgressAndAborts() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.diverge()
        let before = try await s.sha("feature")

        await #expect(throws: GitError.self) { try await s.repo.rebase(onto: "main", branch: "feature") }
        let state = try #require(try await s.repo.operationState())
        #expect(state.kind == .rebase)
        #expect(state.branch == "feature")
        #expect(state.step == 1)
        #expect(state.total == 1)
        #expect(state.target == (try await s.sha("main")))

        try await s.repo.abortOperation(.rebase)
        #expect(try await s.repo.operationState() == nil)
        #expect(try await s.sha("feature") == before)
    }

    @Test func cherryPickConflictSkipped() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.diverge()

        await #expect(throws: GitError.self) { try await s.repo.cherryPick(try await s.sha("feature")) }
        #expect(try await s.repo.operationState()?.kind == .cherryPick)
        try await s.repo.skipOperation(.cherryPick)
        #expect(try await s.repo.operationState() == nil)
        #expect(try await s.subjects() == ["main change", "init"])
    }

    @Test func fastForwardAndMergeModes() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.repo.createBranch("feature", checkout: true)
        try await s.commit("b.txt", "b\n", "add b")
        try await s.repo.checkout(branch: "main")

        // A non-current branch can only be fast-forwarded.
        try await s.repo.createBranch("old", at: "main", checkout: false)
        try await s.repo.fastForward(branch: "old", to: "feature")
        #expect(try await s.sha("old") == (try await s.sha("feature")))

        try await s.repo.merge("feature", mode: .noFastForward)
        #expect(try await s.repo.log(limit: 1).first?.isMerge == true)

        try await s.repo.checkout(branch: "feature")
        try await s.commit("c.txt", "c\n", "add c")
        // main moved ahead with a merge commit, feature with its own: fast-forward is impossible.
        await #expect(throws: GitError.self) { try await s.repo.fastForward(branch: "main", to: "feature") }
        await #expect(throws: GitError.self) { try await s.repo.merge("main", mode: .fastForwardOnly) }
    }

    @Test func resetModes() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.commit("a.txt", "two\n", "second")

        try await s.repo.reset(to: "HEAD~1", mode: .soft)
        #expect(try await s.repo.status().entries.first?.isStaged == true)
        try await s.repo.reset(to: "HEAD", mode: .mixed)
        #expect(try await s.repo.status().entries.first?.isStaged == false)
        try await s.repo.reset(to: "HEAD", mode: .hard)
        #expect(try await s.repo.status().entries.isEmpty)
        #expect(try s.read("a.txt") == "base\n")
    }

    @Test func undoCommitCheckoutAndMerge() async throws {
        let s = try await Sandbox()
        defer { s.remove() }

        // Commit: the changes return to the index.
        try await s.commit("a.txt", "two\n", "second")
        var undo = try #require(try await s.repo.undoAction())
        #expect(undo.message == "commit: second")
        try await s.repo.undo(undo)
        #expect(try await s.subjects() == ["init"])
        #expect(try await s.repo.status().entries.first?.isStaged == true)

        // Undoing again undoes the undo.
        undo = try #require(try await s.repo.undoAction())
        try await s.repo.undo(undo)
        #expect(try await s.subjects() == ["second", "init"])

        // Branch checkout.
        try await s.repo.createBranch("feature", checkout: true)
        undo = try #require(try await s.repo.undoAction())
        #expect(undo.kind == .checkout("main"))
        try await s.repo.undo(undo)
        #expect(try await s.repo.head() == .branch(name: "main", sha: try await s.sha("main")))

        // Merge: the branch returns to its previous commit.
        try await s.repo.checkout(branch: "feature")
        try await s.commit("b.txt", "b\n", "add b")
        try await s.repo.checkout(branch: "main")
        let before = try await s.sha("main")
        try await s.repo.merge("feature", mode: .noFastForward)
        undo = try #require(try await s.repo.undoAction())
        #expect(undo.kind == .reset(to: before, soft: false))
        try await s.repo.undo(undo)
        #expect(try await s.sha("main") == before)
        #expect(try await s.repo.status().entries.isEmpty)
    }

    @Test func undoSkipsAbortedMerge() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.diverge()
        let before = try await s.sha("main~1")

        await #expect(throws: GitError.self) { try await s.repo.merge("feature") }
        try await s.repo.abortOperation(.merge)
        // An aborted merge didn't move HEAD: what came before it is undone.
        let undo = try #require(try await s.repo.undoAction())
        #expect(undo.message == "commit: main change")
        #expect(undo.kind == .reset(to: before, soft: true))
    }

    @Test func undoRebaseOfAnotherBranch() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.repo.createBranch("feature", checkout: true)
        try await s.commit("f.txt", "f\n", "feat")
        try await s.repo.checkout(branch: "main")
        try await s.commit("m.txt", "m\n", "main2")
        let before = try await s.sha("feature")

        // Started from main: before `(start)` in the HEAD reflog is the tip of main, not feature.
        try await s.repo.rebase(onto: "main", branch: "feature")
        #expect(try await s.sha("feature") != before)
        let undo = try #require(try await s.repo.undoAction())
        #expect(undo.kind == .reset(to: before, soft: false))
        try await s.repo.undo(undo)
        #expect(try await s.sha("feature") == before)
    }

    @Test func undoInteractiveRebaseAndDetachedRebase() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.commit("one.txt", "1\n", "one")
        try await s.commit("two.txt", "2\n", "two")
        let before = try await s.sha("HEAD")
        let commits = try await s.repo.commits(from: "main~2")
        try await s.repo.interactiveRebase(base: try await s.sha("main~2"), steps: [
            RebaseStep(sha: commits[1].id, action: .pick),
            RebaseStep(sha: commits[0].id, action: .pick),
        ])
        #expect(try await s.subjects() == ["one", "two", "init"])
        var undo = try #require(try await s.repo.undoAction())
        try await s.repo.undo(undo)
        #expect(try await s.sha("HEAD") == before)

        // On a detached HEAD there's no branch entry: roll back via the HEAD reflog to `(start)`.
        try await s.repo.checkout(commit: before)
        try await s.repo.interactiveRebase(base: try await s.sha("HEAD~2"), steps: [
            RebaseStep(sha: commits[0].id, action: .drop),
            RebaseStep(sha: commits[1].id, action: .pick),
        ])
        #expect(try await s.subjects() == ["two", "init"])
        undo = try #require(try await s.repo.undoAction())
        #expect(undo.kind == .reset(to: before, soft: false))
    }

    @Test func interactiveRebaseRewritesHistory() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.commit("one.txt", "1\n", "one")
        try await s.commit("two.txt", "2\n", "two")
        try await s.commit("three.txt", "3\n", "three")
        try await s.commit("four.txt", "4\n", "four")
        let commits = try await s.repo.commits(from: "main~4")
        #expect(commits.map(\.subject) == ["one", "two", "three", "four"])
        let sha = Dictionary(uniqueKeysWithValues: commits.map { ($0.subject, $0.id) })

        // Move four forward and rename it, merge three into two, drop one.
        try await s.repo.interactiveRebase(base: try await s.sha("main~4"), steps: [
            RebaseStep(sha: sha["four"]!, action: .reword("four, it's renamed\n\nwith body")),
            RebaseStep(sha: sha["two"]!, action: .pick),
            RebaseStep(sha: sha["three"]!, action: .fixup),
            RebaseStep(sha: sha["one"]!, action: .drop),
        ])

        #expect(try await s.repo.operationState() == nil)
        #expect(try await s.subjects() == ["two", "four, it's renamed", "init"])
        #expect(try await s.repo.message(of: "HEAD~1").contains("with body"))
        #expect(!FileManager.default.fileExists(atPath: s.dir.appending(path: "one.txt").path))
        #expect(try s.read("three.txt") == "3\n")
    }

    @Test func interactiveRebaseStopsOnEdit() async throws {
        let s = try await Sandbox()
        defer { s.remove() }
        try await s.commit("one.txt", "1\n", "one")
        try await s.commit("two.txt", "2\n", "two")
        let commits = try await s.repo.commits(from: "main~2")

        try await s.repo.interactiveRebase(base: try await s.sha("main~2"), steps: [
            RebaseStep(sha: commits[0].id, action: .edit),
            RebaseStep(sha: commits[1].id, action: .pick),
        ])
        let state = try #require(try await s.repo.operationState())
        #expect(state.kind == .rebase)
        #expect(state.step == 1)
        #expect(state.total == 2)

        try await s.commit("one.txt", "1 fixed\n", "unused")
        try await s.repo.run(["reset", "--soft", "HEAD~1"])
        try await s.repo.commit(message: "one", amend: true)
        try await s.repo.continueOperation(.rebase)
        #expect(try await s.repo.operationState() == nil)
        #expect(try await s.subjects() == ["two", "one", "init"])
        #expect(try s.read("one.txt") == "1 fixed\n")
    }

    @Test func parsesCheckoutReflogMessage() {
        #expect(GitRepository.checkoutSource("checkout: moving from main to feature/x") == "main")
        #expect(GitRepository.checkoutSource("commit: fix") == nil)
        #expect(GitRepository.shellQuote("it's") == "'it'\\''s'")
    }
}
