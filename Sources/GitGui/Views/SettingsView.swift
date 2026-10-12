import Hosting
import SwiftUI

/// Settings window (⌘,): hosting provider accounts.
struct SettingsView: View {
    var body: some View {
        TabView {
            GitHubSettings()
                .tabItem { Label("GitHub", systemImage: "arrow.triangle.pull") }
        }
        .frame(width: 520)
    }
}

private struct GitHubSettings: View {
    private var accounts: Accounts { .shared }
    @State private var token = ""
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Token") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle)
                        if let login = accounts.githubLogin {
                            Text("Signed in as \(login)").foregroundStyle(.secondary)
                        } else if let e = accounts.githubError {
                            Text(e).foregroundStyle(.red)
                        }
                    }
                }
            }

            Section {
                SecureField("Custom Token", text: $token, prompt: Text("ghp_… or github_pat_…"))
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    if accounts.githubSource == .keychain {
                        Button("Delete Custom Token", role: .destructive) {
                            Task { await accounts.removeGitHubToken() }
                        }
                    }
                    Spacer()
                    Button("Check Again") {
                        Task { await accounts.reloadGitHub() }
                    }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            } footer: {
                Text("Without a custom token, the app uses the token from `gh auth token`. A custom token is stored in the Keychain and takes precedence over the gh token. It needs read access to repositories (scope `repo`, or fine-grained: Contents, Pull requests, Commit statuses, Checks — read).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { _ = await accounts.gitHubToken() }
    }

    private var sourceTitle: String {
        switch accounts.githubSource {
        case .keychain: "Custom, from Keychain"
        case .githubCLI: "From GitHub CLI (gh)"
        case nil: "Not found"
        }
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            error = await accounts.saveGitHubToken(token)
            if error == nil { token = "" }
            isSaving = false
        }
    }
}
