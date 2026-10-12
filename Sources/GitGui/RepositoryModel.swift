import AppKit
import Foundation
import GitCore
import GraphLayout
import Hosting
import Observation

/// Details of the selected commit.
struct CommitDetail: Sendable {
    let commit: Commit
    /// Message body without the first line.
    let body: String
    let files: [FileDiff]
}

/// What the inspector on the right shows.
enum InspectorMode: Hashable {
    case commit
    case workingTree
}

/// State of one open repository: history, graph, refs, HEAD, status.
@MainActor
@Observable
final class RepositoryModel {
    let repo: GitRepository

    private(set) var commits: [Commit] = []
    private(set) var refs: [Ref] = []
    private(set) var head: Head?
    private(set) var status: WorkingTreeStatus?
    private(set) var stashes: [StashEntry] = []
    /// An unfinished merge/rebase/cherry-pick/revert.
    private(set) var operation: OperationState?
    /// What "Undo" will do.
    private(set) var undoAction: UndoAction?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Name of the running operation (push, commit…) until it finishes.
    private(set) var busy: String?

    /// Refs by commit sha: for the labels on rows.
    private(set) var refsByCommit: [String: [Ref]] = [:]
    /// Graph rows by commit sha.
    private(set) var graphRows: [String: GraphLayout.Row] = [:]
    private(set) var graphWidth = 1
    private var graph = GraphLayout()

    static let pageSize = 1000
    private(set) var hasMore = true

    // MARK: Selection and inspector

    /// Show the history of all branches or only the current one.
    var showAllBranches = true {
        didSet { if showAllBranches != oldValue { Task { await reload() } } }
    }
    /// How many graph lanes are visible; the rest are clipped.
    var maxVisibleLanes = 10

    var searchText = ""
    var inspector: InspectorMode = .commit
    var selectedCommitID: Commit.ID? {
        didSet {
            guard selectedCommitID != oldValue else { return }
            if selectedCommitID != nil { inspector = .commit }
            Task { await loadDetail() }
        }
    }
    private(set) var detail: CommitDetail?
    private(set) var isLoadingDetail = false

    /// Commit message draft and amend mode: they live as long as the window is open.
    var commitMessage = ""
    var amend = false {
        didSet {
            guard amend, !oldValue, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { await prefillAmendMessage() }
        }
    }

    /// The open input sheet (new branch, tag, stash) and the branch awaiting delete confirmation.
    var sheet: RepositorySheet?
    var confirmForceDelete: Ref?
    /// A reset --hard awaiting confirmation.
    var confirmHardReset: Commit?

    /// PRs/MRs and CI from GitHub or GitLab.
    let hosting = HostingState()

    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var reloadPending = false

    init(_ repo: GitRepository) {
        self.repo = repo
    }

    /// Commits filtered by the search string. The graph is not shown while filtering.
    var filteredCommits: [Commit] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commits }
        let lower = q.lowercased()
        return commits.filter {
            $0.subject.lowercased().contains(lower)
                || $0.authorName.lowercased().contains(lower)
                || $0.id.hasPrefix(lower)
        }
    }

    var isFiltering: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Files with a conflict are excluded, even though git considers them changed in the index:
    /// unstaging them would silently resolve the conflict in favour of HEAD.
    var stagedFiles: [WorkingFile] {
        (status?.entries ?? []).filter { $0.isStaged && !$0.isConflict }.map { WorkingFile(entry: $0, staged: true) }
    }

    var unstagedFiles: [WorkingFile] {
        (status?.entries ?? []).filter { $0.isUnstaged || $0.index == .untracked }
            .map { WorkingFile(entry: $0, staged: false) }
    }

    var localBranches: [Ref] { refs.filter { $0.kind == .localBranch } }
    var remoteBranches: [Ref] { refs.filter { $0.kind == .remoteBranch } }
    var tags: [Ref] { refs.filter { $0.kind == .tag } }

    var currentBranch: String? {
        if case .branch(let name, _) = head { return name }
        return nil
    }

    /// The current branch has an upstream: pull and a plain push are available.
    var hasUpstream: Bool { status?.upstream != nil }

    // MARK: Loading

    func start() async {
        if watcher == nil {
            watcher = RepositoryWatcher(url: repo.workingDirectory) { [weak self] in
                Task { @MainActor in await self?.reloadFromWatcher() }
            }
        }
        await reload()
        await refreshHosting()

        // Debug flags for UI snapshots.
        if let n = DebugScreenshot.selectRow, n < commits.count {
            selectedCommitID = commits[n].id
        }
        if DebugScreenshot.showWorkingTree {
            inspector = .workingTree
        }
        for args in DebugScreenshot.debugGitCommands {
            await perform("git \(args.joined(separator: " "))") { try await repo.run(args) }
        }
    }

    private func reloadFromWatcher() async {
        // If a reload is already in progress, remember it and repeat afterwards.
        if isLoading { reloadPending = true; return }
        await reload()
    }

    func reload() async {
        isLoading = true
        // Don't clear the error: it may be an operation error, and the
        // user should dismiss it, not the next FSEvents event.
        defer {
            isLoading = false
            if reloadPending {
                reloadPending = false
                Task { await reload() }
            }
        }
        do {
            async let c = repo.log(limit: Self.pageSize, all: showAllBranches)
            async let r = repo.refs()
            async let h = repo.head()
            async let s = repo.status()
            async let st = repo.stashList()
            async let op = repo.operationState()
            async let u = repo.undoAction()
            let (commits, refs, head, status, stashes) = try await (c, r, h, s, st)
            self.operation = try await op
            self.undoAction = try? await u
            self.commits = commits
            self.refs = refs
            self.head = head
            self.status = status
            self.stashes = stashes
            self.hasMore = commits.count == Self.pageSize
            self.refsByCommit = Dictionary(grouping: refs, by: \.target)
            relayout()
            hosting.relink(refs: refs, commits: commits)
            if let id = selectedCommitID, !commits.contains(where: { $0.id == id }), !stashes.contains(where: { $0.sha == id }) {
                selectedCommitID = nil
            } else if selectedCommitID != nil {
                await loadDetail()
            }
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Loads the next page of history.
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let more = try await repo.log(limit: Self.pageSize, skip: commits.count, all: showAllBranches)
            commits.append(contentsOf: more)
            hasMore = more.count == Self.pageSize
            graph.append(more)
            for row in graph.rows.suffix(more.count) { graphRows[row.commitID] = row }
            graphWidth = graph.maxWidth
            hosting.relink(refs: refs, commits: commits)
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Requests PRs and CI from the hosting provider. Errors are shown in the status bar, not in a general alert.
    func refreshHosting() async {
        await hosting.refresh(repo: repo, head: head?.sha, refs: refs, commits: commits)
    }

    private func relayout() {
        graph = GraphLayout()
        graph.append(commits)
        graphRows = Dictionary(uniqueKeysWithValues: graph.rows.map { ($0.commitID, $0) })
        graphWidth = graph.maxWidth
    }

    private func loadDetail() async {
        guard let id = selectedCommitID else {
            detail = nil
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            // Stash commits aren't in the list; they are read separately.
            var found = commits.first(where: { $0.id == id })
            if found == nil { found = try await repo.commit(id) }
            guard let commit = found else {
                detail = nil
                return
            }
            async let message = repo.message(of: id)
            async let patch = repo.diff(of: id)
            let (m, p) = try await (message, patch)
            // The selection may have changed while loading.
            guard selectedCommitID == id else { return }
            let lines = m.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            detail = CommitDetail(commit: commit, body: body, files: DiffParser.parse(p))
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Diff of a working tree file. For untracked files, the whole content is shown as added.
    func diff(for file: WorkingFile) async -> FileDiff? {
        do {
            if file.entry.index == .untracked {
                let text = try await repo.fileContents(file.entry.path)
                return DiffParser.additionsOnly(path: file.entry.path, text: text)
            }
            let text = try await repo.workingDiff(staged: file.staged, path: file.entry.path)
            return DiffParser.parse(text).first
                ?? FileDiff(oldPath: file.entry.path, newPath: file.entry.path, status: .modified, isBinary: false, hunks: [])
        } catch {
            self.error = String(describing: error)
            return nil
        }
    }

    func clearError() {
        error = nil
    }

    // MARK: Operations

    /// Runs an operation: shows busy state, catches the error, reloads the repository.
    /// Returns `true` if the operation succeeded.
    @discardableResult
    func perform(_ title: String, _ operation: () async throws -> Void) async -> Bool {
        guard busy == nil else { return false }
        busy = title
        error = nil
        defer { busy = nil }
        var failure: String?
        do {
            try await operation()
        } catch {
            failure = String(describing: error)
        }
        error = failure
        await reload()
        return failure == nil
    }

    // Index

    func stage(_ files: [WorkingFile]) async {
        // A conflicted file in the index counts as "resolved". With markers inside,
        // it's easy to commit garbage, so check the content first.
        let unresolved = files.filter { $0.entry.isConflict && hasConflictMarkers($0.entry.path) }.map(\.entry.path)
        guard unresolved.isEmpty else {
            error = "\(unresolved.joined(separator: ", ")) still contains conflict markers (<<<<<<<). Remove them or choose one of the versions."
            return
        }
        await perform("Staging") { try await repo.stage(files.map(\.entry.path)) }
    }

    private func hasConflictMarkers(_ path: String) -> Bool {
        guard let text = try? String(contentsOf: repo.workingDirectory.appending(path: path), encoding: .utf8) else {
            return false
        }
        return text.hasPrefix("<<<<<<< ") || text.contains("\n<<<<<<< ")
    }

    func unstage(_ files: [WorkingFile]) async {
        await perform("Unstaging") { try await repo.unstage(files.map(\.entry.path)) }
    }

    func stageAll() async {
        if conflictCount > 0 {
            // `add -A` would mark files with markers as resolved too: go file by file with a check.
            await stage(unstagedFiles)
        } else {
            await perform("Staging all") { try await repo.stageAll() }
        }
    }

    func unstageAll() async {
        // `git reset` in the middle of a merge/rebase silently discards their state,
        // so in that case only regular files are unstaged.
        if operation != nil {
            await unstage(stagedFiles)
        } else {
            await perform("Unstaging all") { try await repo.unstageAll() }
        }
    }

    func stageHunk(_ hunk: DiffHunk, of file: FileDiff) async {
        await perform("Staging hunk") {
            try await repo.apply(patch: file.patch(hunk: hunk), toIndex: true, reverse: false)
        }
    }

    func unstageHunk(_ hunk: DiffHunk, of file: FileDiff) async {
        await perform("Unstaging hunk") {
            try await repo.apply(patch: file.patch(hunk: hunk), toIndex: true, reverse: true)
        }
    }

    func discardHunk(_ hunk: DiffHunk, of file: FileDiff) async {
        await perform("Discarding hunk") {
            try await repo.apply(patch: file.patch(hunk: hunk), toIndex: false, reverse: true)
        }
    }

    /// Discards changes in the working tree. The UI asks for confirmation.
    func discard(_ files: [WorkingFile]) async {
        await perform("Discarding changes") { try await repo.discard(files.map(\.entry)) }
    }

    func discardAll() async {
        await perform("Discarding all changes") {
            try await repo.discard(status?.entries ?? [])
        }
    }

    var canCommit: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (amend || !stagedFiles.isEmpty)
    }

    func commit() async {
        let message = commitMessage
        let amend = amend
        let ok = await perform(amend ? "Amending commit" : "Creating commit") {
            try await repo.commit(message: message, amend: amend)
        }
        if ok {
            commitMessage = ""
            self.amend = false
        }
    }

    private func prefillAmendMessage() async {
        guard let text = try? await repo.message(of: "HEAD") else { return }
        if amend, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = text.trimmingCharacters(in: .newlines)
        }
    }

    // Branches and tags

    func checkout(_ ref: Ref) async {
        switch ref.kind {
        case .localBranch:
            await perform("Checking out \(ref.shortName)") { try await repo.checkout(branch: ref.shortName) }
        case .remoteBranch:
            await perform("Checking out \(ref.shortName)") {
                // If a local branch with this name already exists, just switch to it.
                let local = ref.shortName.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ref.shortName
                if localBranches.contains(where: { $0.shortName == local }) {
                    try await repo.checkout(branch: local)
                } else {
                    try await repo.checkoutRemote(ref.shortName)
                }
            }
        case .tag, .stash, .other:
            await checkout(commit: ref.target)
        }
    }

    func checkout(commit sha: String) async {
        await perform("Checking out \(sha.prefix(8))") { try await repo.checkout(commit: sha) }
    }

    func createBranch(_ name: String, at sha: String?, checkout: Bool) async {
        await perform("Creating branch \(name)") { try await repo.createBranch(name, at: sha, checkout: checkout) }
    }

    func renameBranch(_ old: String, to new: String) async {
        await perform("Renaming \(old)") { try await repo.renameBranch(old, to: new) }
    }

    /// Deletes a branch. Returns `false` without an error message if the branch isn't merged:
    /// the UI asks for confirmation and calls again with `force: true`.
    @discardableResult
    func deleteBranch(_ ref: Ref, force: Bool) async -> Bool {
        if ref.kind == .remoteBranch {
            return await perform("Deleting \(ref.shortName)") { try await repo.deleteRemoteBranch(ref.shortName) }
        }
        if !force {
            do {
                try await repo.deleteBranch(ref.shortName, force: false)
                await reload()
                return true
            } catch let e as GitError where e.stderr.contains("not fully merged") {
                return false
            } catch {
                self.error = String(describing: error)
                return true
            }
        }
        return await perform("Deleting \(ref.shortName)") { try await repo.deleteBranch(ref.shortName, force: true) }
    }

    func createTag(_ name: String, at sha: String?, message: String) async {
        await perform("Creating tag \(name)") { try await repo.createTag(name, at: sha, message: message) }
    }

    func deleteTag(_ ref: Ref) async {
        await perform("Deleting tag \(ref.shortName)") { try await repo.deleteTag(ref.shortName) }
    }

    // Remotes

    // After talking to the server, new branches and PRs appear: ask the hosting provider right away.

    func fetch() async {
        if await perform("Fetch", { try await repo.fetch() }) { await refreshHosting() }
    }

    func pull(rebase: Bool) async {
        if await perform(rebase ? "Pull --rebase" : "Pull", { try await repo.pull(rebase: rebase) }) {
            await refreshHosting()
        }
    }

    /// Pushes the current branch; without an upstream, sets it to the first remote.
    func push() async {
        let ok = await perform("Push") {
            if hasUpstream {
                try await repo.push()
            } else {
                guard let branch = currentBranch else {
                    throw GitError(arguments: ["push"], exitCode: 1, stderr: "HEAD is not on a branch")
                }
                let remotes = try await repo.remotes()
                guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
                    throw GitError(arguments: ["push"], exitCode: 1, stderr: "no remotes")
                }
                try await repo.push(remote: remote, branch: branch, setUpstream: true)
            }
        }
        if ok { await refreshHosting() }
    }

    // Stash

    func stashPush(message: String, includeUntracked: Bool) async {
        await perform("Stashing changes") {
            try await repo.stashPush(message: message, includeUntracked: includeUntracked)
        }
    }

    func stashApply(_ entry: StashEntry, pop: Bool) async {
        await perform(pop ? "Popping stash" : "Applying stash") { try await repo.stashApply(entry, pop: pop) }
    }

    func stashDrop(_ entry: StashEntry) async {
        if selectedCommitID == entry.sha { selectedCommitID = nil }
        await perform("Dropping stash") { try await repo.stashDrop(entry) }
    }

    /// Shows a stash in the inspector as a commit.
    func show(_ entry: StashEntry) {
        selectedCommitID = entry.sha
    }

    // History: merge, rebase, cherry-pick, reset

    /// Name for referring to a commit in commands and menus: local branch, remote branch, otherwise short sha.
    func name(for commit: Commit) -> String {
        let refs = refsByCommit[commit.id] ?? []
        return refs.first { $0.kind == .localBranch && !$0.isHead }?.shortName
            ?? refs.first { $0.kind == .localBranch }?.shortName
            ?? refs.first { $0.kind == .remoteBranch }?.shortName
            ?? commit.shortID
    }

    /// Local branch at a commit: non-current ones first.
    func localBranch(at sha: String) -> String? {
        let refs = (refsByCommit[sha] ?? []).filter { $0.kind == .localBranch }
        return (refs.first { !$0.isHead } ?? refs.first)?.shortName
    }

    func merge(_ rev: String, mode: MergeMode = .auto) async {
        let into = currentBranch ?? "HEAD"
        await perform("Merging \(rev) into \(into)") { try await repo.merge(rev, mode: mode) }
    }

    /// Switches to `branch` and merges `rev` into it.
    func merge(_ rev: String, into branch: String) async {
        await perform("Merging \(rev) into \(branch)") {
            try await repo.checkout(branch: branch)
            try await repo.merge(rev)
        }
    }

    /// Rebases `branch` (the current one by default) onto `upstream`.
    func rebase(onto upstream: String, branch: String? = nil) async {
        let what = branch ?? currentBranch ?? "HEAD"
        await perform("Rebasing \(what) onto \(upstream)") { try await repo.rebase(onto: upstream, branch: branch) }
    }

    func fastForward(branch: String, to rev: String) async {
        if branch == currentBranch {
            await merge(rev, mode: .fastForwardOnly)
        } else {
            await perform("Fast-forwarding \(branch)") { try await repo.fastForward(branch: branch, to: rev) }
        }
    }

    func cherryPick(_ commit: Commit) async {
        await perform("Cherry-pick \(commit.shortID)") { try await repo.cherryPick(commit.id, isMerge: commit.isMerge) }
    }

    func revert(_ commit: Commit) async {
        await perform("Revert \(commit.shortID)") { try await repo.revert(commit.id, isMerge: commit.isMerge) }
    }

    /// Reset of the current branch. For `hard`, the UI asks for confirmation beforehand.
    func reset(to commit: Commit, mode: ResetMode) async {
        await perform("Reset --\(mode.rawValue) to \(commit.shortID)") { try await repo.reset(to: commit.id, mode: mode) }
    }

    func continueOperation() async {
        guard let op = operation else { return }
        await perform("Continuing") { try await repo.continueOperation(op.kind) }
    }

    func skipOperation() async {
        guard let op = operation else { return }
        await perform("Skipping commit") { try await repo.skipOperation(op.kind) }
    }

    func abortOperation() async {
        guard let op = operation else { return }
        await perform("Aborting") { try await repo.abortOperation(op.kind) }
    }

    func resolveConflict(_ files: [WorkingFile], ours: Bool) async {
        await perform(ours ? "Taking HEAD version" : "Taking incoming version") {
            for f in files { try await repo.resolveConflict(f.entry.path, ours: ours) }
        }
    }

    var conflictCount: Int {
        status?.entries.filter(\.isConflict).count ?? 0
    }

    /// During an unfinished merge/rebase, undo means "Abort":
    /// the reflog at that point no longer describes the user's last action.
    func undo() async {
        if operation != nil {
            await abortOperation()
            return
        }
        guard let action = undoAction else { return }
        await perform("Undoing “\(action.message)”") { try await repo.undo(action) }
    }

    var canUndo: Bool {
        busy == nil && (operation != nil || undoAction != nil)
    }

    /// Opens the interactive rebase window for commits from `commit` to HEAD.
    func beginInteractiveRebase(from commit: Commit) async {
        guard let head = head?.sha else { return }
        do {
            guard try await repo.isAncestor(commit.id, of: head) else {
                error = "Commit \(commit.shortID) is not in the current branch's history"
                return
            }
            let base = commit.parents.first
            let range = try await repo.commits(from: base)
            if range.contains(where: \.isMerge) {
                error = "There are merge commits between \(commit.shortID) and HEAD: interactive rebase would not preserve them"
                return
            }
            sheet = .interactiveRebase(base: base, commits: range)
        } catch {
            self.error = String(describing: error)
        }
    }

    func interactiveRebase(base: String?, steps: [RebaseStep]) async {
        await perform("Interactive rebase") { try await repo.interactiveRebase(base: base, steps: steps) }
    }

    /// Opens a working tree file in the default app.
    func openFile(_ path: String) {
        NSWorkspace.shared.open(repo.workingDirectory.appending(path: path))
    }

    // Hosting provider

    /// Opens a link in the default browser.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// A branch from which a PR can be created: it is published and has no PR yet.
    func canCreatePullRequest(from ref: Ref) -> Bool {
        hosting.provider != nil && hosting.serverBranch(for: ref) != nil && hosting.pullRequest(for: ref) == nil
    }

    func createPullRequest(from ref: Ref) {
        guard let provider = hosting.provider, let branch = hosting.serverBranch(for: ref) else { return }
        open(provider.newPullRequestURL(source: branch))
    }

    // Misc

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([repo.workingDirectory.appending(path: path)])
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
