import AppKit
import GitCore
import GraphLayout
import Hosting
import SwiftUI

/// Commit list with a graph on top of NSTableView (see CommitTableView).
struct CommitListView: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        CommitTableView(
            commits: model.filteredCommits,
            graphRows: model.isFiltering ? [:] : model.graphRows,
            refsByCommit: model.refsByCommit,
            headSHA: model.head?.sha,
            pullRequestsByCommit: model.hosting.pullRequestsByCommit,
            ciStatus: model.hosting.ciStatus,
            hostingVersion: model.hosting.version,
            visibleLanes: visibleLanes,
            selection: $model.selectedCommitID,
            onReachEnd: { Task { await model.loadMore() } },
            contextMenu: { commit in contextMenu(for: commit) },
            onDrop: { source, target in
                // Show the menu where the mouse was released; first check whether
                // a fast-forward is possible, which is a git query.
                let location = NSEvent.mouseLocation
                Task {
                    guard let menu = await dropMenu(source: source, target: target) else { return }
                    menu.popUp(positioning: nil, at: location, in: nil)
                }
            }
        )
        .overlay {
            if model.commits.isEmpty, model.isLoading {
                ProgressView("Reading history…")
            } else if let error = model.error, model.commits.isEmpty {
                ContentUnavailableView("Unable to Read Repository", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.isFiltering, model.filteredCommits.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    /// Row menu: check out, branches and tags on this commit, copy.
    private func contextMenu(for commit: Commit) -> NSMenu {
        let menu = NSMenu()
        let refs = model.refsByCommit[commit.id] ?? []
        let busy = model.busy != nil
        let isHead = commit.id == model.head?.sha

        for ref in refs where ref.kind == .localBranch && !ref.isHead {
            menu.addItem(ClosureMenuItem("Check Out \(ref.shortName)", enabled: !busy) {
                Task { await model.checkout(ref) }
            })
        }
        for ref in refs where ref.kind == .remoteBranch {
            menu.addItem(ClosureMenuItem("Check Out \(ref.shortName)", enabled: !busy) {
                Task { await model.checkout(ref) }
            })
        }
        if !isHead || model.currentBranch != nil {
            menu.addItem(ClosureMenuItem("Check Out Commit (detached)", enabled: !busy) {
                Task { await model.checkout(commit: commit.id) }
            })
        }
        addHistoryItems(to: menu, commit: commit, isHead: isHead)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Branch Here…", enabled: !busy) {
            model.sheet = .newBranch(from: commit.id)
        })
        menu.addItem(ClosureMenuItem("New Tag Here…", enabled: !busy) {
            model.sheet = .newTag(at: commit.id)
        })

        let deletable = refs.filter { ($0.kind == .localBranch && !$0.isHead) || $0.kind == .tag }
        if !deletable.isEmpty {
            menu.addItem(.separator())
            for ref in deletable {
                let title = ref.kind == .tag ? "Delete Tag \(ref.shortName)" : "Delete Branch \(ref.shortName)"
                menu.addItem(ClosureMenuItem(title, destructive: true, enabled: !busy) {
                    Task {
                        if ref.kind == .tag {
                            await model.deleteTag(ref)
                        } else if await !model.deleteBranch(ref, force: false) {
                            model.confirmForceDelete = ref
                        }
                    }
                })
            }
        }

        if let provider = model.hosting.provider {
            menu.addItem(.separator())
            for pr in model.hosting.pullRequestsByCommit[commit.id] ?? [] {
                menu.addItem(ClosureMenuItem("Open \(provider.pullRequestShortName) \(pr.reference)") { model.open(pr.webURL) })
            }
            // A local branch and its upstream often point at the same commit: one item per remote branch.
            var offered = Set<String>()
            for ref in refs where ref.kind == .localBranch || ref.kind == .remoteBranch {
                if model.canCreatePullRequest(from: ref), let branch = model.hosting.serverBranch(for: ref),
                   offered.insert(branch).inserted {
                    menu.addItem(ClosureMenuItem("Create \(provider.pullRequestName) from \(ref.shortName)") {
                        model.createPullRequest(from: ref)
                    })
                }
            }
            menu.addItem(ClosureMenuItem("Open Commit on \(provider.displayName)") {
                model.open(provider.webURL(forCommit: commit.id))
            })
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy SHA") { model.copyToPasteboard(commit.id) })
        menu.addItem(ClosureMenuItem("Copy Message") { model.copyToPasteboard(commit.subject) })
        return menu
    }

    /// Merge, rebase, cherry-pick, revert, reset, and interactive rebase relative to the current branch.
    private func addHistoryItems(to menu: NSMenu, commit: Commit, isHead: Bool) {
        let enabled = model.busy == nil && model.operation == nil
        let current = model.currentBranch ?? "HEAD"
        let name = model.name(for: commit)
        let rev = rev(for: commit)

        menu.addItem(.separator())
        if !isHead {
            menu.addItem(ClosureMenuItem("Merge \(name) into \(current)", enabled: enabled) {
                Task { await model.merge(rev) }
            })
            menu.addItem(ClosureMenuItem("Rebase \(current) onto \(name)", enabled: enabled) {
                Task { await model.rebase(onto: rev) }
            })
            menu.addItem(ClosureMenuItem("Cherry-pick \(commit.shortID) onto \(current)", enabled: enabled) {
                Task { await model.cherryPick(commit) }
            })
        }
        menu.addItem(ClosureMenuItem("Revert \(commit.shortID)", enabled: enabled) {
            Task { await model.revert(commit) }
        })
        if !isHead {
            menu.addItem(resetItem(commit: commit, branch: current, enabled: enabled))
        }
        menu.addItem(ClosureMenuItem("Interactive Rebase from Here…", enabled: enabled) {
            Task { await model.beginInteractiveRebase(from: commit) }
        })
    }

    /// "Reset branch to here" with a choice of mode; --hard asks for confirmation.
    private func resetItem(commit: Commit, branch: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Reset \(branch) to Here", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(ClosureMenuItem("Soft — keep changes staged", enabled: enabled) {
            Task { await model.reset(to: commit, mode: .soft) }
        })
        sub.addItem(ClosureMenuItem("Mixed — keep changes in files", enabled: enabled) {
            Task { await model.reset(to: commit, mode: .mixed) }
        })
        sub.addItem(ClosureMenuItem("Hard — discard changes…", destructive: true, enabled: enabled) {
            model.confirmHardReset = commit
        })
        item.submenu = sub
        item.isEnabled = enabled
        return item
    }

    /// Revision for git commands: the branch name if the commit has one, otherwise the full sha.
    private func rev(for commit: Commit) -> String {
        let refs = model.refsByCommit[commit.id] ?? []
        return model.localBranch(at: commit.id)
            ?? refs.first { $0.kind == .remoteBranch }?.shortName
            ?? commit.id
    }

    /// Menu after dragging row `source` onto row `target`, as in GitKraken:
    /// what can be done with one branch and the other. `nil` means there is nothing to offer.
    private func dropMenu(source: Commit, target: Commit) async -> NSMenu? {
        guard model.busy == nil, model.operation == nil else { return nil }
        let menu = NSMenu()
        let current = model.currentBranch
        let headSHA = model.head?.sha
        let sName = model.name(for: source), sRev = rev(for: source)
        let tName = model.name(for: target), tRev = rev(for: target)
        func ancestor(_ a: Commit, of b: Commit) async -> Bool {
            (try? await model.repo.isAncestor(a.id, of: b.id)) ?? false
        }
        func add(_ title: String, _ action: @escaping () async -> Void) {
            menu.addItem(ClosureMenuItem(title) { Task { await action() } })
        }

        if let current, target.id == headSHA {
            // Dropped onto the current branch: pull changes in from source.
            if await ancestor(target, of: source) {
                add("Fast-forward \(current) to \(sName)") { await model.fastForward(branch: current, to: sRev) }
            }
            add("Merge \(sName) into \(current)") { await model.merge(sRev) }
            add("Rebase \(current) onto \(sName)") { await model.rebase(onto: sRev) }
            add("Cherry-pick \(source.shortID) onto \(current)") { await model.cherryPick(source) }
        } else if let current, source.id == headSHA {
            // Dropped the current branch onto another one.
            if await ancestor(source, of: target) {
                add("Fast-forward \(current) to \(tName)") { await model.fastForward(branch: current, to: tRev) }
            }
            add("Rebase \(current) onto \(tName)") { await model.rebase(onto: tRev) }
            add("Merge \(tName) into \(current)") { await model.merge(tRev) }
            menu.addItem(resetItem(commit: target, branch: current, enabled: true))
        } else {
            if let tBranch = model.localBranch(at: target.id) {
                if await ancestor(target, of: source) {
                    add("Fast-forward \(tBranch) to \(sName)") { await model.fastForward(branch: tBranch, to: sRev) }
                }
                add("Check Out \(tBranch) and Merge \(sName)") { await model.merge(sRev, into: tBranch) }
                if let sBranch = model.localBranch(at: source.id) {
                    add("Rebase \(sBranch) onto \(tBranch)") { await model.rebase(onto: tBranch, branch: sBranch) }
                }
            }
            if let current {
                add("Cherry-pick \(source.shortID) onto \(current)") { await model.cherryPick(source) }
            }
        }
        guard !menu.items.isEmpty else { return nil }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Cancel") {})
        return menu
    }

    /// The graph is hidden while searching: the rows are no longer consecutive.
    private var visibleLanes: Int {
        model.isFiltering ? 0 : min(model.graphWidth, model.maxVisibleLanes)
    }
}

/// Branch and tag labels next to the commit message.
struct RefBadges: View {
    let refs: [Ref]
    /// How many labels to show in a row; the rest collapse into "+N".
    var limit = 2

    var body: some View {
        let sorted = refs.sorted(by: order)
        ForEach(sorted.prefix(limit)) { ref in
            badge(ref)
        }
        if sorted.count > limit {
            Text("+\(sorted.count - limit)")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.secondary)
                .help(sorted.dropFirst(limit).map(\.shortName).joined(separator: "\n"))
        }
    }

    private func badge(_ ref: Ref) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon(for: ref))
                .font(.system(size: 8))
            Text(abbreviated(ref.shortName))
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: ref.isHead ? .bold : .medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .fixedSize()
        .background(color(for: ref).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color(for: ref).opacity(0.5), lineWidth: 0.5))
        .foregroundStyle(color(for: ref))
        .help(ref.worktreePath.map { ref.isHead ? ref.shortName : "\(ref.shortName) — checked out in worktree \($0)" } ?? ref.shortName)
    }

    /// Long names such as `origin/feature/sc-15205/cost-item-name-validation`
    /// are truncated in the middle; the full name is in the tooltip.
    private func abbreviated(_ name: String) -> String {
        let max = 30
        guard name.count > max else { return name }
        let head = name.prefix(14), tail = name.suffix(13)
        return "\(head)…\(tail)"
    }

    private func order(_ a: Ref, _ b: Ref) -> Bool {
        if a.isHead != b.isHead { return a.isHead }
        return rank(a.kind) < rank(b.kind)
    }

    private func rank(_ k: Ref.Kind) -> Int {
        switch k {
        case .localBranch: 0
        case .remoteBranch: 1
        case .tag: 2
        case .stash: 3
        case .other: 4
        }
    }

    private func icon(for ref: Ref) -> String {
        switch ref.kind {
        case .localBranch: ref.isHead ? "checkmark" : ref.worktreePath != nil ? "square.on.square" : "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .stash: "tray"
        case .other: "questionmark"
        }
    }

    private func color(for ref: Ref) -> Color {
        switch ref.kind {
        case .localBranch: ref.isHead ? .green : .blue
        case .remoteBranch: .purple
        case .tag: .orange
        case .stash: .gray
        case .other: .secondary
        }
    }
}
