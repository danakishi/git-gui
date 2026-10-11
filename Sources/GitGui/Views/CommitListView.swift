import GitCore
import GraphLayout
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
            visibleLanes: visibleLanes,
            selection: $model.selectedCommitID,
            onReachEnd: { Task { await model.loadMore() } }
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
        .help(ref.shortName)
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
        case .localBranch: ref.isHead ? "checkmark" : "arrow.triangle.branch"
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
