import Foundation
import Testing
@testable import GitCore

@Suite("git log")
struct LogParserTests {
    @Test func parsesLinearAndMergeCommits() {
        let text = """
        aaaa\0bbbb cccc\0Alice\0alice@x.io\01700000000\01700000010\0Merge branch 'f'
        bbbb\0dddd\0Bob\0bob@x.io\01699999999\01699999999\0Fix: handle NUL\0in subject? no
        eeee\0\0Root\0root@x.io\01600000000\01600000000\0Initial commit
        """
        let commits = GitParsers.parseLog(text)
        #expect(commits.count == 3)
        #expect(commits[0].parents == ["bbbb", "cccc"])
        #expect(commits[0].isMerge)
        #expect(commits[0].authorDate == Date(timeIntervalSince1970: 1_700_000_000))
        // Extra NULs in the last field don't break parsing: everything stays in the subject.
        #expect(commits[1].subject == "Fix: handle NUL\0in subject? no")
        #expect(commits[2].parents.isEmpty)
    }

    @Test func skipsMalformedLines() {
        #expect(GitParsers.parseLog("garbage\n\n").isEmpty)
    }
}

@Suite("git for-each-ref")
struct RefParserTests {
    @Test func classifiesRefs() {
        let text = """
        refs/heads/main\0111\0\0origin/main\0*
        refs/heads/feature\0222\0\0\0
        refs/remotes/origin/main\0111\0\0\0
        refs/remotes/origin/HEAD\0111\0\0\0
        refs/tags/v1.0\0333\0444\0\0
        refs/tags/light\0555\0\0\0
        refs/stash\0666\0\0\0
        """
        let refs = GitParsers.parseRefs(text)
        #expect(refs.count == 6)  // origin/HEAD is skipped

        let main = refs[0]
        #expect(main.kind == .localBranch)
        #expect(main.shortName == "main")
        #expect(main.isHead)
        #expect(main.upstream == "origin/main")

        #expect(refs[1].isHead == false)
        #expect(refs[1].upstream == nil)
        #expect(refs[2].kind == .remoteBranch)
        #expect(refs[2].shortName == "origin/main")

        // An annotated tag points to the peeled commit.
        #expect(refs[3].kind == .tag)
        #expect(refs[3].target == "444")
        #expect(refs[4].target == "555")
        #expect(refs[5].kind == .stash)
    }
}

@Suite("git status --porcelain=v2")
struct StatusParserTests {
    @Test func parsesBranchHeaderAndEntries() {
        let text = """
        # branch.oid 1234
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 M. N... 100644 100644 100644 abc def Sources/a.swift
        1 .M N... 100644 100644 100644 abc def Sources/b.swift
        1 A. N... 000000 100644 100644 000 def new file with spaces.txt
        2 R. N... 100644 100644 100644 abc def R100 new.txt\told.txt
        u UU N... 100644 100644 100644 100644 a b c conflict.txt
        ? untracked.txt
        ! ignored.log
        """
        let s = GitParsers.parseStatus(text)
        #expect(s.branch == "main")
        #expect(s.upstream == "origin/main")
        #expect(s.ahead == 2)
        #expect(s.behind == 1)
        #expect(s.entries.count == 7)

        #expect(s.entries[0].index == .modified && s.entries[0].isStaged)
        #expect(s.entries[1].worktree == .modified && !s.entries[1].isStaged)
        #expect(s.entries[2].path == "new file with spaces.txt")
        #expect(s.entries[3].path == "new.txt" && s.entries[3].originalPath == "old.txt")
        #expect(s.entries[4].isConflict)
        #expect(s.entries[5].index == .untracked)
        #expect(s.entries[6].index == .ignored)
    }

    @Test func detachedHead() {
        let s = GitParsers.parseStatus("# branch.head (detached)\n")
        #expect(s.branch == nil)
        #expect(s.entries.isEmpty)
    }
}

@Suite("Live git", .enabled(if: FileManager.default.fileExists(atPath: "/usr/bin/git")))
struct LiveGitTests {
    /// Create a temporary repository with two commits and a branch, then read it in full.
    @Test func readsTemporaryRepository() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "gitgui-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let env = ["GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@t"]
        func git(_ args: String...) async throws {
            try await GitRunner.run(args, in: dir, environment: env)
        }
        try await git("init", "-q", "-b", "main")
        try "a".write(to: dir.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "a.txt")
        try await git("commit", "-q", "-m", "first")
        try await git("tag", "-a", "v1", "-m", "tag")
        try await git("checkout", "-q", "-b", "feature")
        try "b".write(to: dir.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try await git("add", "b.txt")
        try await git("commit", "-q", "-m", "second")
        try "c".write(to: dir.appending(path: "c.txt"), atomically: true, encoding: .utf8)

        let repo = try #require(await GitRepository.discover(at: dir.appending(path: "a.txt")))
        let commits = try await repo.log()
        #expect(commits.map(\.subject) == ["second", "first"])
        #expect(commits[1].parents.isEmpty)

        let refs = try await repo.refs()
        #expect(refs.map(\.shortName).sorted() == ["feature", "main", "v1"])
        #expect(refs.first { $0.shortName == "feature" }?.isHead == true)
        #expect(refs.first { $0.shortName == "v1" }?.target == commits[1].id)

        let head = try await repo.head()
        #expect(head == .branch(name: "feature", sha: commits[0].id))

        let status = try await repo.status()
        #expect(status.branch == "feature")
        #expect(status.entries.map(\.path) == ["c.txt"])
    }
}
