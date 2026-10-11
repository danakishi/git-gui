import GitCore
import SwiftUI

/// Stash list: a click shows the contents in the inspector; actions are in the menu and buttons.
struct StashPopover: View {
    @Bindable var model: RepositoryModel
    @State private var selection: StashEntry.ID?
    @State private var dropCandidate: StashEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stash").font(.headline)
                Spacer()
                Button {
                    model.sheet = .stash
                } label: {
                    Label("Stash Changes…", systemImage: "tray.and.arrow.down")
                }
                .disabled(model.status?.entries.isEmpty ?? true)
                .help("git stash push")
            }
            .padding(8)
            if model.stashes.isEmpty {
                ContentUnavailableView("Stash Is Empty", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.stashes, selection: $selection) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).lineLimit(2)
                            Text("\(entry.ref) · \(entry.date, format: .dateTime.day().month().hour().minute())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { Task { await model.stashApply(entry, pop: false) } }
                            .help("git stash apply: restores the changes and keeps the entry")
                        Button("Pop") { Task { await model.stashApply(entry, pop: true) } }
                            .help("git stash pop: restores the changes and deletes the entry")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Show in Inspector") { model.show(entry) }
                        Divider()
                        Button("Apply") { Task { await model.stashApply(entry, pop: false) } }
                        Button("Pop") { Task { await model.stashApply(entry, pop: true) } }
                        Divider()
                        Button("Delete…", role: .destructive) { dropCandidate = entry }
                    }
                }
                .onChange(of: selection) {
                    if let e = model.stashes.first(where: { $0.id == selection }) { model.show(e) }
                }
            }
        }
        .frame(width: 380, height: 320)
        .disabled(model.busy != nil)
        .confirmationDialog(
            "Delete \(dropCandidate?.ref ?? "stash")?",
            isPresented: Binding(get: { dropCandidate != nil }, set: { if !$0 { dropCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let e = dropCandidate { Task { await model.stashDrop(e) } }
            }
        } message: {
            Text("The stashed changes will be lost.")
        }
    }
}
