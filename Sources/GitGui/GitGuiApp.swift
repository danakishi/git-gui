import SwiftUI

@main
struct GitGuiApp: App {
    @State private var store = RepositoryStore()

    var body: some Scene {
        WindowGroup("GitGui") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { store.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}
