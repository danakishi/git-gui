import GitCore
import SwiftUI

/// List of branches, tags, worktrees, and submodules: click shows the commit,
/// double-click checks it out (a worktree or submodule is opened as a repository).
struct BranchesPopover: View {
    @Environment(RepositoryStore.self) private var store
    @Bindable var model: RepositoryModel
    @State private var filter = ""
    @State private var selection: Ref.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button {
                    model.sheet = .newBranch(from: nil)
                } label: {
                    Label("New Branch", systemImage: "plus")
                }
                .help("Create a branch from HEAD")
            }
            .padding(8)
            List(selection: $selection) {
                section("Local", model.localBranches)
                section("Remote", model.remoteBranches)
                section("Tags", model.tags)
                worktreeSection
                submoduleSection
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let ref = model.refs.first(where: { ids.contains($0.id) }) {
                    menu(ref)
                } else if let id = ids.first, let url = repositoryURL(id) {
                    repositoryMenu(url)
                }
            } primaryAction: { ids in
                if let ref = model.refs.first(where: { ids.contains($0.id) }) {
                    if let path = ref.worktreePath, model.isInOtherWorktree(ref) {
                        open(URL(fileURLWithPath: path, isDirectory: true))
                    } else {
                        Task { await model.checkout(ref) }
                    }
                } else if let id = ids.first, let url = repositoryURL(id) {
                    open(url)
                }
            }
            .onChange(of: selection) {
                // A single click highlights the ref's commit in the graph.
                if let ref = model.refs.first(where: { $0.id == selection }) {
                    model.selectedCommitID = ref.target
                }
            }
            Text("Double-click to check out or open. Everything else is in the context menu.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 340, height: 460)
    }

    @ViewBuilder
    private func section(_ title: String, _ refs: [Ref]) -> some View {
        let shown = refs.filter { filter.isEmpty || $0.shortName.localizedCaseInsensitiveContains(filter) }
        if !shown.isEmpty {
            Section("\(title) (\(shown.count))") {
                ForEach(shown) { ref in
                    HStack(spacing: 6) {
                        Image(systemName: ref.isHead ? "checkmark.circle.fill" : icon(ref))
                            .foregroundStyle(ref.isHead ? .green : .secondary)
                            .frame(width: 14)
                        Text(ref.shortName)
                            .fontWeight(ref.isHead ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        if let pr = model.hosting.pullRequest(for: ref) {
                            PullRequestBadge(pullRequest: pr)
                        }
                        if let path = ref.worktreePath, model.isInOtherWorktree(ref) {
                            Label((path as NSString).lastPathComponent, systemImage: "square.on.square")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .help("Checked out in worktree \(path)")
                        } else if let up = ref.upstream {
                            Text(up).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .tag(ref.id)
                    .help(ref.shortName)
                }
            }
        }
    }

    // MARK: Worktrees and submodules

    private static let worktreePrefix = "worktree:"
    private static let submodulePrefix = "submodule:"

    @ViewBuilder
    private var worktreeSection: some View {
        // A regular repository has a single worktree, itself, so there is nothing to show.
        let shown = model.worktrees.filter { model.worktrees.count > 1 && matches($0.path) }
        if !shown.isEmpty {
            Section("Worktrees (\(shown.count))") {
                ForEach(shown) { wt in
                    let current = wt.path == model.repo.workingDirectory.path
                    HStack(spacing: 6) {
                        Image(systemName: current ? "checkmark.circle.fill" : "square.on.square")
                            .foregroundStyle(current ? .green : .secondary)
                            .frame(width: 14)
                        Text((wt.path as NSString).lastPathComponent)
                            .fontWeight(current ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        if wt.isPrunable {
                            Text("directory missing").font(.caption).foregroundStyle(.orange)
                        } else if wt.isLocked {
                            Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(wt.branch ?? wt.head.map { String($0.prefix(8)) } ?? (wt.isBare ? "bare" : ""))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .tag(Self.worktreePrefix + wt.path)
                    .help(wt.path)
                }
            }
        }
    }

    @ViewBuilder
    private var submoduleSection: some View {
        let shown = model.submodules.filter { matches($0.path) }
        if !shown.isEmpty {
            Section("Submodules (\(shown.count))") {
                ForEach(shown) { sub in
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 14)
                        Text(sub.path).lineLimit(1)
                        Spacer()
                        Text(submoduleState(sub))
                            .font(.caption)
                            .foregroundStyle(sub.state == .upToDate ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                    .tag(Self.submodulePrefix + sub.path)
                    .help("\(sub.path) @ \(sub.sha.prefix(8))" + (sub.describe.map { " (\($0))" } ?? ""))
                }
            }
        }
    }

    private func submoduleState(_ sub: Submodule) -> String {
        switch sub.state {
        case .upToDate: sub.describe ?? String(sub.sha.prefix(8))
        case .uninitialized: "not initialized"
        case .otherCommit: "different commit"
        case .conflict: "conflict"
        }
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedCaseInsensitiveContains(filter)
    }

    /// Directory of a worktree or an initialized submodule, by the row tag.
    private func repositoryURL(_ id: String) -> URL? {
        if id.hasPrefix(Self.worktreePrefix) {
            let path = String(id.dropFirst(Self.worktreePrefix.count))
            guard model.worktrees.first(where: { $0.path == path })?.isPrunable == false else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if id.hasPrefix(Self.submodulePrefix) {
            let path = String(id.dropFirst(Self.submodulePrefix.count))
            guard model.submodules.first(where: { $0.path == path })?.state != .uninitialized else { return nil }
            return model.repo.workingDirectory.appending(path: path, directoryHint: .isDirectory)
        }
        return nil
    }

    @ViewBuilder
    private func repositoryMenu(_ url: URL) -> some View {
        if url.path != model.repo.workingDirectory.path {
            Button("Open as Repository") { open(url) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") { model.copyToPasteboard(url.path) }
        if !model.submodules.isEmpty {
            Divider()
            Button("Update Submodules") { Task { await model.updateSubmodules() } }
                .help("git submodule update --init --recursive")
        }
        if model.worktrees.contains(where: \.isPrunable) {
            Divider()
            Button("Prune Missing Worktrees") { Task { await model.pruneWorktrees() } }
                .help("git worktree prune")
        }
    }

    /// Adds the directory to the repository list and switches to it.
    private func open(_ url: URL) {
        Task { await store.add(url) }
    }

    private func icon(_ ref: Ref) -> String {
        switch ref.kind {
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .stash: "tray"
        case .other: "questionmark"
        }
    }

    @ViewBuilder
    private func menu(_ ref: Ref) -> some View {
        if let path = ref.worktreePath, model.isInOtherWorktree(ref) {
            Button("Open Worktree “\((path as NSString).lastPathComponent)”") {
                open(URL(fileURLWithPath: path, isDirectory: true))
            }
        } else if !ref.isHead {
            Button(ref.kind == .tag ? "Check Out Tag (detached)" : "Check Out") {
                Task { await model.checkout(ref) }
            }
        }
        Button("Show in Graph") { model.selectedCommitID = ref.target }
        Divider()
        Button("New Branch Here…") { model.sheet = .newBranch(from: ref.target) }
        if ref.kind == .localBranch {
            Button("Rename…") { model.sheet = .renameBranch(ref) }
        }
        if let provider = model.hosting.provider, ref.kind != .tag {
            Divider()
            if let pr = model.hosting.pullRequest(for: ref) {
                Button("Open \(provider.pullRequestShortName) \(pr.reference)") { model.open(pr.webURL) }
            } else if model.canCreatePullRequest(from: ref) {
                Button("Create \(provider.pullRequestName)") { model.createPullRequest(from: ref) }
            }
            if let branch = model.hosting.serverBranch(for: ref) {
                Button("Open Branch on \(provider.displayName)") { model.open(provider.webURL(forBranch: branch)) }
            }
        }
        Divider()
        Button("Copy Name") { model.copyToPasteboard(ref.shortName) }
        Divider()
        switch ref.kind {
        case .localBranch:
            Button("Delete Branch…", role: .destructive) {
                Task {
                    if await !model.deleteBranch(ref, force: false) { model.confirmForceDelete = ref }
                }
            }
            .disabled(ref.isHead)
        case .remoteBranch:
            Button("Delete from Remote…", role: .destructive) { model.confirmForceDelete = ref }
        case .tag:
            Button("Delete Tag", role: .destructive) { Task { await model.deleteTag(ref) } }
        default:
            EmptyView()
        }
    }
}
