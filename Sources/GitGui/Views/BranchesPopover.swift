import GitCore
import SwiftUI

/// List of branches and tags: click shows the commit, double-click checks it out.
struct BranchesPopover: View {
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
            }
            .contextMenu(forSelectionType: Ref.ID.self) { ids in
                if let ref = model.refs.first(where: { ids.contains($0.id) }) { menu(ref) }
            } primaryAction: { ids in
                if let ref = model.refs.first(where: { ids.contains($0.id) }) {
                    Task { await model.checkout(ref) }
                }
            }
            .onChange(of: selection) {
                // A single click highlights the ref's commit in the graph.
                if let ref = model.refs.first(where: { $0.id == selection }) {
                    model.selectedCommitID = ref.target
                }
            }
            Text("Double-click to check out. Everything else is in the context menu.")
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
                        if let up = ref.upstream {
                            Text(up).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .tag(ref.id)
                    .help(ref.shortName)
                }
            }
        }
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
        if !ref.isHead {
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
