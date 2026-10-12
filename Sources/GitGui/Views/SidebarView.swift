import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: favorites, groups, and the remaining repositories.
/// Add with ⌘O or by dragging in a folder; dropping onto a group adds it straight into that group.
struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store

    /// Group name input: for a new group (`renaming == nil`) or a rename.
    @State private var groupPrompt: GroupPrompt?
    @State private var groupName = ""

    struct GroupPrompt: Identifiable {
        var id: String { renaming ?? "new:\(moving?.uuidString ?? "")" }
        /// The group being renamed.
        var renaming: String?
        /// The repository being moved to a new group.
        var moving: UUID?
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedID) {
            if !store.favorites.isEmpty {
                Section(isExpanded: expanded(RepositoryStore.favoritesKey)) {
                    rows(store.favorites)
                } header: {
                    Text("Favorites")
                }
            }
            ForEach(store.groups, id: \.self) { group in
                Section(isExpanded: expanded(group)) {
                    let list = store.entries(in: group)
                    rows(list)
                    if list.isEmpty {
                        Text("Empty").foregroundStyle(.tertiary).selectionDisabled()
                    }
                } header: {
                    Text(group)
                        .contextMenu { groupMenu(group) }
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { for u in urls { await store.add(u, group: group) } }
                            return true
                        }
                }
            }
            let ungrouped = store.entries(in: nil)
            if !ungrouped.isEmpty || store.groups.isEmpty {
                Section {
                    rows(ungrouped)
                } header: {
                    Text(store.groups.isEmpty ? "Repositories" : "Ungrouped")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Add Repository…") { store.presentOpenPanel() }
                    Button("New Group…") { prompt(GroupPrompt()) }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    store.presentOpenPanel()
                }
                .help("Add Repository (⌘O); the menu has New Group")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for u in urls { await store.add(u) } }
            return true
        }
        .overlay {
            if store.entries.isEmpty, store.groups.isEmpty {
                ContentUnavailableView {
                    Label("Empty", systemImage: "tray")
                } description: {
                    Text("Drag a repository folder here")
                }
            }
        }
        .alert(groupPrompt?.renaming == nil ? "New Group" : "Rename Group",
               isPresented: Binding(get: { groupPrompt != nil }, set: { if !$0 { groupPrompt = nil } }),
               presenting: groupPrompt) { p in
            TextField("Group name", text: $groupName)
            Button("Cancel", role: .cancel) {}
            Button(p.renaming == nil ? "Create" : "Rename") { commit(p) }
        }
    }

    private func rows(_ entries: [RepositoryEntry]) -> some View {
        ForEach(entries) { entry in
            Label(entry.name, systemImage: "shippingbox")
                .help(entry.path)
                .tag(entry.id)
                .contextMenu { entryMenu(entry) }
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: RepositoryEntry) -> some View {
        Button(entry.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            store.setFavorite(entry.id, !entry.isFavorite)
        }
        Menu("Group") {
            ForEach(store.groups, id: \.self) { group in
                Toggle(group, isOn: Binding(get: { entry.group == group }, set: { _ in store.move(entry.id, to: group) }))
            }
            if !store.groups.isEmpty { Divider() }
            Toggle("Ungrouped", isOn: Binding(get: { entry.group == nil }, set: { _ in store.move(entry.id, to: nil) }))
            Divider()
            Button("New Group…") { prompt(GroupPrompt(moving: entry.id)) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
        Divider()
        Button("Remove from List", role: .destructive) {
            store.remove(entry.id)
        }
    }

    @ViewBuilder
    private func groupMenu(_ group: String) -> some View {
        Button("Rename…") { prompt(GroupPrompt(renaming: group)) }
        Button("Move Up") { store.moveGroup(group, by: -1) }
            .disabled(store.groups.first == group)
        Button("Move Down") { store.moveGroup(group, by: 1) }
            .disabled(store.groups.last == group)
        Divider()
        Button("Delete Group", role: .destructive) { store.removeGroup(group) }
            .help("The repositories stay in the list, ungrouped")
    }

    private func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { store.isExpanded(key) }, set: { store.setExpanded(key, $0) })
    }

    private func prompt(_ p: GroupPrompt) {
        groupName = p.renaming ?? ""
        groupPrompt = p
    }

    private func commit(_ p: GroupPrompt) {
        if let old = p.renaming {
            store.renameGroup(old, to: groupName)
        } else if let group = store.addGroup(groupName), let id = p.moving {
            store.move(id, to: group)
        }
    }
}
