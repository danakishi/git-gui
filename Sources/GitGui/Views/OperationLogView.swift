import GitCore
import SwiftUI

/// The bottom panel: what was run and how it ended.
struct OperationLogView: View {
    let model: RepositoryModel
    @State private var expanded: Set<GitInvocation.ID> = []

    var body: some View {
        let log = OperationLog.shared
        let entries = log.entries(for: model.repo)
        VStack(spacing: 0) {
            HStack {
                Text("Operation Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear(for: model.repo) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            if entries.isEmpty {
                Text("Nothing yet: git operations and errors will appear here.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // New entries are on top, so there is no need to scroll to the start.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.reversed()) { e in
                            row(e)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: GitInvocation) -> some View {
        let failed = e.exitCode != 0
        let stderr = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(failed ? Color.red : Color.secondary)
                Text(e.date, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(e.commandLine)
                    .monospaced()
                    .lineLimit(expanded.contains(e.id) ? nil : 1)
                    .textSelection(.enabled)
                Spacer()
                Text(String(format: "%.2f s", e.duration)).foregroundStyle(.tertiary).monospacedDigit()
                if failed { Text("exit code \(e.exitCode)").foregroundStyle(.red) }
            }
            if !stderr.isEmpty, failed || expanded.contains(e.id) {
                Text(stderr)
                    .monospaced()
                    .foregroundStyle(failed ? .red : .secondary)
                    .lineLimit(expanded.contains(e.id) ? nil : 3)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
        .font(.system(size: 11))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
        }
    }
}
