import GitCore
import SwiftUI

/// The bar above the list while a merge/rebase/cherry-pick/revert is unfinished.
struct OperationBanner: View {
    let model: RepositoryModel

    var body: some View {
        if let op = model.operation {
            let conflicts = model.conflictCount
            HStack(spacing: 10) {
                Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "pause.circle.fill")
                    .foregroundStyle(conflicts > 0 ? .orange : .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(op)).fontWeight(.semibold)
                    Text(hint(conflicts)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abort", role: .destructive) { Task { await model.abortOperation() } }
                    .help("Restore everything to the state before the operation started")
                if op.kind.canSkip {
                    Button("Skip") { Task { await model.skipOperation() } }
                        .help("Drop the current commit and move on")
                }
                Button("Continue") { Task { await model.continueOperation() } }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(conflicts > 0 ? "Resolve the conflicts first" : "Continue (⇧⌘↩)")
                    .disabled(conflicts > 0)
            }
            .controlSize(.small)
            .disabled(model.busy != nil)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background((conflicts > 0 ? Color.orange : Color.blue).opacity(0.12))
        }
    }

    private func title(_ op: OperationState) -> String {
        let target = op.target.map { String($0.prefix(8)) } ?? ""
        switch op.kind {
        case .merge:
            return "Merging \(target) into \(model.currentBranch ?? "HEAD")"
        case .rebase:
            var s = "Rebasing"
            if let b = op.branch { s += " \(b)" }
            if !target.isEmpty { s += " onto \(target)" }
            if let step = op.step, let total = op.total { s += " · step \(step) of \(total)" }
            return s
        case .cherryPick:
            return "Cherry-picking \(target)"
        case .revert:
            return "Reverting \(target)"
        }
    }

    private func hint(_ conflicts: Int) -> String {
        if conflicts > 0 {
            return "Conflicts: \(conflicts). Resolve them in the Changes panel and stage the files."
        }
        return "No conflicts: you can continue."
    }
}

/// The interactive rebase window: the order and action for each commit.
///
/// Commits are shown as in the graph, newest on top. squash and fixup meld a
/// commit into the one below it (the older one).
struct InteractiveRebaseView: View {
    let model: RepositoryModel
    let base: String?
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [Row]
    private let initialOrder: [String]

    init(model: RepositoryModel, base: String?, commits: [Commit]) {
        self.model = model
        self.base = base
        let rows = commits.reversed().map { Row(commit: $0) }
        _rows = State(initialValue: rows)
        initialOrder = rows.map(\.id)
    }

    struct Row: Identifiable {
        let commit: Commit
        var action: Action = .pick
        var message: String

        init(commit: Commit) {
            self.commit = commit
            self.message = commit.subject
        }

        var id: String { commit.id }
    }

    enum Action: String, CaseIterable, Identifiable {
        case pick, reword, squash, fixup, edit, drop
        var id: String { rawValue }

        var title: String {
            switch self {
            case .pick: "Keep"
            case .reword: "Reword"
            case .squash: "Squash down"
            case .fixup: "Fixup down"
            case .edit: "Stop"
            case .drop: "Drop"
            }
        }

        var help: String {
            switch self {
            case .pick: "Keep the commit as is"
            case .reword: "Keep with a new message"
            case .squash: "Meld into the commit below, combining the messages"
            case .fixup: "Meld into the commit below, keeping its message"
            case .edit: "Stop after the commit so you can amend it"
            case .drop: "Remove the commit from history"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interactive Rebase").font(.headline)
            Text("\(rows.count) \(rows.count == 1 ? "commit" : "commits") on \(base.map { String($0.prefix(8)) } ?? "the root of history"). Newest on top; drag to reorder.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach($rows) { $row in
                    HStack(spacing: 8) {
                        Picker("", selection: $row.action) {
                            ForEach(Action.allCases) { a in Text(a.title).tag(a).help(a.help) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Text(row.commit.shortID)
                            .monospaced()
                            .foregroundStyle(.secondary)
                        if row.action == .reword {
                            TextField("Message", text: $row.message)
                        } else {
                            Text(row.commit.subject)
                                .lineLimit(1)
                                .strikethrough(row.action == .drop)
                                .foregroundStyle(row.action == .drop ? .secondary : .primary)
                        }
                        Spacer(minLength: 0)
                    }
                    .help(row.action.help)
                }
                .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 240)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Text("You can undo the result with the Undo button (⌥⌘Z).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }

    /// Steps for git, oldest first.
    private var steps: [RebaseStep] {
        rows.reversed().map { row in
            let action: RebaseStep.Action = switch row.action {
            case .pick: .pick
            case .reword: .reword(row.message)
            case .squash: .squash
            case .fixup: .fixup
            case .edit: .edit
            case .drop: .drop
            }
            return RebaseStep(sha: row.commit.id, action: action)
        }
    }

    private var problem: String? {
        let kept = rows.reversed().filter { $0.action != .drop }
        if kept.isEmpty { return "All commits are dropped; use reset for that." }
        if let first = kept.first, first.action == .squash || first.action == .fixup {
            return "There is nothing to meld the bottom-most remaining commit into."
        }
        if rows.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "The commit message is empty."
        }
        let unchanged = rows.allSatisfy { $0.action == .pick } && rows.map(\.id) == initialOrder
        return unchanged ? "Nothing has changed." : nil
    }

    private func start() {
        let steps = steps
        dismiss()
        Task { await model.interactiveRebase(base: base, steps: steps) }
    }
}
