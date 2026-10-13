import GitCore
import Hosting
import SwiftUI

/// Selected commit panel: metadata, file list, and the diff of the selected file.
struct CommitDetailView: View {
    let model: RepositoryModel
    @State private var selectedFile: FileDiff.ID?

    var body: some View {
        if let detail = model.detail {
            // The header sits outside the split view and takes the height of its content:
            // in a fixed-height pane it was centered, ran under the toolbar, and got clipped.
            VStack(spacing: 0) {
                // `fixedSize` here sends the split view into an endless constraints loop.
                header(detail)
                    .layoutPriority(1)
                Divider()
                splitView(detail)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: detail.commit.id, initial: true) {
                selectedFile = detail.files.first?.id
            }
        } else if model.isLoadingDetail {
            ProgressView()
        } else {
            ContentUnavailableView("Select a Commit", systemImage: "circle.dotted")
        }
    }

    /// The file list and the selected file's diff.
    private func splitView(_ detail: CommitDetail) -> some View {
        // A single flat VSplitView: in a nested one the diff's priority doesn't work,
        // and the extra space goes to the file list.
        VSplitView {
            // A bare List in a VSplitView pane doesn't give space to its neighbors;
            // wrapping it in a VStack fixes that.
            VStack(spacing: 0) {
                List(detail.files, selection: $selectedFile) { file in
                    FileRow(file: file).tag(file.id)
                }
                .contextMenu(forSelectionType: FileDiff.ID.self) { ids in
                    if let file = detail.files.first(where: { ids.contains($0.id) }) {
                        fileMenu(file, commit: detail.commit)
                    }
                }
                .overlay {
                    if detail.files.isEmpty {
                        ContentUnavailableView("No Changed Files", systemImage: "doc")
                    }
                }
            }
            .frame(minHeight: 130, idealHeight: 160, maxHeight: 480)
            Group {
                if let file = detail.files.first(where: { $0.id == selectedFile }) {
                    DiffView(file: file)
                } else {
                    Color.clear
                }
            }
            .frame(minHeight: 80, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    private func header(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.commit.subject)
                    .font(.headline)
                    .textSelection(.enabled)
                if !detail.body.isEmpty {
                    Text(detail.body)
                        .font(.body)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .help(detail.body)
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    GridRow {
                        Text("Author").foregroundStyle(.secondary)
                        Text("\(detail.commit.authorName) <\(detail.commit.authorEmail)>").textSelection(.enabled)
                    }
                    GridRow {
                        Text("Date").foregroundStyle(.secondary)
                        Text(detail.commit.authorDate, format: .dateTime.day().month().year().hour().minute().second())
                    }
                    GridRow {
                        Text("SHA").foregroundStyle(.secondary)
                        Text(detail.commit.id).monospaced().textSelection(.enabled)
                    }
                    if !detail.commit.parents.isEmpty {
                        GridRow {
                            Text(detail.commit.parents.count > 1 ? "Parents" : "Parent").foregroundStyle(.secondary)
                            HStack {
                                ForEach(detail.commit.parents, id: \.self) { p in
                                    Button(String(p.prefix(8))) { model.selectedCommitID = p }
                                        .buttonStyle(.link)
                                        .monospaced()
                                }
                            }
                        }
                    }
                    let refs = model.refsByCommit[detail.commit.id] ?? []
                    if !refs.isEmpty {
                        GridRow {
                            Text("Refs").foregroundStyle(.secondary)
                            HStack { RefBadges(refs: refs) }
                        }
                    }
                    hostingRows(detail.commit)
                }
                .font(.callout)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func fileMenu(_ file: FileDiff, commit: Commit) -> some View {
        if !file.isBinary {
            Button("Open in External Diff Tool") { Task { await model.externalDiff(commit: commit, path: file.path) } }
        }
        if file.status != .deleted {
            Button("Open in Editor") { model.openFile(file.path) }
                .help("Opens the file in the working tree, not the version from the commit")
            Button("Show in Finder") { model.revealInFinder(file.path) }
        }
        Divider()
        Button("Copy Path") { model.copyToPasteboard(file.path) }
    }

    /// CI, PRs, and a link to the commit on GitHub/GitLab.
    @ViewBuilder
    private func hostingRows(_ commit: Commit) -> some View {
        let hosting = model.hosting
        if let ci = hosting.ciStatus[commit.id] {
            GridRow {
                Text("CI").foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    CIStatusIcon(status: ci, size: 12)
                    Text(ci.title)
                }
            }
        }
        ForEach(hosting.pullRequestsByCommit[commit.id] ?? []) { pr in
            GridRow {
                Text(hosting.provider?.pullRequestShortName ?? "PR").foregroundStyle(.secondary)
                Button("\(pr.reference) \(pr.title)") { model.open(pr.webURL) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .help("\(pr.sourceBranch) → \(pr.targetBranch), by \(pr.author)")
            }
        }
        if let provider = hosting.provider {
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                Button("Open on \(provider.displayName)") { model.open(provider.webURL(forCommit: commit.id)) }
                    .buttonStyle(.link)
            }
        }
    }
}

/// A file row in lists: status, path, +/−.
struct FileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.status)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.path.components(separatedBy: "/").last ?? file.path)
                    .lineLimit(1)
                let dir = file.path.components(separatedBy: "/").dropLast().joined(separator: "/")
                if !dir.isEmpty {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !file.isBinary {
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}
