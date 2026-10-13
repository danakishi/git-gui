import AppKit
import Foundation
import GitCore
import Observation

/// A repository in the app's list.
struct RepositoryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var path: String
    var name: String
    /// A group in the sidebar; `nil` means ungrouped.
    var group: String?
    var isFavorite = false

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    init(id: UUID, path: String, name: String, group: String? = nil, isFavorite: Bool = false) {
        self.id = id
        self.path = path
        self.name = name
        self.group = group
        self.isFavorite = isFavorite
    }

    // Entries from the file written before groups and favorites: they have no new fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

/// The user's repository list, groups, and favorites; stored in Application Support.
@MainActor
@Observable
final class RepositoryStore {
    private(set) var entries: [RepositoryEntry] = []
    /// Groups in display order. An empty group is kept too, until it is deleted.
    private(set) var groups: [String] = []
    /// Collapsed sidebar sections: group names and `favoritesKey`.
    private(set) var collapsed: Set<String> = []
    var selectedID: RepositoryEntry.ID? {
        didSet { if selectedID != oldValue { save() } }
    }
    var lastError: String?
    /// The ⌘K palette is open.
    var showPalette = false
    /// Where HEAD is in each repository, for the sidebar. The open repository updates its own
    /// entry on every reload; the rest are reread when the app becomes active.
    private(set) var heads: [RepositoryEntry.ID: Head] = [:]

    static let favoritesKey = "\u{0}favorites"

    /// Models of open repositories: kept so they aren't reloaded on every switch.
    @ObservationIgnored private var models: [RepositoryEntry.ID: RepositoryModel] = [:]

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appending(path: "GitGui", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = DebugScreenshot.libraryPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? dir.appending(path: "repositories.json")
        load()
        showPalette = DebugScreenshot.paletteQuery != nil
    }

    var selected: RepositoryEntry? {
        entries.first { $0.id == selectedID }
    }

    /// The repository model; created on first access.
    func model(for entry: RepositoryEntry) -> RepositoryModel {
        if let m = models[entry.id] { return m }
        let m = RepositoryModel(GitRepository(entry.url))
        models[entry.id] = m
        return m
    }

    var selectedModel: RepositoryModel? { selected.map(model(for:)) }

    func setHead(_ head: Head?, for id: RepositoryEntry.ID) {
        if heads[id] != head { heads[id] = head }
    }

    /// Rereads HEAD of every repository in the list: a branch may have been switched in a terminal.
    func refreshHeads() async {
        await withTaskGroup(of: (RepositoryEntry.ID, Head?).self) { group in
            for entry in entries {
                group.addTask { (entry.id, try? await GitRepository(entry.url).head()) }
            }
            for await (id, head) in group { setHead(head, for: id) }
        }
    }

    var favorites: [RepositoryEntry] { entries.filter(\.isFavorite) }

    /// Repositories of a group without the favorites: those are shown in their own section.
    func entries(in group: String?) -> [RepositoryEntry] {
        entries.filter { !$0.isFavorite && $0.group == group }
    }

    /// Order as in the sidebar: for ⌘1…⌘9 and moving to the adjacent repository.
    var orderedEntries: [RepositoryEntry] {
        favorites + groups.flatMap { entries(in: $0) } + entries(in: nil)
    }

    /// Selects the repository `offset` positions above or below the current one, wrapping around.
    func selectAdjacent(_ offset: Int) {
        let list = orderedEntries
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : 0)
        selectedID = list[((i + offset) % list.count + list.count) % list.count].id
    }

    /// Adds a folder. If it is a subfolder of a repository, uses the repository root.
    func add(_ url: URL, group: String? = nil) async {
        guard let repo = await GitRepository.discover(at: url) else {
            lastError = "\(url.path) is not a git repository"
            return
        }
        let path = repo.workingDirectory.path
        if let existing = entries.first(where: { $0.path == path }) {
            selectedID = existing.id
            return
        }
        let entry = RepositoryEntry(id: UUID(), path: path, name: repo.workingDirectory.lastPathComponent, group: group)
        entries.append(entry)
        sortEntries()
        selectedID = entry.id
        save()
        setHead(try? await repo.head(), for: entry.id)
    }

    func remove(_ id: RepositoryEntry.ID) {
        entries.removeAll { $0.id == id }
        models[id] = nil
        heads[id] = nil
        if selectedID == id { selectedID = orderedEntries.first?.id }
        save()
    }

    // MARK: Groups and favorites

    func setFavorite(_ id: RepositoryEntry.ID, _ value: Bool) {
        update(id) { $0.isFavorite = value }
    }

    func move(_ id: RepositoryEntry.ID, to group: String?) {
        update(id) { $0.group = group }
    }

    /// Creates a group; if the name is taken, returns the existing one. `nil` for an empty name.
    @discardableResult
    func addGroup(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if !groups.contains(name) {
            groups.append(name)
            save()
        }
        return name
    }

    func renameGroup(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old, let i = groups.firstIndex(of: old) else { return }
        if groups.contains(new) {
            // Merge into the existing group.
            groups.remove(at: i)
        } else {
            groups[i] = new
        }
        for k in entries.indices where entries[k].group == old { entries[k].group = new }
        if collapsed.remove(old) != nil { collapsed.insert(new) }
        save()
    }

    /// Deletes a group; its repositories stay in the list as ungrouped.
    func removeGroup(_ name: String) {
        groups.removeAll { $0 == name }
        for k in entries.indices where entries[k].group == name { entries[k].group = nil }
        collapsed.remove(name)
        save()
    }

    func moveGroup(_ name: String, by offset: Int) {
        guard let i = groups.firstIndex(of: name) else { return }
        let j = i + offset
        guard groups.indices.contains(j) else { return }
        groups.swapAt(i, j)
        save()
    }

    func isExpanded(_ section: String) -> Bool { !collapsed.contains(section) }

    func setExpanded(_ section: String, _ value: Bool) {
        if value { collapsed.remove(section) } else { collapsed.insert(section) }
        save()
    }

    private func update(_ id: RepositoryEntry.ID, _ change: (inout RepositoryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    private func sortEntries() {
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    /// File contents. It used to be just an array of repositories.
    private struct Library: Codable {
        var repositories: [RepositoryEntry]
        var groups: [String]
        var collapsed: [String]
        /// The repository that was open at quit.
        var selected: UUID?
    }

    private func load() {
        // Debug launch with `--repo=<path>`: show only that repository and leave the list untouched.
        if let path = DebugScreenshot.repoPath {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            let entry = RepositoryEntry(id: UUID(), path: url.path, name: url.lastPathComponent)
            // Before selection: selecting saves the list.
            isTransient = true
            entries = [entry]
            selectedID = entry.id
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let library = try? decoder.decode(Library.self, from: data) {
            entries = library.repositories
            groups = library.groups
            collapsed = Set(library.collapsed)
            selectedID = library.selected
        } else if let list = try? decoder.decode([RepositoryEntry].self, from: data) {
            entries = list
        } else {
            return
        }
        // A group that isn't in the list (the file was edited by hand) is still shown.
        for g in entries.compactMap(\.group) where !groups.contains(g) { groups.append(g) }
        if selected == nil { selectedID = orderedEntries.first?.id }
    }

    /// The list is overridden by a debug flag; nothing is written to disk.
    private var isTransient = false

    private func save() {
        guard !isTransient else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let library = Library(repositories: entries, groups: groups, collapsed: collapsed.sorted(), selected: selectedID)
        guard let data = try? enc.encode(library) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
