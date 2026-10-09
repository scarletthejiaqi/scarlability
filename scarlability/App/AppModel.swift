import Foundation
import Observation
import ScarlabilityKit

/// App-wide state: where notes are stored, the library, and the open note.
@Observable
final class AppModel {
    enum State {
        case needsFolder
        case loading
        case ready(LibraryModel)
        case failed(String)
    }

    private(set) var state: State = .needsFolder
    /// The note being edited, shown full screen over the library.
    var openDocument: NoteDocument?
    let toolSettings = ToolSettings()
    var folderName: String? { folderAccess?.displayName }

    private var folderAccess: FolderAccess?

    init() {
        if let access = FolderAccess.restore() {
            open(access)
        }
    }

    /// Called with the folder the user picked in the folder picker.
    func chooseFolder(_ url: URL) {
        do {
            open(try FolderAccess.grant(url))
        } catch {
            state = .failed("Couldn't use that folder: \(error.localizedDescription)")
        }
    }

    func forgetFolder() {
        closeDocument()
        folderAccess?.stop()
        folderAccess = nil
        FolderAccess.forget()
        state = .needsFolder
    }

    func openNote(_ note: NotebookFolder.StoredNote) {
        guard case .ready(let library) = state else { return }
        Task {
            do {
                let document = try await NoteDocument.open(note, in: library.folder)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-SeedDemoInk") {
                    document.seedDemoInkIfEmpty()
                }
                #endif
                openDocument = document
                #if DEBUG
                // Rename while open, write right after, then close: checks no stray copy is left.
                if ProcessInfo.processInfo.arguments.contains("-DebugRenameOpenNote") {
                    document.rename(to: "Renamed Note")
                    if let page = document.pages.first {
                        document.addStroke([.init(stroke: Stroke(color: .red, points: DemoInk.strokes()[0].points), pageID: page.id)])
                    }
                    try? await Task.sleep(for: .seconds(2))
                    closeDocument()
                }
                #endif
            } catch {
                library.errorMessage = "Couldn't open “\(note.record.title)”: \(error.localizedDescription)"
            }
        }
    }

    /// Saves and closes the open note, and refreshes the library (titles, thumbnails).
    func closeDocument() {
        openDocument?.saveNow()
        openDocument = nil
        if case .ready(let library) = state {
            // Saves run on the same queue first, so the reload sees them.
            Task { await library.reload() }
        }
    }

    private func open(_ access: FolderAccess) {
        folderAccess?.stop()
        folderAccess = access
        state = .loading
        let library = LibraryModel(folder: NotebookFolder(root: access.notesURL, deviceID: DeviceIdentity.id))
        Task {
            await library.reload()
            state = .ready(library)
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-SeedLibrary") {
                await library.seedDemoLibraryIfEmpty()
            }
            // For the canvas debug scenarios: open (or make) a note right away.
            if arguments.contains("-OpenFirstNote") {
                var note = library.snapshot.allNotes.first
                if note == nil {
                    note = await library.createNote()
                }
                if let note {
                    openNote(note)
                }
            }
            #endif
        }
    }
}

enum DeviceIdentity {
    private static let key = "deviceID"

    /// A random ID for this install. Each device's ink files are named after it, so devices
    /// never write to the same file.
    static var id: UUID {
        if let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
