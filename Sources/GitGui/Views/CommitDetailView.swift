import GitCore
import SwiftUI

/// Selected commit panel: metadata, file list, and the diff of the selected file.
struct CommitDetailView: View {
    let model: RepositoryModel
    @State private var selectedFile: FileDiff.ID?

    var body: some View {
        if let detail = model.detail {
            VSplitView {
                header(detail)
                    .frame(minHeight: 110, idealHeight: 160)
                fileAndDiff(detail)
            }
            .onChange(of: detail.commit.id, initial: true) {
                selectedFile = detail.files.first?.id
            }
        } else if model.isLoadingDetail {
            ProgressView()
        } else {
            ContentUnavailableView("Select a Commit", systemImage: "circle.dotted")
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
                }
                .font(.callout)
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func fileAndDiff(_ detail: CommitDetail) -> some View {
        VSplitView {
            List(detail.files, selection: $selectedFile) { file in
                FileRow(file: file).tag(file.id)
            }
            .frame(minHeight: 80, idealHeight: 160)
            .overlay {
                if detail.files.isEmpty {
                    ContentUnavailableView("No Changed Files", systemImage: "doc")
                }
            }

            if let file = detail.files.first(where: { $0.id == selectedFile }) {
                DiffView(file: file)
            } else {
                Color.clear
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
