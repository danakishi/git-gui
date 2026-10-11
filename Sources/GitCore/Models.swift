import Foundation

/// A commit from `git log`.
public struct Commit: Identifiable, Hashable, Sendable {
    /// The full sha.
    public let id: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let commitDate: Date
    public let subject: String

    public var shortID: String { String(id.prefix(8)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(
        id: String, parents: [String], authorName: String, authorEmail: String,
        authorDate: Date, commitDate: Date, subject: String
    ) {
        self.id = id
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.commitDate = commitDate
        self.subject = subject
    }
}

/// A ref: branch, remote branch, tag, stash.
public struct Ref: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case localBranch, remoteBranch, tag, stash, other }

    /// The full name, for example `refs/heads/main`.
    public let id: String
    public let kind: Kind
    /// The short name: `main`, `origin/main`, `v1.0`.
    public let shortName: String
    /// The sha of the commit the ref points to (peeled for annotated tags).
    public let target: String
    /// The current branch (HEAD points to it).
    public let isHead: Bool
    /// The upstream of a local branch, for example `origin/main`.
    public let upstream: String?

    public init(id: String, kind: Kind, shortName: String, target: String, isHead: Bool, upstream: String?) {
        self.id = id
        self.kind = kind
        self.shortName = shortName
        self.target = target
        self.isHead = isHead
        self.upstream = upstream
    }
}

/// Where HEAD is right now.
public enum Head: Hashable, Sendable {
    case branch(name: String, sha: String)
    case detached(sha: String)
    /// An empty repository with no commits.
    case unborn(branch: String)

    public var sha: String? {
        switch self {
        case .branch(_, let sha), .detached(let sha): sha
        case .unborn: nil
        }
    }
}

/// A line of `git status --porcelain=v2`.
public struct StatusEntry: Identifiable, Hashable, Sendable {
    public enum Change: Character, Sendable {
        case unmodified = "."
        case modified = "M"
        case typeChanged = "T"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case updatedUnmerged = "U"
        case untracked = "?"
        case ignored = "!"
    }

    public var id: String { path }
    public let path: String
    /// The old path when renamed.
    public let originalPath: String?
    public let index: Change
    public let worktree: Change
    public let isConflict: Bool

    public var isStaged: Bool { index != .unmodified && index != .untracked && index != .ignored }
    public var isUnstaged: Bool { worktree != .unmodified }

    public init(path: String, originalPath: String? = nil, index: Change, worktree: Change, isConflict: Bool = false) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.isConflict = isConflict
    }
}

/// A summary of `git status`: branch, upstream, and the list of files.
public struct WorkingTreeStatus: Sendable {
    public let branch: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let entries: [StatusEntry]

    public init(branch: String?, upstream: String?, ahead: Int, behind: Int, entries: [StatusEntry]) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.entries = entries
    }
}

/// An entry of `git stash list`.
public struct StashEntry: Identifiable, Hashable, Sendable {
    /// The sequence number: `stash@{index}`.
    public let index: Int
    /// The sha of the stash commit.
    public let sha: String
    public let date: Date
    /// The message, for example `WIP on main: 1234abc Subject` or one set by the user.
    public let message: String

    public var id: String { sha }
    public var ref: String { "stash@{\(index)}" }

    public init(index: Int, sha: String, date: Date, message: String) {
        self.index = index
        self.sha = sha
        self.date = date
        self.message = message
    }
}
