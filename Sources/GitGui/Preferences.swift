import AppKit
import SwiftUI

/// App settings in UserDefaults. Views read them through
/// `@AppStorage` with these keys; other code uses the static properties.
enum Preferences {
    /// Path to the editor's .app; empty means the default app for the file.
    static let editorKey = "editorApp"
    /// Path to the terminal's .app; empty means Terminal.
    static let terminalKey = "terminalApp"
    /// Tool name for `git difftool`/`git mergetool`; empty means take it from `diff.tool`/`merge.tool`.
    static let diffToolKey = "diffTool"
    static let mergeToolKey = "mergeTool"
    /// Monospaced font family for the diff and the conflict editor; empty means the system font.
    static let fontNameKey = "codeFontName"
    static let fontSizeKey = "codeFontSize"

    static let defaultFontSize = 12.0

    private static var defaults: UserDefaults { .standard }

    static var editor: String? { nonEmpty(defaults.string(forKey: editorKey)) }
    static var terminal: String? { nonEmpty(defaults.string(forKey: terminalKey)) }
    static var diffTool: String? { nonEmpty(defaults.string(forKey: diffToolKey)) }
    static var mergeTool: String? { nonEmpty(defaults.string(forKey: mergeToolKey)) }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Code font: the chosen family or the system monospaced font.
    static func codeFont(name: String, size: Double) -> Font {
        if !name.isEmpty, NSFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, design: .monospaced)
    }

    static func codeNSFont(name: String, size: Double) -> NSFont {
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Monospaced font families installed on the system.
    @MainActor
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
              let name = members.first?.first as? String,
              let font = NSFont(name: name, size: 12) else { return false }
        return font.isFixedPitch
    }

    /// Opens files or a directory in the app at `appPath`; without it, behaves like Finder.
    @MainActor
    static func open(_ urls: [URL], appPath: String?) {
        guard let appPath else {
            for url in urls { NSWorkspace.shared.open(url) }
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: appPath),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The app's name from the path to its .app.
    static func appName(_ path: String) -> String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Code font from Settings: use `.codeFont()` instead of `.font(...)`.
private struct CodeFont: ViewModifier {
    @AppStorage(Preferences.fontNameKey) private var name = ""
    @AppStorage(Preferences.fontSizeKey) private var size = Preferences.defaultFontSize
    var scale = 1.0

    func body(content: Content) -> some View {
        content.font(Preferences.codeFont(name: name, size: size * scale))
    }
}

extension View {
    func codeFont(scale: Double = 1) -> some View {
        modifier(CodeFont(scale: scale))
    }
}
