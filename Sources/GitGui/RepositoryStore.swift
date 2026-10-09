import AppKit
import Foundation
import GitCore
import Observation

/// A repository in the app's list.
struct RepositoryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var path: String
    var name: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// The user's repository list; stored in Application Support.
@MainActor
@Observable
final class RepositoryStore {
    private(set) var entries: [RepositoryEntry] = []
    var selectedID: RepositoryEntry.ID?
    var lastError: String?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appending(path: "GitGui", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "repositories.json")
        load()
    }

    var selected: RepositoryEntry? {
        entries.first { $0.id == selectedID }
    }

    /// Adds a folder. If it is a subfolder of a repository, uses the repository root.
    func add(_ url: URL) async {
        guard let repo = await GitRepository.discover(at: url) else {
            lastError = "\(url.path) is not a git repository"
            return
        }
        let path = repo.workingDirectory.path
        if let existing = entries.first(where: { $0.path == path }) {
            selectedID = existing.id
            return
        }
        let entry = RepositoryEntry(id: UUID(), path: path, name: repo.workingDirectory.lastPathComponent)
        entries.append(entry)
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedID = entry.id
        save()
    }

    func remove(_ id: RepositoryEntry.ID) {
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries.first?.id }
        save()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a git repository folder"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { for u in urls { await add(u) } }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([RepositoryEntry].self, from: data) else { return }
        entries = list
        selectedID = list.first?.id
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
