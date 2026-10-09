import GitCore
import SwiftUI

/// Commit table. The graph arrives in stage 1; for now, text columns only.
struct CommitListView: View {
    let model: RepositoryModel
    @State private var selection: Commit.ID?

    var body: some View {
        Table(model.commits, selection: $selection) {
            TableColumn("Message") { commit in
                HStack(spacing: 4) {
                    RefBadges(refs: model.refsByCommit[commit.id] ?? [])
                    Text(commit.subject)
                        .lineLimit(1)
                        .fontWeight(commit.isMerge ? .regular : .medium)
                        .foregroundStyle(commit.isMerge ? .secondary : .primary)
                }
                .onAppear {
                    // Load the next batch when we reach the end.
                    if commit.id == model.commits.last?.id {
                        Task { await model.loadMore() }
                    }
                }
            }
            TableColumn("Author", value: \.authorName)
                .width(min: 80, ideal: 140)
            TableColumn("Date") { commit in
                Text(commit.authorDate, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 100, ideal: 130)
            TableColumn("SHA") { commit in
                Text(commit.shortID).monospaced().foregroundStyle(.secondary)
            }
            .width(72)
        }
        .overlay {
            if model.commits.isEmpty, model.isLoading {
                ProgressView("Reading history…")
            } else if let error = model.error {
                ContentUnavailableView("Unable to Read Repository", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
    }
}

/// Branch and tag labels next to the commit message.
struct RefBadges: View {
    let refs: [Ref]

    var body: some View {
        ForEach(refs.sorted(by: order)) { ref in
            Text(ref.shortName)
                .font(.caption2.weight(ref.isHead ? .bold : .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color(for: ref).opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(color(for: ref).opacity(0.6), lineWidth: 0.5))
                .foregroundStyle(color(for: ref))
        }
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
