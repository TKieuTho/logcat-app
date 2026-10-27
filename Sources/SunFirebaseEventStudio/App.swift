import SwiftUI

@main
struct SunFirebaseEventStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("Logcat") {
            ContentView()
                .environmentObject(model)
                .tint(Theme.accent)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates(manual: true) }
            }
            CommandGroup(after: .textEditing) {
                Button("Copy Selected Event") { model.copySelectedEvent() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Clear Visible Events") { model.clearVisibleEvents() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
