import Foundation

/// High-level access to a single repository.
/// All methods are wrappers around specific git commands.
public struct GitRepository: Sendable, Hashable {
    public let workingDirectory: URL

    public init(_ workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    /// Finds the repository root for an arbitrary path inside it.
    /// Returns `nil` if the path is not inside a git repository.
    public static func discover(at path: URL) async -> GitRepository? {
        // Process won't launch with a file as the working directory.
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        let dir = isDir.boolValue ? path : path.deletingLastPathComponent()
        guard let out = try? await GitRunner.run(["rev-parse", "--show-toplevel"], in: dir) else { return nil }
        let root = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        return GitRepository(URL(fileURLWithPath: root, isDirectory: true))
    }

    @discardableResult
    public func run(_ arguments: [String], check: Bool = true) async throws -> GitOutput {
        try await GitRunner.run(arguments, in: workingDirectory, check: check)
    }

    // MARK: Reading

    /// History of all branches in topological order, in chunks.
    public func log(limit: Int = 500, skip: Int = 0, all: Bool = true) async throws -> [Commit] {
        var args = ["log", "--topo-order", "--format=\(GitParsers.logFormat)",
                    "--max-count=\(limit)", "--skip=\(skip)"]
        if all { args.append("--all") }
        let out = try await run(args)
        return GitParsers.parseLog(out.text)
    }

    /// All branches, tags, and stashes.
    public func refs() async throws -> [Ref] {
        let out = try await run(["for-each-ref", "--format=\(GitParsers.refFormat)",
                                 "refs/heads", "refs/remotes", "refs/tags", "refs/stash"])
        return GitParsers.parseRefs(out.text)
    }

    public func head() async throws -> Head {
        let sym = try await run(["symbolic-ref", "-q", "--short", "HEAD"], check: false)
        let branch = sym.exitCode == 0 ? sym.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let rev = try await run(["rev-parse", "-q", "--verify", "HEAD"], check: false)
        let sha = rev.exitCode == 0 ? rev.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        switch (branch, sha) {
        case let (b?, s?): return .branch(name: b, sha: s)
        case let (nil, s?): return .detached(sha: s)
        case let (b?, nil): return .unborn(branch: b)
        case (nil, nil): return .unborn(branch: "HEAD")
        }
    }

    public func status() async throws -> WorkingTreeStatus {
        let out = try await run(["status", "--porcelain=v2", "--branch", "--untracked-files=all"])
        return GitParsers.parseStatus(out.text)
    }

    /// Full commit message text (subject + body).
    public func message(of sha: String) async throws -> String {
        try await run(["log", "-1", "--format=%B", sha]).text
    }

    /// Diff of a commit against its first parent, in unified format.
    public func diff(of sha: String) async throws -> String {
        try await run(["show", "--format=", "--patch", "--stat=0", "-m", "--first-parent", sha]).text
    }

    /// Working tree diff: the index (`staged: true`) or working files.
    public func workingDiff(staged: Bool, path: String? = nil) async throws -> String {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let path { args += ["--", path] }
        return try await run(args).text
    }

    // MARK: Operations

    public func fetch(prune: Bool = true) async throws {
        var args = ["fetch", "--all"]
        if prune { args.append("--prune") }
        try await run(args)
    }
}
