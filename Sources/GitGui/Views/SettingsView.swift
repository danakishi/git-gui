import GitCore
import Hosting
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (⌘,): external programs, font, hosting provider accounts.
struct SettingsView: View {
    @State private var tab = DebugScreenshot.settingsTab ?? 0

    var body: some View {
        TabView(selection: $tab) {
            ToolsSettings()
                .tabItem { Label("Programs", systemImage: "hammer") }
                .tag(0)

            FontSettings()
                .tabItem { Label("Font", systemImage: "textformat") }
                .tag(1)

            Form {
                AccountSection(account: .github)
            }
            .formStyle(.grouped)
            .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }
            .tag(2)

            GitLabSettings()
                .tabItem { Label("GitLab", systemImage: "server.rack") }
                .tag(3)
        }
        .frame(width: 560, height: 480)
    }
}

/// GitLab servers: those found in repositories and those added manually.
private struct GitLabSettings: View {
    private var accounts: Accounts { .shared }
    @State private var newHost = ""

    var body: some View {
        Form {
            ForEach(gitlabAccounts) { account in
                AccountSection(account: account)
            }
            Section {
                HStack {
                    TextField("Server", text: $newHost, prompt: Text("git.example.com"))
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Another GitLab Server")
            } footer: {
                Text("Servers with \"gitlab\" in their name are recognized automatically. Add the others here so their remotes are treated as GitLab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var gitlabAccounts: [HostingAccount] {
        accounts.knownAccounts.filter { $0 != .github }
    }

    private func add() {
        accounts.addGitLabHost(newHost)
        newHost = ""
    }
}

/// A single account: where the token comes from, whose it is, and a field for a custom token.
private struct AccountSection: View {
    let account: HostingAccount
    private var accounts: Accounts { .shared }
    @State private var token = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        let status = accounts.status(account)
        Section {
            LabeledContent("Token") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sourceTitle(status.source))
                    if let login = status.login {
                        Text("Signed in as \(login)").foregroundStyle(.secondary)
                    } else if let e = status.error {
                        Text(e).foregroundStyle(.red)
                    }
                }
            }
            SecureField("Custom Token", text: $token, prompt: Text(placeholder))
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                if status.source == .keychain {
                    Button("Delete Custom Token", role: .destructive) {
                        Task { await accounts.removeToken(for: account) }
                    }
                }
                if case .gitlab(let host) = account, accounts.gitlabHosts.contains(host) {
                    Button("Remove Server", role: .destructive) { accounts.removeGitLabHost(host) }
                }
                Spacer()
                Button("Check Again") {
                    Task { await accounts.reload(account) }
                }
                Button("Save", action: save)
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        } header: {
            Text(account.host)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: account) { _ = await accounts.token(for: account) }
    }

    private var placeholder: String {
        switch account {
        case .github: "ghp_… or github_pat_…"
        case .gitlab: "glpat-…"
        }
    }

    private var footer: String {
        let scopes = switch account {
        case .github: "Needs read access to repositories: scope `repo`, or fine-grained Contents, Pull requests, Commit statuses, Checks — read."
        case .gitlab: "Needs the `read_api` scope."
        }
        return "Without a custom token, the app uses the token from `\(account.cliName)`. A custom token is stored in the Keychain and takes precedence over the CLI token. " + scopes
    }

    private func sourceTitle(_ source: Accounts.Source?) -> String {
        switch source {
        case .keychain: "Custom, from Keychain"
        case .cli: "From \(account.cliName)"
        case nil: "Not found"
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            error = await accounts.saveToken(token, for: account)
            if error == nil { token = "" }
            isSaving = false
        }
    }
}

/// Editor, terminal, and the `git difftool`/`git mergetool` tools.
private struct ToolsSettings: View {
    @AppStorage(Preferences.editorKey) private var editor = ""
    @AppStorage(Preferences.terminalKey) private var terminal = ""
    @AppStorage(Preferences.diffToolKey) private var diffTool = ""
    @AppStorage(Preferences.mergeToolKey) private var mergeTool = ""
    @State private var tools: [String] = []
    @State private var gitDiffTool: String?
    @State private var gitMergeTool: String?

    var body: some View {
        Form {
            Section {
                AppPicker(title: "Editor", path: $editor, fallback: "Default app for the file")
                AppPicker(title: "Terminal", path: $terminal, fallback: "Terminal")
            } footer: {
                Text("The editor opens files and the whole repository (⌥⌘E); the terminal opens the repository directory (⌥⌘T).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                toolPicker("Diff", selection: $diffTool, configured: gitDiffTool)
                toolPicker("Merge", selection: $mergeTool, configured: gitMergeTool)
            } header: {
                Text("External Tools")
            } footer: {
                Text("Launched through `git difftool` and `git mergetool`: tools built into git (opendiff, kaleidoscope, bc, vscode…) and your own from `difftool.<name>.cmd` work. If a tool exits successfully, git marks the conflict as resolved by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let git = GitRepository(FileManager.default.homeDirectoryForCurrentUser)
            tools = await git.externalTools()
            gitDiffTool = await git.config("diff.tool")
            gitMergeTool = await git.config("merge.tool")
        }
    }

    private func toolPicker(_ title: String, selection: Binding<String>, configured: String?) -> some View {
        Picker(title, selection: selection) {
            Text("As in git config" + (configured.map { " (\($0))" } ?? "")).tag("")
            Divider()
            // A previously chosen tool may have disappeared from the list, but it still needs to be shown.
            ForEach(Set(tools + [selection.wrappedValue]).filter { !$0.isEmpty }.sorted(), id: \.self) { tool in
                Text(tool).tag(tool)
            }
        }
    }
}

/// App picker: icon, name, "Choose…", and reset to default.
private struct AppPicker: View {
    let title: String
    @Binding var path: String
    let fallback: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if !path.isEmpty {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(Preferences.appName(path))
                } else {
                    Text(fallback).foregroundStyle(.secondary)
                }
                Button("Choose…", action: choose)
                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Default: \(fallback)")
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// Font for the diff and the conflict editor.
private struct FontSettings: View {
    @AppStorage(Preferences.fontNameKey) private var name = ""
    @AppStorage(Preferences.fontSizeKey) private var size = Preferences.defaultFontSize

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $name) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(size)) pt", value: $size, in: 9...24, step: 1)
            } footer: {
                Text("For the diff, the conflict editor, and the commit message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                Text("func merge(_ rev: String) -> Bool {\n    return rev != \"main\" // 0O 1lI\n}")
                    .codeFont()
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    /// The family from Settings may have been removed from the system: keep it in the list.
    private var families: [String] {
        let all = Preferences.monospacedFamilies
        return name.isEmpty || all.contains(name) ? all : [name] + all
    }
}
