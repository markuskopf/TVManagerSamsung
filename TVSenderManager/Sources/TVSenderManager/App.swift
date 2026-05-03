import SwiftUI

@main
struct TVSenderManagerApp: App {
    @StateObject private var store = ChannelStore()

    var body: some Scene {
        WindowGroup("Samsung TV Senderverwaltung") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 620)
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
                Button("Änderungen verwerfen") { store.discardChanges() }
                    .disabled(!store.hasUnsavedChanges)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Suche fokussieren") {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
