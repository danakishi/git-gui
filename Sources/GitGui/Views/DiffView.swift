import GitCore
import SwiftUI

/// Hunk actions in the header: stage/unstage and discard.
struct HunkActions {
    /// Label of the primary button, e.g. "Stage".
    let primaryTitle: String
    let primaryIcon: String
    let primary: (DiffHunk) -> Void
    /// Discards the hunk; `nil` if not applicable (for example, for the index).
    let discard: ((DiffHunk) -> Void)?
}

/// View of a single file's diff: hunks, line numbers, highlighting.
struct DiffView: View {
    let file: FileDiff
    var hunkActions: HunkActions?

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary File", systemImage: "doc.zipper")
        } else if file.hunks.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "doc")
        } else {
            // GeometryReader provides the width of the area: otherwise, in a two-axis ScrollView,
            // the content is narrower than the window and hunk headers don't stretch to full width.
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            HunkHeader(text: hunk.header, hunk: hunk, actions: hunkActions)
                            ForEach(hunk.lines) { line in
                                DiffLineView(line: line)
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var emptyTitle: String {
        switch file.status {
        case .renamed: "Renamed without changes"
        case .copied: "Copied without changes"
        default: "No changes"
        }
    }
}

private struct HunkHeader: View {
    let text: String
    let hunk: DiffHunk
    let actions: HunkActions?

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let actions {
                if let discard = actions.discard {
                    Button {
                        discard(hunk)
                    } label: {
                        Label("Discard", systemImage: "arrow.uturn.backward")
                    }
                    .help("Discard this hunk in the working tree")
                }
                Button {
                    actions.primary(hunk)
                } label: {
                    Label(actions.primaryTitle, systemImage: actions.primaryIcon)
                }
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(line.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .foregroundStyle(line.kind == .meta ? .secondary : .primary)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .foregroundStyle(.tertiary)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.15)
        case .deletion: .red.opacity(0.15)
        default: .clear
        }
    }
}

/// Icon and color of a file's status, shared by file lists.
extension FileDiff.Status {
    var symbol: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        }
    }

    var color: Color {
        switch self {
        case .added: .green
        case .deleted: .red
        case .modified: .orange
        case .renamed, .copied: .blue
        }
    }
}

struct FileStatusBadge: View {
    let status: FileDiff.Status
    var body: some View {
        Text(status.symbol)
            .font(.caption2.weight(.bold))
            .frame(width: 16, height: 16)
            .background(status.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(status.color)
    }
}
