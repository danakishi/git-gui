import GitCore
import SwiftUI

/// ⌘K palette: repositories, branches, and commands with fuzzy search.
/// ↑↓ select, ↩ run, ⎋ or a click outside closes.
struct CommandPalette: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    /// The open repository; `nil` means only app-level commands.
    let model: RepositoryModel?

    @State private var query = DebugScreenshot.paletteQuery ?? ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        /// Trailing label: what will happen, or the keys.
        let detail: String
        let icon: String
        var keywords = ""
        let action: @MainActor () -> Void
        var positions: [Int] = []
        var score = 0
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Repository, branch, or command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                    .onExitCommand { close() }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("Nothing found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, isSelected: i == selected)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = i; run(items) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selected) {
                        if items.indices.contains(selected) { proxy.scrollTo(items[selected].id) }
                    }
                }
            }
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            highlighted(item)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(item.detail)
                .font(.callout)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Matched letters in bold.
    private func highlighted(_ item: Item) -> Text {
        guard !item.positions.isEmpty else { return Text(item.title) }
        var text = AttributedString()
        let marked = Set(item.positions)
        for (i, ch) in item.title.enumerated() {
            var part = AttributedString(String(ch))
            if marked.contains(i) { part.inlinePresentationIntent = .stronglyEmphasized }
            text += part
        }
        return Text(text)
    }

    // MARK: List

    private var results: [Item] {
        let all = allItems
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        var found: [Item] = []
        for var item in all {
            if let m = FuzzyMatch.match(q, in: item.title) {
                item.positions = m.positions
                item.score = m.score
            } else if !item.keywords.isEmpty, let m = FuzzyMatch.match(q, in: item.keywords) {
                // Matches by keywords rank lower than by title, and are not highlighted.
                item.score = m.score - 10
            } else {
                continue
            }
            found.append(item)
        }
        // The sort is stable: with equal scores the order is the same as without a query.
        return found.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
            .prefix(50)
            .map { $0 }
    }

    private var allItems: [Item] {
        var items: [Item] = []
        for entry in store.orderedEntries where entry.id != store.selectedID {
            items.append(Item(id: "repo:\(entry.id)", title: entry.name,
                              detail: entry.group ?? (entry.isFavorite ? "Favorites" : "Repository"),
                              icon: entry.isFavorite ? "star" : "shippingbox", keywords: entry.group ?? "") {
                store.selectedID = entry.id
            })
        }
        if let model {
            for ref in model.localBranches where !ref.isHead {
                items.append(Item(id: ref.id, title: ref.shortName, detail: "Check Out",
                                  icon: "arrow.triangle.branch") { Task { await model.checkout(ref) } })
            }
            for ref in model.remoteBranches {
                let local = ref.shortName.split(separator: "/", maxSplits: 1).last.map(String.init)
                // A remote branch with a local copy is already in the list above.
                if model.localBranches.contains(where: { $0.shortName == local }) { continue }
                items.append(Item(id: ref.id, title: ref.shortName, detail: "Check Out Remote Branch",
                                  icon: "cloud") { Task { await model.checkout(ref) } })
            }
            for ref in model.tags {
                items.append(Item(id: ref.id, title: ref.shortName, detail: "Show in Graph",
                                  icon: "tag") { model.selectedCommitID = ref.target })
            }
        }
        let current = model
        for command in AppCommand.allCases where command != .palette && command.isEnabled(store: store, model: current) {
            items.append(Item(id: "cmd:\(command.rawValue)", title: command.title,
                              detail: command.shortcut?.symbols ?? "", icon: command.icon, keywords: command.keywords) {
                command.perform(store: store, model: current)
            })
        }
        items.append(Item(id: "cmd:settings", title: "Settings…", detail: "⌘,", icon: "gearshape",
                          keywords: "settings preferences") { openSettings() })
        return items
    }

    // MARK: Actions

    private func move(_ delta: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        let action = items[selected].action
        close()
        // After closing: toolbar popovers should appear without the palette on top of them.
        DispatchQueue.main.async { action() }
    }

    private func close() {
        store.showPalette = false
    }
}
