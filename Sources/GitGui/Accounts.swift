import Foundation
import Hosting
import Observation

/// An account on a hosting provider: GitHub or a specific GitLab server.
enum HostingAccount: Hashable, Identifiable {
    case github
    case gitlab(host: String)

    var id: String { host }

    /// The host; also the entry name in the keychain.
    var host: String {
        switch self {
        case .github: "github.com"
        case .gitlab(let host): host
        }
    }

    /// A tool the token can be obtained from.
    var cliName: String {
        switch self {
        case .github: "gh"
        case .gitlab: "glab"
        }
    }
}

/// Hosting provider accounts, shared by all repositories.
///
/// The token is looked up in order: the user's own in the keychain (from Settings), then from the CLI
/// (`gh auth token`, `glab config get token`). The CLI token isn't copied into the keychain:
/// with every rebuild of the app with an ad-hoc signature, macOS would ask again for
/// write access, and the CLI stores it itself anyway.
@MainActor
@Observable
final class Accounts {
    static let shared = Accounts()

    enum Source {
        case keychain
        case cli
    }

    /// What is known about an account: where the token comes from and whose it is.
    struct Status {
        var source: Source?
        var login: String?
        var error: String?
    }

    private(set) var statuses: [HostingAccount: Status] = [:]
    /// The user's own GitLab servers: their name may not contain the word "gitlab".
    private(set) var gitlabHosts: [String]
    /// Increments when tokens or the server list change: repositories recreate their provider.
    private(set) var generation = 0

    @ObservationIgnored private var tokens: [HostingAccount: String] = [:]
    @ObservationIgnored private var resolving: [HostingAccount: Task<Void, Never>] = [:]

    private static let hostsKey = "gitlabHosts"

    private init() {
        gitlabHosts = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
    }

    /// Entries for the Settings window: GitHub, the user's own GitLab servers, and those found in repositories.
    var knownAccounts: [HostingAccount] {
        let seen = statuses.keys.compactMap { if case .gitlab(let h) = $0 { h } else { nil } }
        let hosts = Set(gitlabHosts + seen).sorted()
        return [.github] + hosts.map { .gitlab(host: $0) }
    }

    func status(_ account: HostingAccount) -> Status {
        statuses[account] ?? Status()
    }

    /// The token; looked up on first access.
    func token(for account: HostingAccount) async -> String? {
        if resolving[account] == nil { resolving[account] = Task { await resolve(account) } }
        await resolving[account]?.value
        return tokens[account]
    }

    /// Looks up the token again: after a change in Settings or a CLI sign-in.
    func reload(_ account: HostingAccount) async {
        resolving[account] = Task { await resolve(account) }
        await resolving[account]?.value
        generation += 1
    }

    /// Validates and saves the user's own token. Returns an error message or `nil`.
    func saveToken(_ token: String, for account: HostingAccount) async -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await Self.login(account, token: token)
            try Keychain.setToken(token, for: account.host)
        } catch {
            return String(describing: error)
        }
        await reload(account)
        return nil
    }

    func removeToken(for account: HostingAccount) async {
        try? Keychain.deleteToken(for: account.host)
        await reload(account)
    }

    /// Adds the user's own GitLab server. Also accepts an address like `https://host/`.
    func addGitLabHost(_ input: String) {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let h = url.host() { host = h }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !gitlabHosts.contains(host) else { return }
        gitlabHosts.append(host)
        UserDefaults.standard.set(gitlabHosts, forKey: Self.hostsKey)
        generation += 1
    }

    func removeGitLabHost(_ host: String) {
        gitlabHosts.removeAll { $0 == host }
        UserDefaults.standard.set(gitlabHosts, forKey: Self.hostsKey)
        statuses[.gitlab(host: host)] = nil
        generation += 1
    }

    // MARK: Internals

    private func resolve(_ account: HostingAccount) async {
        var status = Status()
        if let t = Keychain.token(for: account.host) {
            tokens[account] = t
            status.source = .keychain
        } else if let t = await cliToken(account) {
            tokens[account] = t
            status.source = .cli
        } else {
            tokens[account] = nil
        }
        statuses[account] = status
        guard let token = tokens[account] else { return }

        // The login is only needed for Settings; no need to wait for it.
        Task {
            let result: Result<String, Error>
            do { result = .success(try await Self.login(account, token: token)) } catch { result = .failure(error) }
            // The token may have changed while validating.
            guard tokens[account] == token else { return }
            switch result {
            case .success(let login): statuses[account]?.login = login
            case .failure(let error): statuses[account]?.error = String(describing: error)
            }
        }
    }

    private func cliToken(_ account: HostingAccount) async -> String? {
        switch account {
        case .github: await GitHubCLI.token()
        case .gitlab(let host): await GitLabCLI.token(host: host)
        }
    }

    private static func login(_ account: HostingAccount, token: String) async throws -> String {
        switch account {
        case .github: try await GitHubProvider.viewerLogin(token: token)
        case .gitlab(let host): try await GitLabProvider.viewerLogin(host: host, token: token)
        }
    }
}
