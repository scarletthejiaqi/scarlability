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
    /// The library's "Import PDF" file picker is showing (also opened from the menu bar).
    var isImportingPDF = false
    /// The note being edited, shown full screen over the library.
    var openDocument: NoteDocument?
    let toolSettings = ToolSettings()
    var folderName: String? { folderAccess?.displayName }
    /// The notes folder, once it's open.
    var notesFolder: NotebookFolder? {
        if case .ready(let library) = state { return library.folder }
        return nil
    }

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
        library.noteOpened(note)
        Task {
            do {
                let document = try await NoteDocument.open(note, in: library.folder)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-SeedDemoInk") {
                    document.seedDemoInkIfEmpty()
                }
                #endif
                openDocument = document
                document.startWatching()
                #if DEBUG
                // `-DebugSync`: 2 seconds after opening, "another device" writes blue ink on page 1,
                // adds a page with writing on it, and renames the note (moving its package).
                if ProcessInfo.processInfo.arguments.contains("-DebugSync"), let first = document.pages.first {
                    let other = NotebookFolder(root: library.folder.root, deviceID: UUID())
                    let firstID = first.id, lastKey = (document.pages.filter(\.isSaved).last?.record.sortKey ?? 1)
                    let url = await document.currentURL()
                    try? await Task.sleep(for: .seconds(2))
                    _ = try? await NotesIO.run {
                        let swirl = Stroke(color: .blue, points: (0..<200).map { i in
                            let t = Double(i) / 200 * 6 * .pi
                            return InkPoint(x: Float(300 + 60 * cos(t) + 8 * t), y: Float(500 + 60 * sin(t)), width: 3)
                        })
                        try other.saveOwnInk(DeviceInk(strokes: [swirl]), page: firstID, inNoteAt: url)
                        let page = PageRecord(sortKey: lastKey + 0.5, size: PageSize.a4, paper: .whiteLined)
                        try other.save(page, inNoteAt: url)
                        try other.saveOwnInk(DeviceInk(strokes: DemoInk.strokes(color: .blue)), page: page.id, inNoteAt: url)
                        _ = try other.renameNote(at: url, to: "Renamed on the Mac")
                    }
                    // Write here right away, before the next check notices the rename: the save
                    // must land in the renamed note, not make a stray copy under the old name.
                    if let page = document.pages.first {
                        document.addStroke([.init(stroke: Stroke(color: .red, points: DemoInk.strokes()[0].points), pageID: page.id)])
                        document.saveNow()
                    }
                }
                // `-DebugSyncDelete`: 2 seconds after opening, "another device" deletes the note.
                if ProcessInfo.processInfo.arguments.contains("-DebugSyncDelete") {
                    let other = NotebookFolder(root: library.folder.root, deviceID: UUID())
                    let url = await document.currentURL()
                    try? await Task.sleep(for: .seconds(2))
                    _ = try? await NotesIO.run { try other.deleteNote(at: url) }
                }
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

    /// File › New Note (⌘N): a new note in the folder the library shows, opened right away.
    func newNote() {
        guard case .ready(let library) = state else { return }
        Task {
            if openDocument != nil {
                closeDocument()
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let note = await library.createNote() {
                openNote(note)
            }
        }
    }

    /// File › Import PDF (⇧⌘I): back to the library, then its file picker.
    func requestPDFImport() {
        guard case .ready = state else { return }
        Task {
            if openDocument != nil {
                closeDocument()
                try? await Task.sleep(for: .milliseconds(400))
            }
            isImportingPDF = true
        }
    }

    /// A PDF opened in the app from elsewhere ("Open in Scarlability"): it becomes a new note,
    /// which opens.
    func importPDF(from url: URL) {
        guard case .ready(let library) = state else { return }
        Task {
            guard let note = await library.importPDFs([url]).first else { return }
            if openDocument != nil {
                closeDocument()
                try? await Task.sleep(for: .milliseconds(400))
            }
            openNote(note)
        }
    }

    /// Saves and closes the open note, and refreshes the library (titles, thumbnails).
    func closeDocument() {
        openDocument?.stopWatching()
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
            // Picks up what other devices change, while the library is showing.
            library.startWatching { [weak self] in self?.openDocument != nil }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-SeedLibrary") {
                await library.seedDemoLibraryIfEmpty()
            }
            // `-DebugSyncLibrary`: 2 seconds in, "another device" adds a note to the first folder.
            if arguments.contains("-DebugSyncLibrary") {
                let other = NotebookFolder(root: library.folder.root, deviceID: UUID())
                let subject = library.snapshot.allSubjects.first?.id
                try? await Task.sleep(for: .seconds(2))
                _ = try? await NotesIO.run {
                    let note = try other.createNote(title: "Written on the Mac", inSubject: subject)
                    let page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
                    try other.save(page, inNoteAt: note.url)
                    try other.saveOwnInk(DeviceInk(strokes: DemoInk.strokes(color: .blue)), page: page.id, inNoteAt: note.url)
                }
            }
            // `-SeedPDF`: import a demo lecture PDF as a new note and open it.
            if arguments.contains("-SeedPDF") {
                let url = FileManager.default.temporaryDirectory.appending(path: "Calculus Lecture.pdf")
                try? DemoPDF.data().write(to: url)
                if let note = await library.importPDFs([url]).first {
                    openNote(note)
                }
                return
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
