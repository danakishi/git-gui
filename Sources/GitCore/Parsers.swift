import Foundation

/// Parsing of git output. We define the formats ourselves (see ``GitRepository``),
/// so the parsers expect NUL-separated fields and newline-separated records.
public enum GitParsers {
    static let fieldSeparator: Character = "\0"

    // MARK: git log

    /// Format for `git log --format=...`: eight NUL-separated fields.
    /// `%D` (decorations) is last and may be empty.
    public static let logFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%ct%x00%s"

    public static func parseLog(_ text: String) -> [Commit] {
        var result: [Commit] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: fieldSeparator, maxSplits: 6, omittingEmptySubsequences: false)
            guard f.count == 7,
                  let at = TimeInterval(f[4]), let ct = TimeInterval(f[5]) else { continue }
            result.append(Commit(
                id: String(f[0]),
                parents: f[1].split(separator: " ").map(String.init),
                authorName: String(f[2]),
                authorEmail: String(f[3]),
                authorDate: Date(timeIntervalSince1970: at),
                commitDate: Date(timeIntervalSince1970: ct),
                subject: String(f[6])
            ))
        }
        return result
    }

    // MARK: git for-each-ref

    /// `%(*objectname)` is the peeled commit for annotated tags, otherwise empty.
    /// `%(HEAD)` is `*` for the current branch, `%(worktreepath)` is where the branch is checked out (in this or another worktree).
    public static let refFormat = "%(refname)%00%(objectname)%00%(*objectname)%00%(upstream:short)%00%(HEAD)%00%(worktreepath)"

    public static func parseRefs(_ text: String) -> [Ref] {
        var result: [Ref] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: fieldSeparator, maxSplits: 5, omittingEmptySubsequences: false)
            guard f.count >= 5 else { continue }
            let name = String(f[0])
            let peeled = String(f[2])
            let target = peeled.isEmpty ? String(f[1]) : peeled
            let upstream = f[3].isEmpty ? nil : String(f[3])
            let isHead = f[4] == "*"
            let worktree = f.count > 5 && !f[5].isEmpty ? String(f[5]) : nil

            let kind: Ref.Kind
            let short: String
            if name.hasPrefix("refs/heads/") {
                kind = .localBranch
                short = String(name.dropFirst("refs/heads/".count))
            } else if name.hasPrefix("refs/remotes/") {
                short = String(name.dropFirst("refs/remotes/".count))
                // `origin/HEAD` is just a pointer to the default branch and is not needed in the list.
                if short.hasSuffix("/HEAD") { continue }
                kind = .remoteBranch
            } else if name.hasPrefix("refs/tags/") {
                kind = .tag
                short = String(name.dropFirst("refs/tags/".count))
            } else if name == "refs/stash" {
                kind = .stash
                short = "stash"
            } else {
                kind = .other
                short = name
            }
            result.append(Ref(id: name, kind: kind, shortName: short, target: target, isHead: isHead,
                              upstream: upstream, worktreePath: worktree))
        }
        return result
    }

    // MARK: git status --porcelain=v2 --branch

    public static func parseStatus(_ text: String) -> WorkingTreeStatus {
        var branch: String?
        var upstream: String?
        var ahead = 0, behind = 0
        var entries: [StatusEntry] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            switch line.first {
            case "#":
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.head": branch = parts[2] == "(detached)" ? nil : String(parts[2])
                case "branch.upstream": upstream = String(parts[2])
                case "branch.ab":
                    // "+N -M"
                    let ab = parts[2].split(separator: " ")
                    if ab.count == 2 {
                        ahead = Int(ab[0].dropFirst()) ?? 0
                        behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                entries.append(StatusEntry(
                    path: String(parts[8]),
                    index: change(parts[1].first), worktree: change(parts[1].last),
                    submodule: submodule(parts[2])
                ))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path\torigPath
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10 else { continue }
                let paths = parts[9].split(separator: "\t", maxSplits: 1)
                entries.append(StatusEntry(
                    path: String(paths[0]),
                    originalPath: paths.count > 1 ? String(paths[1]) : nil,
                    index: change(parts[1].first), worktree: change(parts[1].last),
                    submodule: submodule(parts[2])
                ))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                entries.append(StatusEntry(
                    path: String(parts[10]),
                    index: change(parts[1].first), worktree: change(parts[1].last),
                    isConflict: true
                ))
            case "?":
                entries.append(StatusEntry(path: String(line.dropFirst(2)), index: .untracked, worktree: .untracked))
            case "!":
                entries.append(StatusEntry(path: String(line.dropFirst(2)), index: .ignored, worktree: .ignored))
            default:
                continue
            }
        }
        return WorkingTreeStatus(branch: branch, upstream: upstream, ahead: ahead, behind: behind, entries: entries)
    }

    // MARK: git stash list

    /// `%gd` is `stash@{N}`, `%H` the sha, `%at` the date, `%gs` the reflog message.
    public static let stashFormat = "%gd%x00%H%x00%at%x00%gs"

    public static func parseStashList(_ text: String) -> [StashEntry] {
        var result: [StashEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: fieldSeparator, maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let at = TimeInterval(f[2]) else { continue }
            // "stash@{3}" → 3
            let digits = f[0].drop { !$0.isNumber }.prefix { $0.isNumber }
            guard let index = Int(digits) else { continue }
            result.append(StashEntry(index: index, sha: String(f[1]),
                                     date: Date(timeIntervalSince1970: at), message: String(f[3])))
        }
        return result
    }

    /// The `sub` field: `N...` for a regular file, `S<c><m><u>` for a submodule.
    private static func submodule(_ field: Substring) -> StatusEntry.Submodule? {
        let c = Array(field)
        guard c.count == 4, c[0] == "S" else { return nil }
        return StatusEntry.Submodule(commitChanged: c[1] == "C", hasModifications: c[2] == "M", hasUntracked: c[3] == "U")
    }

    private static func change(_ c: Character?) -> StatusEntry.Change {
        c.flatMap(StatusEntry.Change.init(rawValue:)) ?? .unmodified
    }
}
