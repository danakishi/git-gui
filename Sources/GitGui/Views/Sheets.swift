import GitCore
import SwiftUI

/// Input sheets: new branch, rename, tag, stash.
enum RepositorySheet: Identifiable {
    case newBranch(from: String?)
    case renameBranch(Ref)
    case newTag(at: String?)
    case stash

    var id: String {
        switch self {
        case .newBranch(let s): "branch:\(s ?? "")"
        case .renameBranch(let r): "rename:\(r.id)"
        case .newTag(let s): "tag:\(s ?? "")"
        case .stash: "stash"
        }
    }
}

struct RepositorySheetView: View {
    let sheet: RepositorySheet
    let model: RepositoryModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""
    @State private var flag = true
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            switch sheet {
            case .newBranch:
                TextField("Branch name", text: $name).focused($nameFocused)
                Toggle("Check out the new branch", isOn: $flag)
            case .renameBranch:
                TextField("New name", text: $name).focused($nameFocused)
            case .newTag:
                TextField("Tag name", text: $name).focused($nameFocused)
                TextField("Message (optional, makes the tag annotated)", text: $message, axis: .vertical)
                    .lineLimit(2...4)
            case .stash:
                TextField("Message (optional)", text: $name).focused($nameFocused)
                Toggle("Include untracked files", isOn: $flag)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .renameBranch(let ref) = sheet { name = ref.shortName }
            nameFocused = true
        }
    }

    private var title: String {
        switch sheet {
        case .newBranch: "New Branch"
        case .renameBranch(let r): "Rename “\(r.shortName)”"
        case .newTag: "New Tag"
        case .stash: "Stash Changes"
        }
    }

    private var subtitle: String? {
        switch sheet {
        case .newBranch(let from?): "From commit \(from.prefix(8))"
        case .newBranch(nil): "From current HEAD"
        case .newTag(let at?): "On commit \(at.prefix(8))"
        case .newTag(nil): "On current HEAD"
        case .renameBranch, .stash: nil
        }
    }

    private var confirmTitle: String {
        switch sheet {
        case .newBranch: "Create"
        case .renameBranch: "Rename"
        case .newTag: "Create"
        case .stash: "Stash"
        }
    }

    private var isValid: Bool {
        if case .stash = sheet { return true }
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !n.contains(" ") && !n.hasPrefix("-")
    }

    private func confirm() {
        let n = name.trimmingCharacters(in: .whitespaces)
        dismiss()
        Task {
            switch sheet {
            case .newBranch(let from): await model.createBranch(n, at: from, checkout: flag)
            case .renameBranch(let ref): await model.renameBranch(ref.shortName, to: n)
            case .newTag(let at): await model.createTag(n, at: at, message: message)
            case .stash: await model.stashPush(message: n, includeUntracked: flag)
            }
        }
    }
}
