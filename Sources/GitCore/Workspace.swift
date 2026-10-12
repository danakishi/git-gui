import Foundation

// Submodules, worktrees, and Git LFS: what's needed to display them correctly.

/// A submodule from `git submodule status`.
public struct Submodule: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// The commit recorded in the parent is checked out.
        case upToDate
        /// Not initialized: the directory is empty.
        case uninitialized
        /// A different commit is checked out.
        case otherCommit
        /// Merge conflict in the parent.
        case conflict
    }

    public var id: String { path }
    public let path: String
    /// The commit checked out in the submodule (for an uninitialized one, the one recorded in the parent).
    public let sha: String
    public let state: State
    /// `git describe` of the checked-out commit, for example `v1.2-3-gabc`.
    public let describe: String?

    public init(path: String, sha: String, state: State, describe: String?) {
        self.path = path
        self.sha = sha
        self.state = state
        self.describe = describe
    }
}

/// A worktree from `git worktree list --porcelain`.
public struct Worktree: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let head: String?
    /// The checked-out branch without `refs/heads/`; `nil` for detached or bare.
    public let branch: String?
    public let isBare: Bool
    public let isLocked: Bool
    /// The directory is gone; the entry can be removed with `git worktree prune`.
    public let isPrunable: Bool

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(path: String, head: String?, branch: String?, isBare: Bool = false,
                isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// A Git LFS pointer: how the content of a file stored in LFS looks to git.
public struct LFSPointer: Hashable, Sendable {
    /// `sha256:…`
    public let oid: String
    public let size: Int

    /// Parses the pointer text; `nil` if it isn't one.
    public static func parse(_ lines: [String]) -> LFSPointer? {
        guard lines.first?.hasPrefix("version https://git-lfs.github.com/spec/") == true else { return nil }
        var oid: String?, size: Int?
        for line in lines.dropFirst() {
            if line.hasPrefix("oid ") { oid = String(line.dropFirst(4)) }
            else if line.hasPrefix("size ") { size = Int(line.dropFirst(5)) }
        }
        guard let oid, let size else { return nil }
        return LFSPointer(oid: oid, size: size)
    }

    public init(oid: String, size: Int) {
        self.oid = oid
        self.size = size
    }
}

extension FileDiff {
    /// A change that makes no sense to show as lines of text.
    public enum Special: Hashable, Sendable {
        /// The submodule moved from one commit to another. `dirty` means there are uncommitted changes inside.
        case submodule(old: String?, new: String?, dirty: Bool)
        /// A file in Git LFS: git only sees pointers.
        case lfs(old: LFSPointer?, new: LFSPointer?)
    }

    public var special: Special? {
        let lines = hunks.flatMap(\.lines).filter { $0.kind != .meta }
        guard let first = lines.first?.text else { return nil }
        let old = lines.filter { $0.kind != .addition }.map(\.text)
        let new = lines.filter { $0.kind != .deletion }.map(\.text)

        if first.hasPrefix("Subproject commit ") {
            func sha(_ list: [String]) -> (String, Bool)? {
                guard let line = list.first(where: { $0.hasPrefix("Subproject commit ") }) else { return nil }
                let value = String(line.dropFirst("Subproject commit ".count))
                return value.hasSuffix("-dirty") ? (String(value.dropLast(6)), true) : (value, false)
            }
            let o = sha(old), n = sha(new)
            return .submodule(old: o?.0, new: n?.0, dirty: n?.1 ?? false)
        }
        if first.hasPrefix("version https://git-lfs.github.com/spec/") {
            let o = LFSPointer.parse(old), n = LFSPointer.parse(new)
            guard o != nil || n != nil else { return nil }
            return .lfs(old: o, new: n)
        }
        return nil
    }
}

extension GitRepository {
    /// First-level submodules. Without `.gitmodules`, we don't run git.
    public func submodules() async throws -> [Submodule] {
        guard FileManager.default.fileExists(atPath: workingDirectory.appending(path: ".gitmodules").path) else { return [] }
        let out = try await run(["submodule", "status"], check: false)
        guard out.exitCode == 0 else { return [] }
        return Self.parseSubmoduleStatus(out.text)
    }

    /// ` <sha> path (describe)`; the first character is the state: space, `-`, `+`, `U`.
    static func parseSubmoduleStatus(_ text: String) -> [Submodule] {
        text.split(separator: "\n").compactMap { line in
            guard let flag = line.first else { return nil }
            let rest = line.dropFirst()
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            var path = String(parts[1])
            var describe: String?
            if path.hasSuffix(")"), let open = path.range(of: " (", options: .backwards) {
                describe = String(path[open.upperBound...].dropLast())
                path = String(path[..<open.lowerBound])
            }
            let state: Submodule.State = switch flag {
            case "-": .uninitialized
            case "+": .otherCommit
            case "U": .conflict
            default: .upToDate
            }
            return Submodule(path: path, sha: String(parts[0]), state: state, describe: describe)
        }
    }

    public func worktrees() async throws -> [Worktree] {
        let out = try await run(["worktree", "list", "--porcelain"], check: false)
        guard out.exitCode == 0 else { return [] }
        return Self.parseWorktrees(out.text)
    }

    static func parseWorktrees(_ text: String) -> [Worktree] {
        text.components(separatedBy: "\n\n").compactMap { block in
            var path: String?, head: String?, branch: String?
            var bare = false, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = line.dropFirst("branch ".count)
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
                }
                else if line == "bare" { bare = true }
                else if line == "locked" || line.hasPrefix("locked ") { locked = true }
                else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
            }
            guard let path else { return nil }
            return Worktree(path: path, head: head, branch: branch, isBare: bare, isLocked: locked, isPrunable: prunable)
        }
    }

    /// The git directories to watch: its own (for a worktree or submodule it is
    /// outside the working tree) and the common one (branches and tags live there).
    public func gitDirectories() async throws -> [URL] {
        let out = try await run(["rev-parse", "--absolute-git-dir", "--git-common-dir"])
        let lines = out.text.split(separator: "\n").map(String.init)
        // No standardizedFileURL: it strips /private, and the path no longer matches what git reports.
        return lines.map { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                : workingDirectory.appending(path: path, directoryHint: .isDirectory)
        }
    }

    /// `git submodule update --init --recursive`: check out the recorded commits in submodules.
    public func updateSubmodules() async throws {
        try await run(["submodule", "update", "--init", "--recursive"])
    }

    public func pruneWorktrees() async throws {
        try await run(["worktree", "prune"])
    }
}
