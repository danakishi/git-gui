import GitCore
import SwiftUI

struct ContentView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var columns: NavigationSplitViewVisibility = DebugScreenshot.hideSidebar ? .detailOnly : .automatic

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
        } detail: {
            if let entry = store.selected {
                RepositoryView(model: store.model(for: entry))
                    .id(entry.id)
            } else {
                ContentUnavailableView(
                    "No Repository",
                    systemImage: "folder.badge.plus",
                    description: Text("Press ⌘O or drag a folder into the sidebar.")
                )
            }
        }
        .overlay(alignment: .top) {
            if store.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { store.showPalette = false }
                    CommandPalette(model: store.selectedModel)
                        .padding(.top, 60)
                }
            }
        }
        .onAppear {
            if DebugScreenshot.settingsTab != nil { openSettings() }
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
}

/// Detail area: the commit list, the operation log at the bottom, and the inspector on the right.
struct RepositoryView: View {
    @Bindable var model: RepositoryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.operation != nil {
                OperationBanner(model: model)
                Divider()
            }
            WorkingTreeBar(model: model)
            Divider()
            CommitListView(model: model)
            if model.showLog {
                Divider()
                OperationLogView(model: model)
                    .frame(height: 160)
            }
            Divider()
            StatusBar(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            Group {
                switch model.inspector {
                case .commit: CommitDetailView(model: model)
                case .workingTree: WorkingTreeView(model: model)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 420, max: 900)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Message, author, or sha")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
        .focusedSceneValue(\.repository, model)
        .navigationTitle(model.repo.workingDirectory.lastPathComponent)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await model.start() }
        .task {
            // PR and CI refresh every two minutes while the window is frontmost. The task lives
            // as long as the repository is shown, so background repositories don't hit the API.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if NSApp.isActive { await model.refreshHosting() }
            }
        }
        .onChange(of: Accounts.shared.generation) {
            Task { await model.refreshHosting() }
        }
        .sheet(item: $model.sheet) { sheet in
            if case .interactiveRebase(let base, let commits) = sheet {
                InteractiveRebaseView(model: model, base: base, commits: commits)
            } else if case .conflict(let path) = sheet {
                ConflictEditorView(model: model, path: path)
            } else {
                RepositorySheetView(sheet: sheet, model: model)
            }
        }
        .confirmationDialog(
            "Reset --hard to \(model.confirmHardReset?.shortID ?? "")?",
            isPresented: Binding(get: { model.confirmHardReset != nil }, set: { if !$0 { model.confirmHardReset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset --hard", role: .destructive) {
                if let c = model.confirmHardReset { Task { await model.reset(to: c, mode: .hard) } }
            }
        } message: {
            Text("Uncommitted changes will be lost permanently. The commits stay in the reflog, and you can restore the branch with the Undo button.")
        }
        .confirmationDialog(
            forceDeleteTitle,
            isPresented: Binding(get: { model.confirmForceDelete != nil }, set: { if !$0 { model.confirmForceDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let ref = model.confirmForceDelete { Task { await model.deleteBranch(ref, force: true) } }
            }
        } message: {
            if model.confirmForceDelete?.kind == .remoteBranch {
                Text("The branch will be deleted on the remote.")
            } else {
                Text("The branch is not merged: its commits will remain only in the reflog.")
            }
        }
        .onChange(of: OperationLog.shared.lastFailure?.id) {
            // A failed operation expands the log by itself, so you can see exactly what git said.
            if let f = OperationLog.shared.lastFailure, f.directory == model.repo.workingDirectory { model.showLog = true }
        }
    }

    private var forceDeleteTitle: String {
        guard let ref = model.confirmForceDelete else { return "" }
        return ref.kind == .remoteBranch ? "Delete “\(ref.shortName)” on the remote?" : "Delete unmerged branch “\(ref.shortName)”?"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $model.showAllBranches) {
                Label("All Branches", systemImage: "arrow.triangle.branch")
            }
            .help("Show the history of all branches or only the current one (⇧⌘B)")

            Button {
                model.showBranches.toggle()
            } label: {
                Label("Branches", systemImage: "list.bullet.indent")
            }
            .help("Branches and tags (⌘B)")
            .popover(isPresented: $model.showBranches, arrowEdge: .bottom) { BranchesPopover(model: model) }

            Button {
                model.showStash.toggle()
            } label: {
                Label("Stash", systemImage: "tray")
            }
            .badge(model.stashes.count)
            .help("Stash (⌘S)")
            .popover(isPresented: $model.showStash, arrowEdge: .bottom) { StashPopover(model: model) }
        }

        ToolbarItemGroup {
            Button {
                Task { await model.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            .help("git fetch --all --prune (⇧⌘F)")
            .disabled(model.busy != nil)

            Menu {
                Button("Pull (merge)") { Task { await model.pull(rebase: false) } }
                Button("Pull --rebase") { Task { await model.pull(rebase: true) } }
            } label: {
                Label(pullTitle, systemImage: "arrow.down.to.line")
            } primaryAction: {
                Task { await model.pull(rebase: false) }
            }
            .help(model.hasUpstream ? "git pull (⇧⌘L)" : "This branch has no upstream")
            .disabled(model.busy != nil || !model.hasUpstream)

            Button {
                Task { await model.push() }
            } label: {
                Label(pushTitle, systemImage: "arrow.up.to.line")
            }
            .help(model.hasUpstream ? "git push (⇧⌘P)" : "git push --set-upstream (⇧⌘P)")
            .disabled(model.busy != nil || model.currentBranch == nil)
        }

        ToolbarItemGroup {
            Button {
                Task { await model.undo() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help(undoHelp)
            .disabled(!model.canUndo)

            Button {
                Task {
                    await model.reload()
                    await model.refreshHosting()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload the repository (⌘R)")

            Button {
                model.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    private var undoHelp: String {
        if model.operation != nil { return "Abort the operation and restore everything as it was (⌥⌘Z)" }
        guard let action = model.undoAction else { return "Nothing to undo" }
        let when = action.date.formatted(.relative(presentation: .named))
        return "Undo “\(action.message)” (\(when)), ⌥⌘Z. Pressing again restores the previous state."
    }

    private var pullTitle: String {
        if let b = model.status?.behind, b > 0 { return "Pull ↓\(b)" }
        return "Pull"
    }

    private var pushTitle: String {
        if let a = model.status?.ahead, a > 0 { return "Push ↑\(a)" }
        return "Push"
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
        .onTapGesture { model.showWorkingTree() }
        .help("Changes and commit (⇧⌘C)")
    }

    private func plural(_ n: Int) -> String {
        return n == 1 ? "file" : "files"
    }
}

/// Bottom bar: the running operation or the last error, and the log button.
private struct StatusBar: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.mini)
                Text(busy + "…")
            } else if let error = model.error {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(error).lineLimit(1).truncationMode(.middle).help(error)
                Button("Dismiss") { model.clearError() }
                    .buttonStyle(.borderless).controlSize(.small)
            } else {
                Text("Ready").foregroundStyle(.secondary)
            }
            Spacer()
            HostingStatusView(model: model)
            Toggle(isOn: $model.showLog) {
                Label("Log", systemImage: "terminal")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Operation Log (⌥⌘L)")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
