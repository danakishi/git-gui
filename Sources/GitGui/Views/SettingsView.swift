import Hosting
import SwiftUI

/// Settings window (⌘,): hosting provider accounts.
struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                AccountSection(account: .github)
            }
            .formStyle(.grouped)
            .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }

            GitLabSettings()
                .tabItem { Label("GitLab", systemImage: "server.rack") }
        }
        .frame(width: 540, height: 460)
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
