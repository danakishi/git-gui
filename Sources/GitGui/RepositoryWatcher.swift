import CoreServices
import Foundation

/// Watches a repository for changes via FSEvents and fires a callback after a delay,
/// so that a burst of git writes (index.lock, refs, logs) yields a single event.
///
/// There can be several directories: for a worktree or a submodule the git directory lies
/// outside the working tree, and the branches are in the main repository's common directory.
final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.danakishi.gitgui.fsevents")
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let debounce: TimeInterval
    /// Git object directories: written to on every operation, which changes nothing by itself.
    private let ignoredPrefixes: [String]

    init(urls: [URL], gitDirectories: [URL], debounce: TimeInterval = 0.4, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        self.debounce = debounce
        ignoredPrefixes = gitDirectories.map { $0.appending(path: "objects").path + "/" }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        // FSEvents already covers a git directory inside the working tree.
        let roots = urls.map(\.path)
        let paths = roots + gitDirectories.map(\.path).filter { dir in !roots.contains { dir.hasPrefix($0 + "/") } }
        guard let s = FSEventStreamCreate(
            nil, callback, &context, Array(Set(paths)) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
        ) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    private func handle(paths: [String]) {
        // Lock files and objects appear on every operation and change nothing
        // for us by themselves; react to everything else.
        let meaningful = paths.contains { p in
            !(p.hasSuffix(".lock") || p.contains("/.git/objects/") || p.contains("/.build/")
              || ignoredPrefixes.contains { p.hasPrefix($0) })
        }
        guard meaningful else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
