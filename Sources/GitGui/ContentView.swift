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

/// Detail area: the commit list of the selected repository.
struct RepositoryView: View {
    let model: RepositoryModel

    var body: some View {
        CommitListView(model: model)
            .navigationTitle(model.repo.workingDirectory.lastPathComponent)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup {
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
                }
            }
            .task { await model.reload() }
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
            if !s.entries.isEmpty { parts.append("\(s.entries.count) changed") }
        }
        if !model.commits.isEmpty {
            parts.append("\(model.commits.count)\(model.hasMore ? "+" : "") \(model.commits.count == 1 && !model.hasMore ? "commit" : "commits")")
        }
        return parts.joined(separator: " · ")
    }
}
