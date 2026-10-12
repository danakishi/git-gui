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
    /// Where to look for `gh`: an app launched from Finder gets a trimmed-down PATH.
    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    public static var executable: String? {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map { "\($0)/gh" } ?? []
        return (candidates + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func token(host: String = "github.com") async -> String? {
        guard let gh = executable else { return nil }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token", "--hostname", host]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }.value
    }
}
