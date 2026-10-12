import GitCore
import SwiftUI

/// Three-pane conflict editor: ours and theirs on top, the result below.
///
/// In the top panes, each conflict has a "Take" button: the selected sides
/// go into the result in the order they were selected. The result can be edited by hand;
/// after a manual edit, choosing sides no longer overwrites it until the edits
/// are reset.
struct ConflictEditorView: View {
    let model: RepositoryModel
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var file: ConflictFile?
    @State private var loadError: String?
    @State private var choices: [Int: [ConflictFile.Side]] = [:]
    @State private var result = ""
    @State private var manual = false
    /// The conflict the panes are scrolled to.
    @State private var focus = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let file {
                VSplitView {
                    HSplitView {
                        SidePane(file: file, side: .ours, title: title(.ours, file), choices: choices,
                                 focus: focus, toggle: toggle)
                        SidePane(file: file, side: .theirs, title: title(.theirs, file), choices: choices,
                                 focus: focus, toggle: toggle)
                    }
                    .frame(minHeight: 200, idealHeight: 380)
                    resultPane
                        .frame(minHeight: 160, idealHeight: 300)
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Nothing to Show", systemImage: "doc.questionmark")
                } description: {
                    Text(loadError)
                } actions: {
                    HStack {
                        Button("Take HEAD Version") { resolveWhole(ours: true) }
                        Button("Take Incoming Version") { resolveWhole(ours: false) }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1100, idealWidth: 1300, minHeight: 720, idealHeight: 860)
        .task { await load() }
        .onChange(of: choices) {
            if !manual, let file { result = file.resolved(choices) }
        }
    }

    // MARK: Window parts

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let file, file.conflicts.count > 1 {
                Text("Conflict \(focus + 1) of \(file.conflicts.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                ControlGroup {
                    Button { focus = max(0, focus - 1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous Conflict (⌥⌘↑)")
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .disabled(focus == 0)
                    Button { focus = min(file.conflicts.count - 1, focus + 1) } label: { Image(systemName: "chevron.down") }
                        .help("Next Conflict (⌥⌘↓)")
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .disabled(focus >= file.conflicts.count - 1)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var resultPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Result").font(.subheadline.weight(.semibold))
                if manual {
                    Text("· edited manually").font(.caption).foregroundStyle(.secondary)
                    Button("Reset Edits") {
                        manual = false
                        if let file { result = file.resolved(choices) }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                Spacer()
                Text(remainingText)
                    .font(.caption)
                    .foregroundStyle(remaining == 0 ? Color.green : Color.orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            TextEditor(text: Binding(get: { result }, set: { newValue in
                result = newValue
                if let file, newValue != file.resolved(choices) { manual = true }
            }))
            .codeFont()
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack {
            Button("External Tool…") {
                dismiss()
                Task { await model.externalMerge(path) }
            }
            .help("git mergetool" + (Preferences.mergeTool.map { " --tool=\($0)" } ?? ""))
            Button("Open in Editor") { model.openFile(path) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save(markResolved: false) }
                .help("Write the file without marking the conflict as resolved")
                .disabled(file == nil)
            Button("Save and Mark as Resolved") { save(markResolved: true) }
                .keyboardShortcut(.defaultAction)
                .disabled(file == nil || remaining > 0)
                .help(remaining > 0 ? "Resolve all conflicts first" : "Write the file and stage it")
        }
        .padding(12)
    }

    // MARK: State

    private var hint: String {
        switch model.operation?.kind {
        case .rebase: "Rebase: ours is the branch being rebased onto; theirs is the commit being replayed."
        case .cherryPick: "Cherry-pick: ours is the current branch; theirs is the commit being applied."
        case .revert: "Revert: ours is the current branch; theirs is the commit being reverted."
        default: "Merge: ours is the current branch; theirs is the incoming one."
        }
    }

    private func title(_ side: ConflictFile.Side, _ file: ConflictFile) -> String {
        let label = file.conflicts.first.map { side == .ours ? $0.oursLabel : $0.theirsLabel } ?? ""
        let name = side == .ours ? "Ours" : "Theirs"
        return label.isEmpty ? name : "\(name) — \(label)"
    }

    /// How many conflicts remain: based on the chosen sides or, after manual edits, on the markers in the text.
    private var remaining: Int {
        if manual {
            return ConflictFile.parse(result)?.conflicts.count ?? (ConflictFile.hasMarkers(result) ? 1 : 0)
        }
        return (file?.conflicts.count ?? 0) - choices.count
    }

    private var remainingText: String {
        remaining == 0 ? "No conflicts left" : "Conflicts remaining: \(remaining)"
    }

    private func toggle(_ index: Int, _ side: ConflictFile.Side) {
        var sides = choices[index] ?? []
        if let i = sides.firstIndex(of: side) {
            sides.remove(at: i)
        } else {
            sides.append(side)
        }
        // Both sides were deselected, so the conflict is unresolved again.
        choices[index] = sides.isEmpty ? nil : sides
        focus = index
    }

    private func load() async {
        let url = model.repo.workingDirectory.appending(path: path)
        guard let data = try? Data(contentsOf: url) else {
            loadError = "The file is not in the working tree: it was deleted on one of the sides."
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            loadError = "The file is binary or not UTF-8."
            return
        }
        guard let parsed = ConflictFile.parse(text) else {
            loadError = "The file has no conflict markers: for example, it was modified on one side and deleted on the other."
            return
        }
        file = parsed
        result = text
    }

    private func save(markResolved: Bool) {
        let text = result
        dismiss()
        Task { await model.saveResolution(path, text: text, markResolved: markResolved) }
    }

    private func resolveWhole(ours: Bool) {
        guard let entry = model.status?.entries.first(where: { $0.path == path }) else { return }
        dismiss()
        Task { await model.resolveConflict([WorkingFile(entry: entry, staged: false)], ours: ours) }
    }
}

/// One side of a conflict: the common text and this side's conflict blocks.
private struct SidePane: View {
    let file: ConflictFile
    let side: ConflictFile.Side
    let title: String
    let choices: [Int: [ConflictFile.Side]]
    let focus: Int
    let toggle: (Int, ConflictFile.Side) -> Void

    private var tint: Color { side == .ours ? .blue : .purple }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            // The pane width is needed so that narrow text doesn't end up in the middle of
            // the two-axis ScrollView, and conflict headers stretch to the full width.
            GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(blocks) { block in
                            if let index = block.conflict {
                                conflictHeader(index)
                                    .id("c\(index)")
                            }
                            ForEach(block.lines) { line in
                                lineView(line, highlighted: block.conflict != nil)
                            }
                        }
                    }
                    .codeFont()
                    .padding(.bottom, 8)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
                .onChange(of: focus, initial: true) {
                    withAnimation { proxy.scrollTo("c\(focus)", anchor: .top) }
                }
            }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func conflictHeader(_ index: Int) -> some View {
        let sides = choices[index] ?? []
        let taken = sides.contains(side)
        let order = sides.count == 2 ? (sides.first == side ? " · first" : " · second") : ""
        return HStack(spacing: 6) {
            Text("Conflict \(index + 1)").fixedSize()
            if sides.isEmpty {
                Text("· unresolved").foregroundStyle(.orange)
            } else if !taken {
                Text("· not taken").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                toggle(index, side)
            } label: {
                Label(taken ? "Taken\(order)" : "Take", systemImage: taken ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.borderless)
            .help(taken ? "Remove this side from the result" : "Add this side to the result")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(index == focus ? 0.28 : 0.16))
    }

    private func lineView(_ line: NumberedLine, highlighted: Bool) -> some View {
        HStack(spacing: 0) {
            Text(line.number.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
                .foregroundStyle(.tertiary)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? tint.opacity(0.10) : Color.clear)
        .foregroundStyle(highlighted ? Color.primary : Color.secondary)
    }

    struct NumberedLine: Identifiable {
        let id: Int
        let number: Int?
        let text: String
    }

    struct Block: Identifiable {
        let id: Int
        /// The conflict number, or `nil` for a common chunk.
        let conflict: Int?
        let lines: [NumberedLine]
    }

    /// File chunks as seen by this side, with line numbers from its version.
    private var blocks: [Block] {
        var result: [Block] = []
        var number = 1, lineID = 0, conflict = 0
        func numbered(_ lines: [String]) -> [NumberedLine] {
            lines.map { text in
                defer { number += 1; lineID += 1 }
                return NumberedLine(id: lineID, number: number, text: text)
            }
        }
        for (i, chunk) in file.chunks.enumerated() {
            switch chunk {
            case .common(let lines):
                result.append(Block(id: i, conflict: nil, lines: numbered(lines)))
            case .conflict(let c):
                var lines = numbered(c.lines(side))
                if lines.isEmpty {
                    lines = [NumberedLine(id: lineID, number: nil, text: "(empty)")]
                    lineID += 1
                }
                result.append(Block(id: i, conflict: conflict, lines: lines))
                conflict += 1
            }
        }
        return result
    }
}
