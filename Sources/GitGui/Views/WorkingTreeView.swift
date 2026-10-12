import GitCore
import SwiftUI

/// Working tree panel: staged and unstaged files, the selected file's diff, and the commit form.
struct WorkingTreeView: View {
    @Bindable var model: RepositoryModel
    @State private var selection: Set<WorkingFile.ID> = []
    @State private var diff: FileDiff?
    @State private var discardCandidates: [WorkingFile]?
    @State private var confirmDiscardAll = false

    private var allFiles: [WorkingFile] { model.stagedFiles + model.unstagedFiles }
    private var selectedFiles: [WorkingFile] { allFiles.filter { selection.contains($0.id) } }
    /// The single selected file whose diff is shown.
    private var focused: WorkingFile? {
        selection.count == 1 ? allFiles.first { $0.id == selection.first } : nil
    }

    var body: some View {
        VSplitView {
            // The header comes before the list: otherwise the List ends up first under the toolbar
            // and gets a double top inset. The panes above the diff have a maxHeight
            // so that extra space goes to the diff rather than to them.
            VStack(spacing: 0) {
                header
                Divider()
                fileList
            }
            .frame(minHeight: 240, idealHeight: 260, maxHeight: 600)
            diffArea
                .frame(minHeight: 80, maxHeight: .infinity)
                .layoutPriority(1)
            CommitForm(model: model)
                .frame(minHeight: 150, idealHeight: 150, maxHeight: 260)
        }
        .task(id: focused?.id) {
            diff = nil
            guard let focused else { return }
            diff = await model.diff(for: focused)
        }
        .onChange(of: model.status?.entries, initial: true) {
            // After a status refresh, the selected files may have disappeared or moved.
            let ids = Set(allFiles.map(\.id))
            if selection.isEmpty, let id = DebugScreenshot.workingFile, ids.contains(id) { selection = [id] }
            selection = selection.intersection(ids)
            if let focused { Task { diff = await model.diff(for: focused) } }
        }
        .confirmationDialog(
            discardTitle, isPresented: Binding(get: { discardCandidates != nil }, set: { if !$0 { discardCandidates = nil } }),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let files = discardCandidates { Task { await model.discard(files) } }
            }
        } message: {
            Text("Changes in the working tree will be lost and untracked files will be deleted. This can't be undone.")
        }
        .confirmationDialog("Discard All Changes?", isPresented: $confirmDiscardAll, titleVisibility: .visible) {
            Button("Discard All", role: .destructive) { Task { await model.discardAll() } }
        } message: {
            Text("The working tree will be reset to the state of the index, and untracked files will be deleted.")
        }
    }

    private var discardTitle: String {
        guard let files = discardCandidates else { return "" }
        return files.count == 1 ? "Discard “\(files[0].entry.path)”?" : "Discard \(files.count) files?"
    }

    // MARK: Header and file list

    private var header: some View {
        HStack {
            Text("Changes").font(.headline)
            Spacer()
            Button {
                model.sheet = .stash
            } label: {
                Label("Stash…", systemImage: "tray.and.arrow.down")
            }
            .help("git stash push")
            Button(role: .destructive) {
                confirmDiscardAll = true
            } label: {
                Label("Discard All…", systemImage: "arrow.uturn.backward")
            }
            .help("Discard all changes in the working tree")
        }
        .controlSize(.small)
        .disabled(allFiles.isEmpty || model.busy != nil)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var fileList: some View {
        List(selection: $selection) {
            if !model.stagedFiles.isEmpty {
                Section {
                    ForEach(model.stagedFiles) { f in
                        row(f).tag(f.id)
                    }
                } header: {
                    sectionHeader("Staged", count: model.stagedFiles.count,
                                  action: "Unstage All", icon: "minus.circle") { Task { await model.unstageAll() } }
                }
            }
            if !model.unstagedFiles.isEmpty {
                Section {
                    ForEach(model.unstagedFiles) { f in
                        row(f).tag(f.id)
                    }
                } header: {
                    sectionHeader("Unstaged", count: model.unstagedFiles.count,
                                  action: "Stage All", icon: "plus.circle") { Task { await model.stageAll() } }
                }
            }
        }
        .contextMenu(forSelectionType: WorkingFile.ID.self) { ids in
            let files = allFiles.filter { ids.contains($0.id) }
            if !files.isEmpty { fileMenu(files) }
        } primaryAction: { ids in
            // Double-click moves a file between the index and the working tree.
            let files = allFiles.filter { ids.contains($0.id) }
            toggleStage(files)
        }
        .overlay {
            if allFiles.isEmpty {
                ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle")
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, action: String, icon: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text("\(title) (\(count))")
            Spacer()
            Button(action: perform) {
                Label(action, systemImage: icon).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(model.busy != nil)
        }
    }

    private func row(_ file: WorkingFile) -> some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.status)
            Text(file.entry.path).lineLimit(1)
            if file.entry.isConflict {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Conflict")
            }
            Spacer(minLength: 4)
            Button {
                toggleStage([file])
            } label: {
                Image(systemName: file.staged ? "minus" : "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(file.staged ? "Unstage" : "Stage")
            .disabled(model.busy != nil)
        }
        .font(.callout)
        .help(file.entry.originalPath.map { "\($0) → \(file.entry.path)" } ?? file.entry.path)
    }

    @ViewBuilder
    private func fileMenu(_ files: [WorkingFile]) -> some View {
        let staged = files.filter(\.staged), unstaged = files.filter { !$0.staged }
        let conflicts = files.filter(\.entry.isConflict)
        if !conflicts.isEmpty {
            // During a rebase, HEAD is the branch being rebased onto, and incoming is the commit being replayed.
            Button("Take HEAD Version (ours)") { Task { await model.resolveConflict(conflicts, ours: true) } }
            Button("Take Incoming Version (theirs)") { Task { await model.resolveConflict(conflicts, ours: false) } }
            if conflicts.count == 1 {
                Button("Open in Editor") { model.openFile(conflicts[0].entry.path) }
            }
            Divider()
        }
        if !unstaged.isEmpty {
            Button(conflicts.isEmpty ? "Stage" : "Mark as Resolved") { Task { await model.stage(unstaged) } }
        }
        if !staged.isEmpty {
            Button("Unstage") { Task { await model.unstage(staged) } }
        }
        if !unstaged.isEmpty {
            Divider()
            Button("Discard Changes…", role: .destructive) { discardCandidates = unstaged }
        }
        Divider()
        if files.count == 1 {
            Button("Show in Finder") { model.revealInFinder(files[0].entry.path) }
        }
        Button("Copy Path") { model.copyToPasteboard(files.map(\.entry.path).joined(separator: "\n")) }
    }

    private func toggleStage(_ files: [WorkingFile]) {
        let staged = files.filter(\.staged), unstaged = files.filter { !$0.staged }
        Task {
            if !unstaged.isEmpty { await model.stage(unstaged) }
            if !staged.isEmpty { await model.unstage(staged) }
        }
    }

    // MARK: Diff

    @ViewBuilder
    private var diffArea: some View {
        if let diff, let focused {
            DiffView(file: diff, hunkActions: hunkActions(for: focused, diff: diff))
        } else if selection.count > 1 {
            ContentUnavailableView("\(selection.count) Files Selected", systemImage: "doc.on.doc",
                                   description: Text("Actions for all of them are in the context menu."))
        } else if focused != nil {
            ProgressView()
        } else if !allFiles.isEmpty {
            ContentUnavailableView("Select a File", systemImage: "doc.text")
        } else {
            Color.clear
        }
    }

    private func hunkActions(for file: WorkingFile, diff: FileDiff) -> HunkActions? {
        // An untracked file can only be staged as a whole: it is not in the index yet.
        guard file.entry.index != .untracked, diff.hunks.count > 0 else { return nil }
        if file.staged {
            return HunkActions(primaryTitle: "Unstage", primaryIcon: "minus.circle",
                               primary: { h in Task { await model.unstageHunk(h, of: diff) } }, discard: nil)
        }
        return HunkActions(primaryTitle: "Stage", primaryIcon: "plus.circle",
                           primary: { h in Task { await model.stageHunk(h, of: diff) } },
                           discard: { h in Task { await model.discardHunk(h, of: diff) } })
    }
}

/// Commit form: message, amend, button.
private struct CommitForm: View {
    @Bindable var model: RepositoryModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $model.commitMessage)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if model.commitMessage.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Toggle("Amend", isOn: $model.amend)
                    .toggleStyle(.checkbox)
                    .help("Replace the last commit (git commit --amend)")
                Spacer()
                Button {
                    Task { await model.commit() }
                } label: {
                    Text(buttonTitle)
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit || model.busy != nil)
                .help("Commit (⌘↩)")
            }
        }
        .padding(8)
    }

    private var buttonTitle: String {
        if model.amend { return "Amend Commit" }
        let n = model.stagedFiles.count
        return n == 0 ? "Commit" : "Commit (\(n))"
    }
}

/// A working tree file, tagged with the half of the list it is shown in.
struct WorkingFile: Identifiable, Hashable {
    let entry: StatusEntry
    let staged: Bool

    var id: String { (staged ? "staged:" : "unstaged:") + entry.path }

    var status: FileDiff.Status {
        let c = staged ? entry.index : entry.worktree
        switch c {
        case .added, .untracked: return .added
        case .deleted: return .deleted
        case .renamed: return .renamed
        case .copied: return .copied
        default: return .modified
        }
    }
}
