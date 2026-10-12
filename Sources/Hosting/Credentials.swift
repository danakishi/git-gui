import Foundation
import Security

/// Hosting provider tokens in the macOS Keychain.
public enum Keychain {
    static let service = "com.danakishi.gitgui"

    /// The token for a host (`github.com`, `gitlab.example.com`), or `nil`.
    public static func token(for host: String) -> String? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setToken(_ token: String, for host: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery(host) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(host)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "GitGui: \(host)"
            try check(SecItemAdd(add as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public static func deleteToken(for host: String) throws {
        let status = SecItemDelete(baseQuery(host) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func baseQuery(_ host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        throw HostingError("Keychain: \(text)")
    }
}

/// The token from `gh` (GitHub CLI), if the user is logged in to it.
///
/// We don't copy it into the Keychain: `gh` stores the token in its own entry
/// and refreshes it, and we pick up the fresh one on every app launch.
public enum GitHubCLI {
    public static var executable: String? {
        CommandLineTool.find("gh")
    }

    public static func token(host: String = "github.com") async -> String? {
        guard let gh = executable else { return nil }
        return await CommandLineTool.output(gh, ["auth", "token", "--hostname", host])
    }
}

/// The token from `glab` (GitLab CLI) for a specific server.
public enum GitLabCLI {
    public static var executable: String? {
        CommandLineTool.find("glab")
    }

    public static func token(host: String) async -> String? {
        guard let glab = executable else { return nil }
        return await CommandLineTool.output(glab, ["config", "get", "token", "--host", host])
    }
}

/// Running CLI utilities (`gh`, `glab`) outside the terminal.
enum CommandLineTool {
    /// An app launched from Finder gets a trimmed-down PATH, so look in Homebrew first.
    static func find(_ name: String) -> String? {
        let fixed = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (fixed + path).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Stdout trimmed of surrounding whitespace; `nil` if the command failed or printed nothing.
    static func output(_ executable: String, _ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.value
    }
}
