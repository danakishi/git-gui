import Foundation
import Testing
@testable import GitCore

/// Submodules, worktrees, and LFS on real git.
@Suite("Submodules, worktrees, LFS", .serialized)
struct WorkspaceTests {
    private func makeRepo(_ name: String, in root: URL) async throws -> GitRepository {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = GitRepository(dir)
        try await repo.run(["init", "-q", "-b", "main"])
        try await repo.run(["config", "user.name", "Test"])
        try await repo.run(["config", "user.email", "test@example.com"])
        try "\(name)\n".write(to: dir.appending(path: "README"), atomically: true, encoding: .utf8)
        try await repo.stageAll()
        try await repo.commit(message: "init \(name)")
        return repo
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "gitgui-ws-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // /var is a symlink to /private/var, and git returns the real path. resolvingSymlinksInPath
        // doesn't fit here: it does the opposite and strips /private.
        return URL(fileURLWithPath: String(cString: realpath(root.path, nil)), isDirectory: true)
    }

    @Test func submoduleStatusAndDiff() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = try await makeRepo("lib", in: root)
        let app = try await makeRepo("app", in: root)
        try await GitRunner.run(["-c", "protocol.file.allow=always", "submodule", "add", "-q",
                                 lib.workingDirectory.path, "vendor/lib"], in: app.workingDirectory)
        try await app.commit(message: "add lib")

        var subs = try await app.submodules()
        #expect(subs.map(\.path) == ["vendor/lib"])
        #expect(subs.first?.state == .upToDate)

        // A new commit inside the submodule, an edit on top of it, and junk.
        let inner = GitRepository(app.workingDirectory.appending(path: "vendor/lib"))
        try "more\n".write(to: inner.workingDirectory.appending(path: "README"), atomically: true, encoding: .utf8)
        try await inner.stageAll()
        try await inner.commit(message: "more")
        try "edit\n".write(to: inner.workingDirectory.appending(path: "README"), atomically: true, encoding: .utf8)
        try "junk\n".write(to: inner.workingDirectory.appending(path: "junk.txt"), atomically: true, encoding: .utf8)

        subs = try await app.submodules()
        #expect(subs.first?.state == .otherCommit)
        let entry = try #require(try await app.status().entries.first { $0.path == "vendor/lib" })
        #expect(entry.submodule == StatusEntry.Submodule(commitChanged: true, hasModifications: true, hasUntracked: true))

        let diff = try #require(DiffParser.parse(try await app.workingDiff(staged: false, path: "vendor/lib")).first)
        guard case .submodule(let old?, let new?, let dirty) = diff.special else {
            Issue.record("expected a submodule, got \(String(describing: diff.special))")
            return
        }
        #expect(old != new)
        #expect(dirty)
        #expect(new == (try await inner.head().sha))

        // A regular file is not a submodule.
        try "x\n".write(to: app.workingDirectory.appending(path: "README"), atomically: true, encoding: .utf8)
        #expect(try await app.status().entries.first { $0.path == "README" }?.submodule == nil)
    }

    @Test func worktreesAndBranchesTakenThere() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await makeRepo("main-wt", in: root)
        let other = root.appending(path: "feature-wt").path
        try await repo.run(["worktree", "add", "-q", "-b", "feature", other])

        let list = try await repo.worktrees()
        #expect(list.map(\.path) == [repo.workingDirectory.path, other])
        #expect(list.map(\.branch) == ["main", "feature"])

        let refs = try await repo.refs()
        #expect(refs.first { $0.shortName == "feature" }?.worktreePath == other)
        #expect(refs.first { $0.shortName == "main" }?.worktreePath == repo.workingDirectory.path)

        // A linked worktree has its own git directory, and the common one belongs to the main worktree.
        let dirs = try await GitRepository(URL(fileURLWithPath: other)).gitDirectories()
        #expect(dirs.count == 2)
        #expect(dirs[0].path.hasSuffix(".git/worktrees/feature-wt"))
        #expect(dirs[1].path == repo.workingDirectory.appending(path: ".git").path)
    }

    @Test func lfsPointerDiff() throws {
        let text = """
        diff --git a/big.bin b/big.bin
        index 1111111..2222222 100644
        --- a/big.bin
        +++ b/big.bin
        @@ -1,3 +1,3 @@
         version https://git-lfs.github.com/spec/v1
        -oid sha256:aaaa
        -size 100
        +oid sha256:bbbb
        +size 2048

        """
        let diff = try #require(DiffParser.parse(text).first)
        #expect(diff.special == .lfs(old: LFSPointer(oid: "sha256:aaaa", size: 100),
                                     new: LFSPointer(oid: "sha256:bbbb", size: 2048)))
        let plain = try #require(DiffParser.parse("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n").first)
        #expect(plain.special == nil)
    }

    @Test func parsesSubmoduleStatusFlags() {
        let subs = GitRepository.parseSubmoduleStatus("""
         1111 lib/a (v1.0)
        -2222 lib/b
        +3333 lib/c (heads/main)
        U4444 lib/d
        """)
        #expect(subs.map(\.state) == [.upToDate, .uninitialized, .otherCommit, .conflict])
        #expect(subs.map(\.describe) == ["v1.0", nil, "heads/main", nil])
        #expect(subs[1].path == "lib/b")
    }
}
