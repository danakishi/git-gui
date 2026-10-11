import GitCore
import SwiftUI

/// Working tree panel: staged and unstaged files, plus the diff of the selected one.
/// Stage/unstage arrive in stage 2; for now it is view-only.
struct WorkingTreeView: View {
    let model: RepositoryModel
    @State private var selection: WorkingFile.ID?
    @State private var diff: FileDiff?

    var body: some View {
        VSplitView {
            List(selection: $selection) {
                if !model.stagedFiles.isEmpty {
                    Section("Staged (\(model.stagedFiles.count))") {
                        ForEach(model.stagedFiles) { f in
                            WorkingFileRow(file: f).tag(f.id)
                        }
                    }
                }
                if !model.unstagedFiles.isEmpty {
                    Section("Unstaged (\(model.unstagedFiles.count))") {
                        ForEach(model.unstagedFiles) { f in
                            WorkingFileRow(file: f).tag(f.id)
                        }
                    }
                }
            }
            .frame(minHeight: 100, idealHeight: 220)
            .overlay {
                if model.stagedFiles.isEmpty, model.unstagedFiles.isEmpty {
                    ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.circle")
                }
            }

            Group {
                if let diff {
                    DiffView(file: diff)
                } else if selection != nil {
                    ProgressView()
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text")
                }
            }
        }
        .task(id: selection) {
            diff = nil
            guard let selection,
                  let file = (model.stagedFiles + model.unstagedFiles).first(where: { $0.id == selection })
            else { return }
            diff = await model.diff(for: file)
        }
        .onChange(of: model.status?.entries) {
            // The selected file may have disappeared after the status refresh.
            let all = model.stagedFiles + model.unstagedFiles
            if let selection, !all.contains(where: { $0.id == selection }) { self.selection = nil }
        }
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

private struct WorkingFileRow: View {
    let file: WorkingFile

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.status)
            Text(file.entry.path).lineLimit(1)
            if file.entry.isConflict {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Conflict")
            }
        }
        .font(.callout)
        .help(file.entry.originalPath.map { "\($0) → \(file.entry.path)" } ?? file.entry.path)
    }
}
