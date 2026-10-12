import Foundation
import Hosting
import Observation

/// Hosting provider accounts, shared by all repositories.
///
/// The GitHub token is looked up in order: the user's own in the keychain (from Settings), then `gh auth token`.
/// The `gh` token isn't copied into the keychain: with every rebuild of the app with an
/// ad-hoc signature, macOS would ask again for write access.
@MainActor
@Observable
final class Accounts {
    static let shared = Accounts()

    enum Source {
        case keychain
        case githubCLI
    }

    private(set) var githubSource: Source?
    /// Login of the token's owner, once validation has passed.
    private(set) var githubLogin: String?
    private(set) var githubError: String?
    /// Increments when the token changes: repositories recreate their provider.
    private(set) var generation = 0

    @ObservationIgnored private var githubToken: String?
    @ObservationIgnored private var resolving: Task<Void, Never>?

    private init() {}

    /// The GitHub token; looked up on first access.
    func gitHubToken() async -> String? {
        if resolving == nil { resolving = Task { await resolveGitHub() } }
        await resolving?.value
        return githubToken
    }

    /// Looks up the token again: after a change in Settings or `gh auth login`.
    func reloadGitHub() async {
        resolving = Task { await resolveGitHub() }
        await resolving?.value
        generation += 1
    }

    /// Validates and saves the user's own token. Returns an error message or `nil`.
    func saveGitHubToken(_ token: String) async -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await GitHubProvider.viewerLogin(token: token)
            try Keychain.setToken(token, for: Self.githubHost)
        } catch {
            return String(describing: error)
        }
        await reloadGitHub()
        return nil
    }

    func removeGitHubToken() async {
        try? Keychain.deleteToken(for: Self.githubHost)
        await reloadGitHub()
    }

    private static let githubHost = "github.com"

    private func resolveGitHub() async {
        githubLogin = nil
        githubError = nil
        if let t = Keychain.token(for: Self.githubHost) {
            githubToken = t
            githubSource = .keychain
        } else if let t = await GitHubCLI.token() {
            githubToken = t
            githubSource = .githubCLI
        } else {
            githubToken = nil
            githubSource = nil
            return
        }
        // The login is only needed for Settings; no need to wait for it.
        let token = githubToken!
        Task {
            let result: Result<String, Error>
            do { result = .success(try await GitHubProvider.viewerLogin(token: token)) } catch { result = .failure(error) }
            // The token may have changed while validating.
            guard githubToken == token else { return }
            switch result {
            case .success(let login): githubLogin = login
            case .failure(let error): githubError = String(describing: error)
            }
        }
    }
}
