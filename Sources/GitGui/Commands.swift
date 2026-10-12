import AppKit
import SwiftUI

/// App commands: one definition shared by the menus, keyboard shortcuts, and the ⌘K palette.
enum AppCommand: String, CaseIterable, Identifiable {
    // Repository
    case fetch, pull, pullRebase, push
    case newBranch, newTag, branches, stashList, stashPush
    case stageAll, unstageAll, commit
    case resolveConflicts, continueOperation, abortOperation, undo
    case refresh, revealInFinder, openInEditor, openInTerminal
    // View
    case showChanges, toggleInspector, toggleLog, toggleAllBranches, find
    // Go
    case palette, goToHead, previousRepository, nextRepository
    // App
    case openRepository

    var id: String { rawValue }

    /// Where the command appears in the menu bar.
    enum Menu { case repository, view, go, file }

    var menu: Menu {
        switch self {
        case .showChanges, .toggleInspector, .toggleLog, .toggleAllBranches, .find: .view
        case .palette, .goToHead, .previousRepository, .nextRepository: .go
        case .openRepository: .file
        default: .repository
        }
    }

    /// Whether the command is preceded by a separator in the menu.
    var startsGroup: Bool {
        switch self {
        case .newBranch, .stageAll, .resolveConflicts, .refresh, .toggleAllBranches, .find, .previousRepository: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .pullRebase: "Pull --rebase"
        case .push: "Push"
        case .newBranch: "New Branch…"
        case .newTag: "New Tag…"
        case .branches: "Branches & Tags"
        case .stashList: "Stash"
        case .stashPush: "Stash Changes…"
        case .stageAll: "Stage All"
        case .unstageAll: "Unstage All"
        case .commit: "Commit"
        case .resolveConflicts: "Resolve Conflicts…"
        case .continueOperation: "Continue Merge/Rebase"
        case .abortOperation: "Abort Merge/Rebase"
        case .undo: "Undo Last Action"
        case .refresh: "Refresh"
        case .revealInFinder: "Show in Finder"
        case .openInEditor: "Open in Editor"
        case .openInTerminal: "Open in Terminal"
        case .showChanges: "Changes & Commit"
        case .toggleInspector: "Inspector"
        case .toggleLog: "Operation Log"
        case .toggleAllBranches: "History of All Branches"
        case .find: "Find Commit"
        case .palette: "Command Palette…"
        case .goToHead: "Go to HEAD"
        case .previousRepository: "Previous Repository"
        case .nextRepository: "Next Repository"
        case .openRepository: "Open Repository…"
        }
    }

    /// Extra search keywords for the palette.
    var keywords: String {
        switch self {
        case .fetch: "get download"
        case .pull: "get merge"
        case .pullRebase: "get"
        case .push: "send upload"
        case .newBranch: "branch create"
        case .newTag: "tag create"
        case .branches: "branch tag checkout switch"
        case .stashList: "stash shelved"
        case .stashPush: "stash save"
        case .stageAll: "stage add index"
        case .unstageAll: "unstage reset index"
        case .commit: "commit"
        case .resolveConflicts: "conflict merge"
        case .continueOperation: "continue"
        case .abortOperation: "abort"
        case .undo: "undo reflog"
        case .refresh: "reload"
        case .revealInFinder: "finder folder"
        case .openInEditor: "editor code"
        case .openInTerminal: "terminal shell"
        case .showChanges: "working tree status stage"
        case .toggleInspector: "inspector panel"
        case .toggleLog: "log console"
        case .toggleAllBranches: "all branches"
        case .find: "search"
        case .palette: "command"
        case .goToHead: "head"
        case .previousRepository, .nextRepository: "repository"
        case .openRepository: "open add"
        }
    }

    var icon: String {
        switch self {
        case .fetch: "arrow.down.circle"
        case .pull, .pullRebase: "arrow.down.to.line"
        case .push: "arrow.up.to.line"
        case .newBranch: "arrow.triangle.branch"
        case .newTag: "tag"
        case .branches: "list.bullet.indent"
        case .stashList: "tray"
        case .stashPush: "tray.and.arrow.down"
        case .stageAll: "plus.circle"
        case .unstageAll: "minus.circle"
        case .commit: "checkmark.circle"
        case .resolveConflicts: "exclamationmark.triangle"
        case .continueOperation: "play.circle"
        case .abortOperation: "xmark.circle"
        case .undo: "arrow.uturn.backward"
        case .refresh: "arrow.clockwise"
        case .revealInFinder: "folder"
        case .openInEditor: "chevron.left.forwardslash.chevron.right"
        case .openInTerminal: "terminal"
        case .showChanges: "pencil.circle"
        case .toggleInspector: "sidebar.trailing"
        case .toggleLog: "text.alignleft"
        case .toggleAllBranches: "arrow.triangle.merge"
        case .find: "magnifyingglass"
        case .palette: "command"
        case .goToHead: "scope"
        case .previousRepository: "chevron.up"
        case .nextRepository: "chevron.down"
        case .openRepository: "folder.badge.plus"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .fetch: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .pull: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .push: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .newBranch: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .newTag: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .branches: KeyboardShortcut("b")
        case .stashList: KeyboardShortcut("s")
        case .stashPush: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .stageAll: KeyboardShortcut("a", modifiers: [.command, .shift])
        case .unstageAll: KeyboardShortcut("a", modifiers: [.command, .shift, .option])
        case .commit: KeyboardShortcut(.return, modifiers: .command)
        case .continueOperation: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .undo: KeyboardShortcut("z", modifiers: [.command, .option])
        case .refresh: KeyboardShortcut("r")
        case .openInEditor: KeyboardShortcut("e", modifiers: [.command, .option])
        case .openInTerminal: KeyboardShortcut("t", modifiers: [.command, .option])
        case .showChanges: KeyboardShortcut("c", modifiers: [.command, .shift])
        case .toggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        case .toggleLog: KeyboardShortcut("l", modifiers: [.command, .option])
        case .toggleAllBranches: KeyboardShortcut("b", modifiers: [.command, .shift])
        case .find: KeyboardShortcut("f")
        case .palette: KeyboardShortcut("k")
        case .goToHead: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .previousRepository: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .nextRepository: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .openRepository: KeyboardShortcut("o")
        case .pullRebase, .resolveConflicts, .abortOperation, .revealInFinder: nil
        }
    }

    @MainActor
    func isEnabled(store: RepositoryStore, model: RepositoryModel?) -> Bool {
        guard let model else {
            switch self {
            case .palette, .openRepository: return true
            case .previousRepository, .nextRepository: return store.entries.count > 1
            default: return false
            }
        }
        // While an input sheet is open, shortcuts and the palette change nothing beneath it.
        let idle = model.busy == nil && model.sheet == nil
        let hasChanges = !(model.status?.entries.isEmpty ?? true)
        switch self {
        case .fetch: return idle
        case .pull, .pullRebase: return idle && model.hasUpstream
        case .push: return idle && model.currentBranch != nil
        case .newBranch, .newTag: return idle && model.head?.sha != nil
        case .stashPush: return idle && hasChanges
        case .stageAll: return idle && !model.unstagedFiles.isEmpty
        case .unstageAll: return idle && !model.stagedFiles.isEmpty
        case .commit: return idle && model.canCommit
        case .resolveConflicts: return idle && model.conflictCount > 0
        case .continueOperation: return idle && model.operation != nil && model.conflictCount == 0
        case .abortOperation: return idle && model.operation != nil
        case .undo: return model.sheet == nil && model.canUndo
        case .goToHead: return model.head?.sha != nil
        case .openInEditor: return Preferences.editor != nil
        case .previousRepository, .nextRepository: return model.sheet == nil && store.entries.count > 1
        default: return true
        }
    }

    @MainActor
    func perform(store: RepositoryStore, model: RepositoryModel?) {
        switch self {
        case .palette: store.showPalette.toggle(); return
        case .previousRepository: store.selectAdjacent(-1); return
        case .nextRepository: store.selectAdjacent(1); return
        case .openRepository: store.presentOpenPanel(); return
        default: break
        }
        guard let model else { return }
        switch self {
        case .fetch: Task { await model.fetch() }
        case .pull: Task { await model.pull(rebase: false) }
        case .pullRebase: Task { await model.pull(rebase: true) }
        case .push: Task { await model.push() }
        case .newBranch: model.sheet = .newBranch(from: nil)
        case .newTag: model.sheet = .newTag(at: nil)
        case .branches: model.showBranches.toggle()
        case .stashList: model.showStash.toggle()
        case .stashPush: model.sheet = .stash
        case .stageAll: Task { await model.stageAll() }
        case .unstageAll: Task { await model.unstageAll() }
        case .commit: Task { await model.commit() }
        case .resolveConflicts:
            if let first = model.status?.entries.first(where: \.isConflict) { model.sheet = .conflict(path: first.path) }
        case .continueOperation: Task { await model.continueOperation() }
        case .abortOperation: Task { await model.abortOperation() }
        case .undo: Task { await model.undo() }
        case .refresh:
            Task {
                await model.reload()
                await model.refreshHosting()
            }
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([model.repo.workingDirectory])
        case .openInEditor: model.openInEditor()
        case .openInTerminal: model.openInTerminal()
        case .showChanges: model.showWorkingTree()
        case .toggleInspector: model.showInspector.toggle()
        case .toggleLog: model.showLog.toggle()
        case .toggleAllBranches: model.showAllBranches.toggle()
        case .find: model.searchFocusRequest += 1
        case .goToHead: model.selectHead()
        case .palette, .previousRepository, .nextRepository, .openRepository: break
        }
    }
}

extension KeyboardShortcut {
    /// A string like ⇧⌘F, for the palette and tooltips.
    var symbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .return: s += "↩"
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        case .escape: s += "⎋"
        case .delete: s += "⌫"
        case .tab: s += "⇥"
        case .space: s += "Space"
        default: s += String(key.character).uppercased()
        }
        return s
    }
}

extension FocusedValues {
    /// The repository in the active window, for menu commands.
    @Entry var repository: RepositoryModel?
}

/// The Repository and Go menus, plus items in File and View.
struct AppCommands: Commands {
    let store: RepositoryStore
    @FocusedValue(\.repository) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(.file)
        }
        CommandGroup(after: .sidebar) {
            items(.view)
            Divider()
        }
        CommandMenu("Repository") {
            items(.repository)
        }
        CommandMenu("Go") {
            items(.go)
            Divider()
            // ⌘1…⌘9 select repositories in sidebar order.
            ForEach(Array(store.orderedEntries.prefix(9).enumerated()), id: \.element.id) { i, entry in
                Button(entry.name) { store.selectedID = entry.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
        }
    }

    @ViewBuilder
    private func items(_ menu: AppCommand.Menu) -> some View {
        ForEach(AppCommand.allCases.filter { $0.menu == menu }) { command in
            if command.startsGroup { Divider() }
            Button {
                command.perform(store: store, model: model)
            } label: {
                Label(command.title, systemImage: command.icon)
            }
            .keyboardShortcut(command.shortcut)
            .disabled(!command.isEnabled(store: store, model: model))
        }
    }
}
