import Foundation

/// A file with conflict markers, parsed into common chunks and conflicts.
///
/// Understands both the regular style (`<<<<<<<`, `=======`, `>>>>>>>`) and diff3/zdiff3
/// with the base version after `|||||||`.
public struct ConflictFile: Hashable, Sendable {
    public enum Side: Hashable, Sendable {
        /// The HEAD version: for a merge, the current branch; for a rebase, the branch being rebased onto.
        case ours
        /// The incoming version.
        case theirs
    }

    public struct Conflict: Hashable, Sendable {
        public let ours: [String]
        /// Common ancestor; present only in the diff3 style.
        public let base: [String]?
        public let theirs: [String]
        /// Labels after the markers: `HEAD`, `feature`, `1234abc (Subject)`.
        public let oursLabel: String
        public let theirsLabel: String

        public func lines(_ side: Side) -> [String] {
            side == .ours ? ours : theirs
        }
    }

    public enum Chunk: Hashable, Sendable {
        case common([String])
        case conflict(Conflict)
    }

    public let chunks: [Chunk]
    /// The file ended with a newline.
    public let endsWithNewline: Bool

    public var conflicts: [Conflict] {
        chunks.compactMap { if case .conflict(let c) = $0 { c } else { nil } }
    }

    /// `nil` if there are no markers or they are not closed.
    public static func parse(_ text: String) -> ConflictFile? {
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }

        enum State { case common, ours, base, theirs }
        var state = State.common
        var chunks: [Chunk] = []
        var common: [String] = []
        var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = ""

        for line in lines {
            switch state {
            case .common:
                if let label = marker(line, "<") {
                    if !common.isEmpty { chunks.append(.common(common)) }
                    common = []
                    ours = []; base = nil; theirs = []
                    oursLabel = label
                    state = .ours
                } else {
                    common.append(line)
                }
            case .ours:
                if marker(line, "|") != nil {
                    base = []
                    state = .base
                } else if isSeparator(line) {
                    state = .theirs
                } else {
                    ours.append(line)
                }
            case .base:
                if isSeparator(line) {
                    state = .theirs
                } else {
                    base?.append(line)
                }
            case .theirs:
                if let label = marker(line, ">") {
                    chunks.append(.conflict(Conflict(ours: ours, base: base, theirs: theirs,
                                                     oursLabel: oursLabel, theirsLabel: label)))
                    state = .common
                } else {
                    theirs.append(line)
                }
            }
        }
        guard state == .common, chunks.contains(where: { if case .conflict = $0 { true } else { false } }) else {
            return nil
        }
        if !common.isEmpty { chunks.append(.common(common)) }
        return ConflictFile(chunks: chunks, endsWithNewline: endsWithNewline)
    }

    /// Text after resolution. For each conflict by number, the sides in the desired
    /// order; an empty list discards both; a conflict with no choice keeps its markers.
    public func resolved(_ choices: [Int: [Side]]) -> String {
        var out: [String] = []
        var index = 0
        for chunk in chunks {
            switch chunk {
            case .common(let lines):
                out += lines
            case .conflict(let c):
                if let sides = choices[index] {
                    for side in sides { out += c.lines(side) }
                } else {
                    out.append("<<<<<<< " + c.oursLabel)
                    out += c.ours
                    if let base = c.base {
                        out.append("|||||||")
                        out += base
                    }
                    out.append("=======")
                    out += c.theirs
                    out.append(">>>>>>> " + c.theirsLabel)
                }
                index += 1
            }
        }
        return out.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    /// The text still contains conflict markers.
    public static func hasMarkers(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { marker($0, "<") != nil || marker($0, ">") != nil }
    }

    /// A marker line of seven `c` characters; returns the label after it.
    private static func marker(_ line: String, _ c: Character) -> String? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let prefix = String(repeating: c, count: 7)
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(7)
        if rest.isEmpty { return "" }
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    private static func isSeparator(_ line: String) -> Bool {
        line == "=======" || line == "=======\r"
    }
}

extension GitRepository {
    /// Diff/merge tools that git knows on its own (`git difftool --tool=<name>`),
    /// and custom ones from the configuration (`difftool.<name>.cmd`, `mergetool.<name>.cmd`).
    public func externalTools() async -> [String] {
        var tools = Set<String>()
        if let path = try? await run(["--exec-path"]).text.trimmingCharacters(in: .whitespacesAndNewlines) {
            let dir = URL(fileURLWithPath: path).appending(path: "mergetools")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            // `include` is shared code, not a tool.
            tools.formUnion(files.filter { $0 != "include" && !$0.hasPrefix(".") })
        }
        let config = (try? await run(["config", "--get-regexp", #"^(diff|merge)tool\..*\.cmd$"#], check: false).text) ?? ""
        for line in config.split(separator: "\n") {
            let key = line.split(separator: " ", maxSplits: 1)[0]
            let parts = key.split(separator: ".")
            if parts.count >= 3 { tools.insert(parts[1...(parts.count - 2)].joined(separator: ".")) }
        }
        return tools.sorted()
    }

    /// A `git config` value, such as `diff.tool`, or `nil`.
    public func config(_ key: String) async -> String? {
        let out = try? await run(["config", "--get", key], check: false)
        guard let out, out.exitCode == 0 else { return nil }
        let value = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Opens an external diff: `staged` compares the index against HEAD, otherwise the working file against the index.
    /// Waits until the tool is closed. `tool == nil` behaves as in `diff.tool`.
    public func diffTool(path: String, staged: Bool, tool: String?) async throws {
        var args = ["difftool", "--no-prompt"]
        if let tool { args.append("--tool=\(tool)") }
        if staged { args.append("--cached") }
        try await run(args + ["--", path])
    }

    /// External diff of a file in a commit against its first parent.
    public func diffTool(commit: Commit, path: String, tool: String?) async throws {
        var args = ["difftool", "--no-prompt"]
        if let tool { args.append("--tool=\(tool)") }
        let parent: String
        if let first = commit.parents.first {
            parent = first
        } else {
            // For a root commit, compare against the empty tree.
            parent = try await run(["hash-object", "-t", "tree", "/dev/null"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await run(args + [parent, commit.id, "--", path])
    }

    /// Opens an external merge tool for a file with a conflict and waits for it.
    /// If the tool reports success, git stages the file itself.
    public func mergeTool(path: String, tool: String?) async throws {
        var args = ["mergetool", "--no-prompt"]
        if let tool { args.append("--tool=\(tool)") }
        // No *.orig next to the file. Via the environment rather than `-c`: the log identifies the command by its first argument.
        let env = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "mergetool.keepBackup", "GIT_CONFIG_VALUE_0": "false"]
        try await GitRunner.run(args + ["--", path], in: workingDirectory, environment: env)
    }
}
