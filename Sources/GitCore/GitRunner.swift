import Foundation

/// Error from running a git command.
public struct GitError: Error, Sendable, CustomStringConvertible {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

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

/// Runs the system `git` and collects its output.
///
/// We use the regular binary rather than libgit2: behavior matches the
/// terminal exactly, and the user's settings (ssh, credential helper, hooks)
/// just work.
public enum GitRunner {
    /// Path to git. By default it is looked up via PATH, but Xcode's copy is used too.
    public nonisolated(unsafe) static var executable: String = "/usr/bin/git"

    /// Runs git with the given arguments in the specified directory.
    /// - Parameter check: throw ``GitError`` on a nonzero exit code.
    @discardableResult
    public static func run(
        _ arguments: [String],
        in directory: URL?,
        environment extra: [String: String] = [:],
        check: Bool = true
    ) async throws -> GitOutput {
        let output = try await execute(arguments, in: directory, extra: extra)
        if check, output.exitCode != 0 {
            throw GitError(arguments: arguments, exitCode: output.exitCode, stderr: output.stderr)
        }
        return output
    }

    private static func execute(
        _ arguments: [String],
        in directory: URL?,
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
        for (k, v) in extra { env[k] = v }
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        try process.run()

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
