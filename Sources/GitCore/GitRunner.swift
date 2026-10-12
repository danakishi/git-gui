import Foundation

/// Error from running a git command.
public struct GitError: Error, Sendable, CustomStringConvertible {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public init(arguments: [String], exitCode: Int32, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var description: String {
        let cmd = (["git"] + arguments).joined(separator: " ")
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(cmd)` exited with code \(exitCode)" + (msg.isEmpty ? "" : ": \(msg)")
    }
}

/// Result of running a command: the complete stdout and stderr.
public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: String
    public let exitCode: Int32

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Record of a single git run, for the in-app operation log.
public struct GitInvocation: Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let arguments: [String]
    public let directory: URL?
    public let exitCode: Int32
    public let stderr: String
    public let duration: TimeInterval

    /// Command line without internal flags (`--no-pager`, `color.ui`).
    public var commandLine: String {
        (["git"] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
    }

    /// Commands that change something in the repository. The others (log, status,
    /// diff) run constantly on every refresh and do not belong in the log.
    public var isMutating: Bool {
        guard let first = arguments.first, Self.mutatingCommands.contains(first) else { return false }
        let rest = arguments.dropFirst()
        switch first {
        case "stash":
            // `stash list` and `stash show` only read.
            return !(rest.first == "list" || rest.first == "show")
        case "remote":
            // `remote`, `remote -v`, `remote get-url`, and `remote show` read;
            // `remote add/remove/...` modify.
            guard let sub = rest.first(where: { !$0.hasPrefix("-") }) else { return false }
            return sub != "get-url" && sub != "show"
        case "submodule", "worktree":
            // `submodule status` and `worktree list` only read.
            return !(rest.first == "status" || rest.first == "list")
        case "branch", "tag":
            // Without positional arguments this is a listing (`branch -a`, `tag -l`).
            return rest.contains { !$0.hasPrefix("-") }
        default:
            return true
        }
    }

    static let mutatingCommands: Set<String> = [
        "add", "rm", "restore", "reset", "apply", "commit", "checkout", "switch", "branch", "tag",
        "fetch", "pull", "push", "merge", "mergetool", "rebase", "cherry-pick", "revert", "stash", "clean", "remote",
        "submodule", "worktree",
    ]
}

/// Runs the system `git` and collects its output.
///
/// We use the regular binary rather than libgit2: behavior matches the
/// terminal exactly, and the user's settings (ssh, credential helper, hooks)
/// just work.
public enum GitRunner {
    /// Path to git. By default it is looked up via PATH, but Xcode's copy is used too.
    public nonisolated(unsafe) static var executable: String = "/usr/bin/git"

    /// Called after every run. The app subscribes to keep the log.
    public nonisolated(unsafe) static var observer: (@Sendable (GitInvocation) -> Void)?

    /// Runs git with the given arguments in the specified directory.
    /// - Parameter stdin: data for standard input (a patch for `apply`, a message for `commit -F -`).
    /// - Parameter check: throw ``GitError`` on a nonzero exit code.
    @discardableResult
    public static func run(
        _ arguments: [String],
        in directory: URL?,
        stdin: Data? = nil,
        environment extra: [String: String] = [:],
        check: Bool = true
    ) async throws -> GitOutput {
        let started = Date()
        let output = try await execute(arguments, in: directory, stdin: stdin, extra: extra)
        observer?(GitInvocation(
            id: UUID(), date: started, arguments: arguments, directory: directory,
            exitCode: output.exitCode, stderr: output.stderr, duration: Date().timeIntervalSince(started)
        ))
        if check, output.exitCode != 0 {
            throw GitError(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr)
        }
        return output
    }

    private static func execute(
        _ arguments: [String],
        in directory: URL?,
        stdin: Data?,
        extra: [String: String]
    ) async throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Disable the pager, color, and interactive prompts: we are not a terminal.
        process.arguments = ["--no-pager", "-c", "color.ui=never"] + arguments
        process.currentDirectoryURL = directory

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C.UTF-8"
        // The editor must not open: all messages are passed explicitly.
        env["GIT_EDITOR"] = "true"
        for (k, v) in extra { env[k] = v }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input: Pipe?
        if stdin != nil {
            input = Pipe()
            process.standardInput = input
        } else {
            input = nil
            process.standardInput = FileHandle.nullDevice
        }

        try process.run()

        if let input, let stdin {
            // Write in a separate task: a large patch may not fit in the buffer
            // until git starts reading.
            let handle = input.fileHandleForWriting
            Task.detached(priority: .userInitiated) {
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        // Read both channels in parallel, otherwise with large output the process
        // would block on a full buffer and hang.
        async let stdoutData = Self.readAll(out.fileHandleForReading)
        async let stderrData = Self.readAll(err.fileHandleForReading)
        let (o, e) = await (stdoutData, stderrData)

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if process.isRunning {
                process.terminationHandler = { _ in c.resume() }
            } else {
                c.resume()
            }
        }

        return GitOutput(
            stdout: o,
            stderr: String(decoding: e, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached(priority: .userInitiated) {
            handle.readDataToEndOfFile()
        }.value
    }
}
