import GitCore
import SwiftUI

struct ContentView: View {
    @Environment(RepositoryStore.self) private var store
    /// Models of open repositories: kept so they aren't reloaded on every switch.
    @State private var models: [RepositoryEntry.ID: RepositoryModel] = [:]

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let entry = store.selected {
                RepositoryView(model: model(for: entry))
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "folder.badge.plus",
                    description: Text("Press ⌘O or drag a folder into the sidebar.")
                )
            }
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private func model(for entry: RepositoryEntry) -> RepositoryModel {
        if let m = models[entry.id] { return m }
        let m = RepositoryModel(GitRepository(entry.url))
        models[entry.id] = m
        return m
    }
}

/// Detail area: the commit list with the inspector on the right.
struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    @State private var showInspector = true

    var body: some View {
        VStack(spacing: 0) {
            WorkingTreeBar(model: model)
            Divider()
            CommitListView(model: model)
        }
        .inspector(isPresented: $showInspector) {
            Group {
                switch model.inspector {
                case .commit: CommitDetailView(model: model)
                case .workingTree: WorkingTreeView(model: model)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 380, max: 900)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Message, author, or sha")
        .navigationTitle(model.repo.workingDirectory.lastPathComponent)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $model.showAllBranches) {
                    Label("All Branches", systemImage: "arrow.triangle.branch")
                }
                .help("Show the history of all branches or only the current one")

                Button {
                    Task { await model.fetch() }
                } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
                .help("git fetch --all --prune")

                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Reload the repository (⌘R)")

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the inspector (⌥⌘I)")
            }
        }
        .task { await model.start() }
        .alert("Git Error", isPresented: Binding(
            get: { model.error != nil && !model.commits.isEmpty },
            set: { _ in model.clearError() }
        )) {
            Button("OK") {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch model.head {
        case .branch(let name, _): parts.append(name)
        case .detached(let sha): parts.append("detached @ \(sha.prefix(8))")
        case .unborn(let b): parts.append("\(b) (empty)")
        case nil: break
        }
        if let s = model.status {
            if s.ahead > 0 { parts.append("↑\(s.ahead)") }
            if s.behind > 0 { parts.append("↓\(s.behind)") }
        }
        if !model.commits.isEmpty {
            parts.append("\(model.commits.count)\(model.hasMore ? "+" : "") \(model.commits.count == 1 && !model.hasMore ? "commit" : "commits")")
        }
        return parts.joined(separator: " · ")
    }
}

/// Strip above the list: shows how many files changed and switches the inspector to the working tree.
private struct WorkingTreeBar: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        let count = model.status?.entries.count ?? 0
        HStack(spacing: 8) {
            Image(systemName: count == 0 ? "checkmark.circle" : "pencil.circle.fill")
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
            Text(count == 0 ? "Working tree clean" : "\(count) \(plural(count)) changed")
            if let s = model.status, !s.entries.isEmpty {
                Text("· \(model.stagedFiles.count) staged").foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(model.inspector == .workingTree ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.inspector = .workingTree
            model.selectedCommitID = nil
        }
    }

    private func plural(_ n: Int) -> String {
        return n == 1 ? "file" : "files"
    }
}
