import Foundation

/// A unified diff line.
public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case context, addition, deletion, meta }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(id: Int, kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    /// A `@@ -a,b +c,d @@ context` line.
    public let header: String
    public let lines: [DiffLine]

    public init(id: Int, header: String, lines: [DiffLine]) {
        self.id = id
        self.header = header
        self.lines = lines
    }
}

/// Changes to a single file.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public enum Status: Sendable { case added, deleted, modified, renamed, copied }

    public let oldPath: String?
    public let newPath: String?
    public let status: Status
    public let isBinary: Bool
    public let hunks: [DiffHunk]
    public let additions: Int
    public let deletions: Int

    public var id: String { path }
    public var path: String { newPath ?? oldPath ?? "" }

    public init(oldPath: String?, newPath: String?, status: Status, isBinary: Bool, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
        var a = 0, d = 0
        for h in hunks {
            for l in h.lines {
                switch l.kind {
                case .addition: a += 1
                case .deletion: d += 1
                default: break
                }
            }
        }
        additions = a
        deletions = d
    }
}

/// Parsing of `git diff` / `git show --patch`.
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var builder: FileBuilder?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Substring(raw)
            if line.hasPrefix("diff --git ") {
                if let b = builder { files.append(b.build()) }
                builder = FileBuilder(header: String(line))
                continue
            }
            guard builder != nil else { continue }

            if line.hasPrefix("@@") {
                builder!.startHunk(String(line))
            } else if builder!.inHunk {
                builder!.addLine(line)
            } else {
                builder!.addMeta(line)
            }
        }
        if let b = builder { files.append(b.build()) }
        return files
    }

    /// Diff for a file that isn't in git yet: the whole text as added.
    public static func additionsOnly(path: String, text: String) -> FileDiff {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [DiffLine] = []
        for (i, l) in lines.enumerated() {
            // A trailing newline produces an empty tail, which is not a line of the file.
            if i == lines.count - 1, l.isEmpty { break }
            out.append(DiffLine(id: i, kind: .addition, text: String(l), oldNumber: nil, newNumber: i + 1))
        }
        let hunk = DiffHunk(id: 0, header: "@@ -0,0 +1,\(out.count) @@", lines: out)
        return FileDiff(oldPath: nil, newPath: path, status: .added, isBinary: false, hunks: out.isEmpty ? [] : [hunk])
    }

    private struct FileBuilder {
        var oldPath: String?
        var newPath: String?
        var status: FileDiff.Status = .modified
        var isBinary = false
        var hunks: [DiffHunk] = []

        var inHunk = false
        var hunkHeader = ""
        var hunkLines: [DiffLine] = []
        var oldLine = 0, newLine = 0
        var lineID = 0

        init(header: String) {
            // "diff --git a/path b/path" is a fallback source of paths when there is no ---/+++.
            let body = header.dropFirst("diff --git ".count)
            if let r = body.range(of: " b/") {
                oldPath = String(body[body.index(body.startIndex, offsetBy: 2)..<r.lowerBound])
                newPath = String(body[r.upperBound...])
            }
        }

        mutating func addMeta(_ line: Substring) {
            if line.hasPrefix("--- ") {
                oldPath = path(from: line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                newPath = path(from: line.dropFirst(4))
            } else if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .deleted
            } else if line.hasPrefix("rename from ") {
                status = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                newPath = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                status = .copied
                oldPath = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                newPath = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            }
        }

        private func path(from s: Substring) -> String? {
            if s == "/dev/null" { return nil }
            // Git adds the a/ and b/ prefixes; a tab and a date may follow the path.
            var p = s.split(separator: "\t", maxSplits: 1)[0]
            if p.hasPrefix("a/") || p.hasPrefix("b/") { p = p.dropFirst(2) }
            return String(p)
        }

        mutating func startHunk(_ header: String) {
            finishHunk()
            inHunk = true
            hunkHeader = header
            // @@ -old[,n] +new[,m] @@
            let parts = header.split(separator: " ")
            oldLine = parts.count > 1 ? number(parts[1].dropFirst()) : 0
            newLine = parts.count > 2 ? number(parts[2].dropFirst()) : 0
        }

        private func number(_ s: Substring) -> Int {
            Int(s.split(separator: ",")[0]) ?? 0
        }

        mutating func addLine(_ line: Substring) {
            defer { lineID += 1 }
            let text = String(line.dropFirst())
            switch line.first {
            case " ":
                hunkLines.append(DiffLine(id: lineID, kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            case "+":
                hunkLines.append(DiffLine(id: lineID, kind: .addition, text: text, oldNumber: nil, newNumber: newLine))
                newLine += 1
            case "-":
                hunkLines.append(DiffLine(id: lineID, kind: .deletion, text: text, oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            case "\\":
                hunkLines.append(DiffLine(id: lineID, kind: .meta, text: String(line), oldNumber: nil, newNumber: nil))
            case nil:
                // An empty context line (git usually writes a single space, but not always).
                hunkLines.append(DiffLine(id: lineID, kind: .context, text: "", oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            default:
                // Something outside a hunk: the next file will start with "diff --git".
                inHunk = false
                finishHunk()
                addMeta(line)
            }
        }

        mutating func finishHunk() {
            guard !hunkHeader.isEmpty else { return }
            hunks.append(DiffHunk(id: hunks.count, header: hunkHeader, lines: hunkLines))
            hunkHeader = ""
            hunkLines = []
        }

        func build() -> FileDiff {
            var copy = self
            copy.finishHunk()
            var status = copy.status
            if status == .modified {
                if oldPath == nil { status = .added } else if newPath == nil { status = .deleted }
            }
            return FileDiff(oldPath: copy.oldPath, newPath: copy.newPath, status: status,
                            isBinary: copy.isBinary, hunks: copy.hunks)
        }
    }
}
