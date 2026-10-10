import SwiftUI

/// Menu bar commands on the Mac, and keyboard shortcuts on iPad with a keyboard (hold ⌘ to see
/// them). Undo, Redo, Copy, Cut, Paste, Select All and Delete come from the system's Edit menu.
struct NoteCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { model.newNote() }
                .keyboardShortcut("n")
            Button("Import PDF…") { model.requestPDFImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Back to Library") { model.closeDocument() }
                .keyboardShortcut("[")
        }
        CommandMenu("Tools") {
            Button("Pen") { model.toolSettings.tool = .pen }.keyboardShortcut("1")
            Button("Highlighter") { model.toolSettings.tool = .highlighter }.keyboardShortcut("2")
            Button("Eraser") { model.toolSettings.tool = .eraser }.keyboardShortcut("3")
            Button("Text") { model.toolSettings.tool = .text }.keyboardShortcut("4")
            Button("Lasso") { model.toolSettings.tool = .select }.keyboardShortcut("5")
        }
    }
}
