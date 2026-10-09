import SwiftUI
import UniformTypeIdentifiers

/// Sidebar: the list of repositories; add one with ⌘O or by dragging in a folder.
struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedID) {
            Section("Repositories") {
                ForEach(store.entries) { entry in
                    Label(entry.name, systemImage: "shippingbox")
                        .help(entry.path)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            }
                            Divider()
                            Button("Remove from List", role: .destructive) {
                                store.remove(entry.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .toolbar {
            ToolbarItem {
                Button { store.presentOpenPanel() } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .help("Add Repository (⌘O)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { for u in urls { await store.add(u) } }
            return true
        }
        .overlay {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("Empty", systemImage: "tray")
                } description: {
                    Text("Drag a repository folder here")
                }
            }
        }
    }
}
