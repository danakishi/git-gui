import Foundation
import GitCore
import Observation

/// Log of git runs for the bottom panel. Keeps only operations that change the
/// repository and any failed commands: reads (log, status, diff) run constantly
/// on every refresh and would only get in the way.
@MainActor
@Observable
final class OperationLog {
    static let shared = OperationLog()

    private(set) var entries: [GitInvocation] = []
    /// The last error, until the user dismisses it.
    var lastFailure: GitInvocation?

    private static let limit = 500

    private init() {}

    /// Subscribes to all git runs. Call once at app startup.
    func install() {
        GitRunner.observer = { invocation in
            Task { @MainActor in OperationLog.shared.record(invocation) }
        }
    }

    private func record(_ invocation: GitInvocation) {
        guard invocation.isMutating || invocation.exitCode != 0 else { return }
        entries.append(invocation)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if invocation.exitCode != 0 { lastFailure = invocation }
    }

    func entries(for repo: GitRepository) -> [GitInvocation] {
        entries.filter { $0.directory == repo.workingDirectory }
    }

    func clear(for repo: GitRepository) {
        entries.removeAll { $0.directory == repo.workingDirectory }
        if lastFailure?.directory == repo.workingDirectory { lastFailure = nil }
    }
}
