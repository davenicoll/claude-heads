import SwiftUI

@main
struct ClaudeHeadsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Claude Heads", systemImage: "bubble.left.and.bubble.right.fill") {
            ForEach(appState.heads) { head in
                Button(head.name) {
                    appState.focusHead(id: head.id)
                }
            }

            if !appState.heads.isEmpty {
                Divider()
            }

            Button("New Head...") {
                appState.showNewHeadDialog()
            }
            .keyboardShortcut("n")

            Button("Settings...") {
                appState.showSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit") {
                appState.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            SettingsView()
        }
    }

}
