import Foundation

// Operations that rewrite history: merge, rebase, cherry-pick, revert, reset,
// the unfinished state after a conflict, and undo via the reflog.

/// An operation that stopped midway: a conflict, or `edit` in an interactive rebase.
public struct OperationState: Hashable, Sendable {
    public enum Kind: Sendable {
        case merge, rebase, cherryPick, revert

        public var canSkip: Bool { self != .merge }
    }

    public let kind: Kind
    /// For rebase: the current step number and the total.
    public let step: Int?
    public let total: Int?
    /// The branch being rebased (`feature`), if the rebase was started from a branch.
    public let branch: String?
    /// The sha being rebased onto, or the incoming commit of a merge/cherry-pick/revert.
    public let target: String?

    public init(kind: Kind, step: Int? = nil, total: Int? = nil, branch: String? = nil, target: String? = nil) {
        self.kind = kind
        self.step = step
        self.total = total
        self.branch = branch
        self.target = target
    }
}

/// A step of an interactive rebase.
public struct RebaseStep: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case pick
        /// Keep the commit with a new message.
        case reword(String)
        /// Meld into the previous commit, combining the messages.
        case squash
        /// Meld into the previous commit, keeping the previous message.
        case fixup
        /// Stop after the commit so it can be amended.
        case edit
        case drop
    }

    public let sha: String
    public let action: Action

    public init(sha: String, action: Action) {
        self.sha = sha
        self.action = action
    }
}

/// What "Undo" will do, as found in the reflog.
public struct UndoAction: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Go back to the branch or commit that was checked out before.
        case checkout(String)
        /// Move the branch (or HEAD) back to its previous commit. `soft` is for undoing a commit:
        /// the changes stay in the index.
        case reset(to: String, soft: Bool)
    }

    public let kind: Kind
    /// The reflog entry being undone, for example `commit: Fix typo`.
    public let message: String
    public let date: Date

    public init(kind: Kind, message: String, date: Date) {
        self.kind = kind
        self.message = message
        self.date = date
    }
}

public enum ResetMode: String, Sendable, CaseIterable {
    /// Only move the branch back; the index and files stay as they were.
    case soft
    /// Move the branch and index back; files stay as they were.
    case mixed
    /// Move everything back; uncommitted changes are lost.
    case hard
}

public enum MergeMode: Sendable {
    /// Fast-forward if possible, otherwise create a merge commit.
    case auto
    case fastForwardOnly
    case noFastForward
}

extension GitRepository {
    // MARK: State

    /// The absolute path to the `.git` directory (for a worktree, its own one).
    public func gitDirectory() async throws -> URL {
        let path = try await run(["rev-parse", "--absolute-git-dir"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The unfinished operation, or `nil`. Reads git's internal files directly,
    /// because git has no command that reports this in a parseable form.
    public func operationState() async throws -> OperationState? {
        let dir = try await gitDirectory()
        return Self.operationState(gitDirectory: dir)
    }

    static func operationState(gitDirectory dir: URL) -> OperationState? {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            (try? String(contentsOf: dir.appending(path: name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func branch(_ name: String) -> String? {
            read(name).map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
                .flatMap { $0 == "detached HEAD" ? nil : $0 }
        }

        // rebase-merge is a regular or interactive rebase; rebase-apply is the old backend and `git am`.
        if fm.fileExists(atPath: dir.appending(path: "rebase-merge").path) {
            return OperationState(kind: .rebase,
                                  step: read("rebase-merge/msgnum").flatMap(Int.init),
                                  total: read("rebase-merge/end").flatMap(Int.init),
                                  branch: branch("rebase-merge/head-name"),
                                  target: read("rebase-merge/onto"))
        }
        if fm.fileExists(atPath: dir.appending(path: "rebase-apply").path),
           !fm.fileExists(atPath: dir.appending(path: "rebase-apply/applying").path) {
            return OperationState(kind: .rebase,
                                  step: read("rebase-apply/next").flatMap(Int.init),
                                  total: read("rebase-apply/last").flatMap(Int.init),
                                  branch: branch("rebase-apply/head-name"),
                                  target: read("rebase-apply/onto"))
        }
        if let sha = read("MERGE_HEAD") {
            return OperationState(kind: .merge, target: sha.split(separator: "\n").first.map(String.init))
        }
        if let sha = read("CHERRY_PICK_HEAD") {
            return OperationState(kind: .cherryPick, target: sha)
        }
        if let sha = read("REVERT_HEAD") {
            return OperationState(kind: .revert, target: sha)
        }
        return nil
    }

    /// `ancestor` is reachable from `descendant` (or equal to it).
    public func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let out = try await run(["merge-base", "--is-ancestor", ancestor, descendant], check: false)
        switch out.exitCode {
        case 0: return true
        case 1: return false
        default: throw GitError(arguments: ["merge-base", "--is-ancestor", ancestor, descendant],
                                exitCode: out.exitCode, stderr: out.stderr)
        }
    }

    /// Commits from `base` (exclusive) to `head`, oldest first.
    /// `base == nil` means the whole history down to the root.
    public func commits(from base: String?, to head: String = "HEAD") async throws -> [Commit] {
        let range = base.map { "\($0)..\(head)" } ?? head
        let out = try await run(["log", "--reverse", "--topo-order", "--format=\(GitParsers.logFormat)", range, "--"])
        return GitParsers.parseLog(out.text)
    }

    // MARK: Operations

    /// Merges `rev` into the current branch. The merge commit message is the default one.
    public func merge(_ rev: String, mode: MergeMode = .auto) async throws {
        var args = ["merge", "--no-edit"]
        switch mode {
        case .auto: break
        case .fastForwardOnly: args.append("--ff-only")
        case .noFastForward: args.append("--no-ff")
        }
        try await run(args + [rev])
    }

    /// Rebases `branch` (the current one by default) onto `upstream`.
    /// When a branch is given, git checks it out first.
    public func rebase(onto upstream: String, branch: String? = nil) async throws {
        try await run(["rebase", upstream] + (branch.map { [$0] } ?? []))
    }

    /// Applies commits to the current branch. For a merge commit, the changes are taken relative to the first parent.
    public func cherryPick(_ sha: String, isMerge: Bool = false) async throws {
        try await run(["cherry-pick"] + (isMerge ? ["-m", "1"] : []) + [sha])
    }

    /// A commit that reverses the changes of `sha`.
    public func revert(_ sha: String, isMerge: Bool = false) async throws {
        try await run(["revert", "--no-edit"] + (isMerge ? ["-m", "1"] : []) + [sha])
    }

    public func reset(to rev: String, mode: ResetMode) async throws {
        try await run(["reset", "-q", "--\(mode.rawValue)", rev])
    }

    /// Moves a non-current branch forward without checking it out. Fast-forward only.
    public func fastForward(branch: String, to rev: String) async throws {
        guard try await isAncestor("refs/heads/\(branch)", of: rev) else {
            throw GitError(arguments: ["branch", "-f", branch, rev], exitCode: 1,
                           stderr: "\(branch) cannot be fast-forwarded to \(rev): the histories have diverged")
        }
        try await run(["branch", "-f", branch, rev])
    }

    public func continueOperation(_ kind: OperationState.Kind) async throws {
        try await run([Self.command(kind), "--continue"])
    }

    public func abortOperation(_ kind: OperationState.Kind) async throws {
        try await run([Self.command(kind), "--abort"])
    }

    public func skipOperation(_ kind: OperationState.Kind) async throws {
        try await run([Self.command(kind), "--skip"])
    }

    private static func command(_ kind: OperationState.Kind) -> String {
        switch kind {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    /// Resolves a file's conflict in favour of one side and marks it resolved.
    /// `ours` is the HEAD version (during a rebase, the branch being rebased onto);
    /// otherwise it is the incoming version.
    public func resolveConflict(_ path: String, ours: Bool) async throws {
        let out = try await run(["checkout", ours ? "--ours" : "--theirs", "--", path], check: false)
        if out.exitCode == 0 {
            try await run(["add", "--", path])
        } else {
            // The file is deleted on this side, so resolving means deleting it.
            try await run(["rm", "-q", "--", path])
        }
    }

    // MARK: Interactive rebase

    /// Rewrites the commits after `base` according to the list of steps (oldest first).
    /// `base == nil` starts from the root. Stopping at `edit` or at a conflict leaves the
    /// rebase unfinished; continue with `continueOperation(.rebase)`.
    public func interactiveRebase(base: String?, steps: [RebaseStep]) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "gitgui-rebase-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The directory is needed even after stopping at edit: exec steps with new messages
        // read files from it. The system removes it along with the rest of tmp.

        var todo: [String] = []
        for (i, step) in steps.enumerated() {
            switch step.action {
            case .pick: todo.append("pick \(step.sha)")
            case .squash: todo.append("squash \(step.sha)")
            case .fixup: todo.append("fixup \(step.sha)")
            case .edit: todo.append("edit \(step.sha)")
            case .drop: todo.append("drop \(step.sha)")
            case .reword(let message):
                // There is no way to substitute our own message editor, so the new message
                // goes into a file and the commit is amended right after the pick.
                let file = dir.appending(path: "message-\(i)")
                try message.write(to: file, atomically: true, encoding: .utf8)
                todo.append("pick \(step.sha)")
                todo.append("exec git commit --amend --allow-empty -q --cleanup=strip -F \(Self.shellQuote(file.path))")
            }
        }
        let todoFile = dir.appending(path: "todo")
        try (todo.joined(separator: "\n") + "\n").write(to: todoFile, atomically: true, encoding: .utf8)

        // git invokes the list editor as `$GIT_SEQUENCE_EDITOR <file>` through the shell,
        // so we replace it by copying our own list over the file.
        let editor = "cp \(Self.shellQuote(todoFile.path))"
        let args = ["rebase", "-i", "--no-autosquash"] + (base.map { [$0] } ?? ["--root"])
        try await GitRunner.run(args, in: workingDirectory, environment: ["GIT_SEQUENCE_EDITOR": editor])
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Undo

    /// The last action that can be undone, or `nil`.
    ///
    /// We look at the HEAD reflog: it has branch switches and everything else. Entries
    /// after which HEAD stayed in place (`merge --abort`, a reset to the same
    /// commit) are skipped, since the user doesn't see them as actions. A rebase is
    /// dozens of entries, so it is rolled back to the commit before `(start)`. The undo itself
    /// is written to the reflog, so undoing again restores everything as it was.
    public func undoAction() async throws -> UndoAction? {
        let entries = try await reflog("HEAD", count: 200)
        var i = 0
        // Rebase steps can also be no-ops (`(finish)` after the last pick),
        // but they are part of the action, so we don't skip them.
        while i + 1 < entries.count, entries[i].sha == entries[i + 1].sha,
              Self.checkoutSource(entries[i].message) == nil, !Self.isRebaseStep(entries[i].message) {
            i += 1
        }
        guard i < entries.count else { return nil }
        let last = entries[i]

        if let from = Self.checkoutSource(last.message) {
            return UndoAction(kind: .checkout(from), message: last.message, date: last.date)
        }
        if Self.isRebaseStep(last.message) {
            // `rebase (finish): returning to refs/heads/x`: the previous position is in the
            // branch's own reflog. It can't be found in the HEAD reflog if the rebase was started from another
            // branch (`git rebase main feature`): the tip of main is before `(start)` there.
            if let r = last.message.range(of: "returning to refs/heads/") {
                let branch = String(last.message[r.upperBound...])
                let log = try await reflog("refs/heads/\(branch)", count: 2)
                guard log.count == 2, log[0].message.contains("(finish)") else { return nil }
                return UndoAction(kind: .reset(to: log[1].sha, soft: false), message: last.message, date: last.date)
            }
            // Rebase on a detached HEAD (git doesn't even write `(finish)`): before the start,
            // HEAD was at the entry before `(start)`.
            guard let start = entries[i...].firstIndex(where: { $0.message.contains("(start)") }),
                  start + 1 < entries.count else { return nil }
            return UndoAction(kind: .reset(to: entries[start + 1].sha, soft: false),
                              message: last.message, date: last.date)
        }
        guard i + 1 < entries.count else { return nil }
        // After a regular commit and an amend, the changes return to the index,
        // as in GitKraken. Everything else is rolled back completely.
        let soft = last.message.hasPrefix("commit:") || last.message.hasPrefix("commit (amend):")
        return UndoAction(kind: .reset(to: entries[i + 1].sha, soft: soft), message: last.message, date: last.date)
    }

    public func undo(_ action: UndoAction) async throws {
        switch action.kind {
        case .checkout(let target):
            // With a detached HEAD, the reflog has a sha rather than a branch name.
            let isBranch = try await run(["show-ref", "--verify", "--quiet", "refs/heads/\(target)"], check: false).exitCode == 0
            if isBranch {
                try await checkout(branch: target)
            } else {
                try await checkout(commit: target)
            }
        case .reset(let sha, let soft):
            // --keep preserves uncommitted changes, or refuses if they are in the way.
            try await run(["reset", "-q", soft ? "--soft" : "--keep", sha])
        }
    }

    struct ReflogEntry {
        let sha: String
        let message: String
        let date: Date
    }

    func reflog(_ ref: String, count: Int) async throws -> [ReflogEntry] {
        let out = try await run(["reflog", "show", "-n", "\(count)", "--format=%H%x00%gs%x00%ct", ref, "--"], check: false)
        guard out.exitCode == 0 else { return [] }
        return out.text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard f.count == 3, let t = TimeInterval(f[2]) else { return nil }
            return ReflogEntry(sha: String(f[0]), message: String(f[1]), date: Date(timeIntervalSince1970: t))
        }
    }

    /// A reflog entry from a rebase: `rebase (pick): …`, `rebase -i (finish): …`, `pull --rebase (start): …`.
    static func isRebaseStep(_ message: String) -> Bool {
        (message.hasPrefix("rebase") || message.hasPrefix("pull --rebase")) && message.contains(" (")
    }

    /// `checkout: moving from main to feature` → `main`.
    static func checkoutSource(_ message: String) -> String? {
        let prefix = "checkout: moving from "
        guard message.hasPrefix(prefix) else { return nil }
        let rest = message.dropFirst(prefix.count)
        guard let r = rest.range(of: " to ", options: .backwards) else { return nil }
        return String(rest[..<r.lowerBound])
    }
}
