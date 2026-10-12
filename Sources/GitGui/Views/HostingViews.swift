import Hosting
import SwiftUI

extension CIStatus {
    var title: String {
        switch self {
        case .pending: "CI is waiting to start"
        case .running: "CI is running"
        case .success: "CI passed"
        case .failed: "CI failed"
        case .canceled: "CI canceled"
        case .skipped: "CI skipped"
        }
    }

    var symbol: String {
        switch self {
        case .pending, .running: "clock.fill"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled, .skipped: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending, .running: .orange
        case .success: .green
        case .failed: .red
        case .canceled, .skipped: .gray
        }
    }
}

/// CI status icon.
struct CIStatusIcon: View {
    let status: CIStatus
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size))
            .foregroundStyle(status.color)
            .help(status.title)
    }
}

/// PR label in a graph row: the number, gray for a draft.
struct PullRequestBadge: View {
    let pullRequest: PullRequest

    var body: some View {
        let color: Color = pullRequest.isDraft ? .gray : .green
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 8))
            Text(pullRequest.reference)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .fixedSize()
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 0.5))
        .foregroundStyle(color)
        .help(help)
    }

    private var help: String {
        var lines = ["\(pullRequest.reference) \(pullRequest.title)",
                     "\(pullRequest.sourceBranch) → \(pullRequest.targetBranch)"]
        if pullRequest.isDraft { lines.append("Draft") }
        if let ci = pullRequest.ciStatus { lines.append(ci.title) }
        return lines.joined(separator: "\n")
    }
}

/// Hosting provider state in the status bar: click to refresh.
struct HostingStatusView: View {
    let model: RepositoryModel

    var body: some View {
        let hosting = model.hosting
        if let name = hosting.displayName, let term = hosting.provider?.pullRequestShortName {
            Button {
                Task { await model.refreshHosting() }
            } label: {
                HStack(spacing: 4) {
                    if hosting.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else if hosting.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "arrow.triangle.pull")
                    }
                    Text(hosting.error == nil ? "\(name) · \(hosting.pullRequests.count) \(term)" : "\(name): error")
                }
            }
            .buttonStyle(.borderless)
            .help(help(name))
            .disabled(hosting.isRefreshing)
        } else if let reason = hosting.unavailableReason {
            SettingsLink {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(reason)
        }
    }

    private func help(_ name: String) -> String {
        let hosting = model.hosting
        var lines: [String] = []
        if let error = hosting.error { lines.append(error) }
        if let date = hosting.lastUpdated {
            lines.append("\(name): updated at \(date.formatted(date: .omitted, time: .standard))")
        }
        lines.append("Click to refresh \(model.hosting.provider?.pullRequestShortName ?? "PR") and CI statuses")
        return lines.joined(separator: "\n")
    }
}
