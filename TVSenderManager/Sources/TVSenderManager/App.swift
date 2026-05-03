import SwiftUI
import AppKit

@main
struct TVSenderManagerApp: App {
    @StateObject private var store = ChannelStore()

    init() {
        // When launched as a bare executable (no .app bundle), macOS would
        // otherwise treat the process as an "accessory" and never bring its
        // window to the foreground. Force regular activation so the window
        // shows up no matter how the app is started.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Samsung TV Senderverwaltung") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Senderliste öffnen…") {
                    store.openFolderPicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Speichern") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.hasUnsavedChanges)
                Button("Speichern unter…") { store.saveAsFolderPicker() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.folderURL == nil)
                Button("Änderungen verwerfen") { store.discardChanges() }
                    .disabled(!store.hasUnsavedChanges)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Rückgängig") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Wiederherstellen") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
        }
    }
}
