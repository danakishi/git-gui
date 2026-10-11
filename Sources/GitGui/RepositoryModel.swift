import Foundation
import GitCore
import GraphLayout
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
    private(set) var isLoading = false
    private(set) var error: String?

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

    var stagedFiles: [WorkingFile] {
        (status?.entries ?? []).filter(\.isStaged).map { WorkingFile(entry: $0, staged: true) }
    }

    var unstagedFiles: [WorkingFile] {
        (status?.entries ?? []).filter { $0.isUnstaged || $0.index == .untracked }
            .map { WorkingFile(entry: $0, staged: false) }
    }

    // MARK: Loading

    func start() async {
        if watcher == nil {
            watcher = RepositoryWatcher(url: repo.workingDirectory) { [weak self] in
                Task { @MainActor in await self?.reloadFromWatcher() }
            }
        }
        await reload()

        // Debug flags for UI snapshots.
        if let n = DebugScreenshot.selectRow, n < commits.count {
            selectedCommitID = commits[n].id
        }
        if DebugScreenshot.showWorkingTree {
            inspector = .workingTree
        }
    }

    private func reloadFromWatcher() async {
        // If a reload is already in progress, remember it and repeat afterwards.
        if isLoading { reloadPending = true; return }
        await reload()
    }

    func reload() async {
        isLoading = true
        error = nil
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
            let (commits, refs, head, status) = try await (c, r, h, s)
            self.commits = commits
            self.refs = refs
            self.head = head
            self.status = status
            self.hasMore = commits.count == Self.pageSize
            self.refsByCommit = Dictionary(grouping: refs, by: \.target)
            relayout()
            if let id = selectedCommitID, !commits.contains(where: { $0.id == id }) {
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
        } catch {
            self.error = String(describing: error)
        }
    }

    private func relayout() {
        graph = GraphLayout()
        graph.append(commits)
        graphRows = Dictionary(uniqueKeysWithValues: graph.rows.map { ($0.commitID, $0) })
        graphWidth = graph.maxWidth
    }

    private func loadDetail() async {
        guard let id = selectedCommitID, let commit = commits.first(where: { $0.id == id }) else {
            detail = nil
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
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

    func fetch() async {
        do {
            try await repo.fetch()
            await reload()
        } catch {
            self.error = String(describing: error)
        }
    }
}
