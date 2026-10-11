import AppKit

/// A debug snapshot of the window that needs no system permissions: the window draws itself into a PNG.
///
///   open .build/GitGui.app --args --screenshot /tmp/shot.png --delay 3 --quit
///
/// `--delay` in seconds (2 by default); `--quit` quits the app after the snapshot.
enum DebugScreenshot {
    /// `--select=N`: after loading, select the Nth commit so the inspector can be captured.
    /// It must be with an equals sign: AppKit treats a separate argument "1" as
    /// a file to open, and SwiftUI doesn't create a window.
    nonisolated static var selectRow: Int? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--select=") }
            .flatMap { Int($0.dropFirst("--select=".count)) }
    }

    /// `--working-tree`: show the working tree panel.
    nonisolated static var showWorkingTree: Bool {
        ProcessInfo.processInfo.arguments.contains("--working-tree")
    }

    @MainActor
    static func armIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        var delay: TimeInterval = 2
        if let d = args.firstIndex(of: "--delay"), d + 1 < args.count, let v = TimeInterval(args[d + 1]) { delay = v }
        let quit = args.contains("--quit")

        // The first launch after a rebuild can be slow, so the delay is
        // counted from when the window appears, not from process start.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            waitForWindow(attempts: 60) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    capture(to: path)
                    if quit { NSApp.terminate(nil) }
                }
            }
        }
    }

    @MainActor
    private static func waitForWindow(attempts: Int, then done: @escaping @MainActor () -> Void) {
        if visibleWindow() != nil || attempts == 0 {
            done()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                waitForWindow(attempts: attempts - 1, then: done)
            }
        }
    }

    @MainActor
    private static func visibleWindow() -> NSWindow? {
        // NSApp appears after App.init, so the first check is deferred.
        (NSApp?.windows ?? []).first { $0.isVisible && !$0.isMiniaturized && $0.contentView != nil }
    }

    @MainActor
    static func capture(to path: String) {
        guard let window = visibleWindow(),
              // The window's root view includes the title bar and toolbar.
              let frameView = window.contentView?.superview else {
            let list = (NSApp?.windows ?? []).map {
                "\(type(of: $0)) visible=\($0.isVisible) mini=\($0.isMiniaturized) content=\($0.contentView != nil) frame=\($0.frame)"
            }
            FileHandle.standardError.write(Data("screenshot: no visible window; windows: \(list)\n".utf8))
            return
        }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("screenshot: \(error)\n".utf8))
        }
    }
}
