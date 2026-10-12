import SwiftUI

@main
struct GitGuiApp: App {
    @State private var store = RepositoryStore()

    init() {
        DebugScreenshot.armIfRequested()
        OperationLog.shared.install()
    }

    var body: some Scene {
        WindowGroup("GitGui") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { store.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}
