import CoreGraphics
import Foundation
import Observation
import ScarlabilityKit
import os

/// An open note: its pages and ink, undo history, and saving back to the notes folder.
///
/// There is always one blank page at the end. It only exists in memory until someone writes on
/// it, so two devices never both create a "blank last page" in the shared folder.
@Observable
final class NoteDocument {
    struct Page: Identifiable {
        var record: PageRecord
        /// What this device wrote on the page; the only ink it ever saves.
        var ownInk: DeviceInk
        /// Ink from other devices, read from their files.
        var otherInks: [UUID: DeviceInk]
        /// False for the blank last page until someone writes on it.
        var isSaved: Bool
        private(set) var visibleStrokes: [Stroke] = []

        var id: UUID { record.id }

        init(record: PageRecord, ownInk: DeviceInk, otherInks: [UUID: DeviceInk], isSaved: Bool) {
            self.record = record
            self.ownInk = ownInk
            self.otherInks = otherInks
            self.isSaved = isSaved
            refreshVisibleStrokes()
        }

        mutating func refreshVisibleStrokes() {
            visibleStrokes = InkMerge.visibleStrokes(from: [ownInk] + otherInks.values)
        }
    }

    enum Change {
        case pagesChanged
        case inkChanged(pageID: UUID, area: CGRect)
    }

    private enum Edit {
        case addStroke(Stroke, pageID: UUID)
    }

    private(set) var note: NoteRecord
    private(set) var pages: [Page]
    /// Set when writing to the notes folder fails; cleared by the next successful save.
    private(set) var saveFailed = false
    private var history = UndoHistory<Edit>()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Called for every change, so the canvas can redraw just what changed.
    @ObservationIgnored var onChange: ((Change) -> Void)?

    @ObservationIgnored private let folder: NotebookFolder
    @ObservationIgnored private var noteNeedsSave = false
    @ObservationIgnored private var pageRecordsToSave: Set<UUID> = []
    @ObservationIgnored private var inkToSave: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Changes are written this long after the last edit, so a burst of writing is one save.
    private static let saveDelay: Duration = .seconds(1)
    nonisolated private static let ioQueue = DispatchQueue(label: "scarlability.notes-io")
    nonisolated private static let logger = Logger(subsystem: "scarlability", category: "NoteDocument")

    init(note: NoteRecord, loadedPages: [NotebookFolder.LoadedPage], folder: NotebookFolder) {
        self.note = note
        self.folder = folder
        self.pages = loadedPages.map { loaded in
            var others = loaded.inks
            let own = others.removeValue(forKey: folder.deviceID) ?? DeviceInk()
            return Page(record: loaded.record, ownInk: own, otherInks: others, isSaved: true)
        }
        _ = normalizeTrailingPages()
    }

    /// Opens the most recently edited note, or creates one. (The real library arrives in M3.)
    static func openTestNote(in folder: NotebookFolder) async throws -> NoteDocument {
        let (note, pages) = try await Task.detached {
            let notes = try folder.loadNotes().filter { $0.deletedAt == nil }
            if let latest = notes.max(by: { $0.modifiedAt < $1.modifiedAt }) {
                return (latest, try folder.loadPages(ofNote: latest.id))
            }
            let note = NoteRecord(title: "Test Note")
            try folder.save(note)
            return (note, [])
        }.value
        return NoteDocument(note: note, loadedPages: pages, folder: folder)
    }

    // MARK: - Editing

    /// Called when a stroke starts. Writing on the blank last page adds a new blank page below it.
    func beginWriting(onPage pageID: UUID) {
        guard pages.last?.id == pageID else { return }
        appendBlankPage()
        onChange?(.pagesChanged)
    }

    /// Called when a stroke is abandoned (e.g. a second finger turned it into a scroll).
    func cancelWriting() {
        if normalizeTrailingPages() {
            onChange?(.pagesChanged)
        }
    }

    func addStroke(_ stroke: Stroke, toPage pageID: UUID) {
        let edit = Edit.addStroke(stroke, pageID: pageID)
        apply(edit, reversed: false)
        history.record(edit)
    }

    func undo() {
        if let edit = history.popUndo() {
            apply(edit, reversed: true)
        }
    }

    func redo() {
        if let edit = history.popRedo() {
            apply(edit, reversed: false)
        }
    }

    private func apply(_ edit: Edit, reversed: Bool) {
        switch edit {
        case .addStroke(let stroke, let pageID):
            guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
            if reversed {
                pages[index].ownInk.strokes.removeAll { $0.id == stroke.id }
            } else {
                pages[index].ownInk.strokes.append(stroke)
            }
            pages[index].refreshVisibleStrokes()
            inkDidChange(onPageAt: index)
            onChange?(.inkChanged(pageID: pageID, area: stroke.bounds))
        }
        if normalizeTrailingPages() {
            onChange?(.pagesChanged)
        }
    }

    /// Keeps exactly one blank page at the end. Returns whether pages were added or removed.
    private func normalizeTrailingPages() -> Bool {
        var changed = false
        while pages.count >= 2,
              let last = pages.last, !last.isSaved, last.visibleStrokes.isEmpty,
              pages[pages.count - 2].visibleStrokes.isEmpty {
            pages.removeLast()
            changed = true
        }
        if pages.last.map({ !$0.visibleStrokes.isEmpty }) ?? true {
            appendBlankPage()
            changed = true
        }
        return changed
    }

    private func appendBlankPage() {
        let record = PageRecord(
            sortKey: (pages.last?.record.sortKey ?? 0) + 1,
            size: note.defaultPageSize,
            paper: note.defaultPaper
        )
        pages.append(Page(record: record, ownInk: DeviceInk(), otherInks: [:], isSaved: false))
    }

    // MARK: - Saving

    private func inkDidChange(onPageAt index: Int) {
        if !pages[index].isSaved {
            pages[index].isSaved = true
            pageRecordsToSave.insert(pages[index].id)
        }
        inkToSave.insert(pages[index].id)
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes all unsaved changes now. Also called when the app goes to the background.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let note = noteNeedsSave ? self.note : nil
        let records = pages.filter { pageRecordsToSave.contains($0.id) }.map(\.record)
        let inks = pages.filter { inkToSave.contains($0.id) }.map { ($0.id, $0.ownInk) }
        guard note != nil || !records.isEmpty || !inks.isEmpty else { return }
        noteNeedsSave = false
        pageRecordsToSave.removeAll()
        inkToSave.removeAll()

        let folder = folder
        let noteID = self.note.id
        Self.ioQueue.async {
            let failed: Bool
            do {
                // Page records first, so another device never sees ink for a page it doesn't know.
                for record in records {
                    try folder.save(record, inNote: noteID)
                }
                for (pageID, ink) in inks {
                    try folder.saveOwnInk(ink, page: pageID, inNote: noteID)
                }
                if let note {
                    try folder.save(note)
                }
                failed = false
            } catch {
                Self.logger.error("Saving note \(noteID) failed: \(error)")
                failed = true
            }
            Task { @MainActor [weak self] in
                self?.saveDidFinish(failed: failed, records: records.map(\.id), inks: inks.map(\.0))
            }
        }
    }

    private func saveDidFinish(failed: Bool, records: [UUID], inks: [UUID]) {
        saveFailed = failed
        guard failed else { return }
        // Keep the changes queued so the next save retries them.
        noteNeedsSave = true
        pageRecordsToSave.formUnion(records)
        inkToSave.formUnion(inks)
    }

    #if DEBUG
    /// Fills the first page with demo strokes (launch with `-SeedDemoInk`), for testing without a Pencil.
    func seedDemoInkIfEmpty() {
        guard pages.allSatisfy({ $0.visibleStrokes.isEmpty }), !pages.isEmpty else { return }
        pages[0].ownInk.strokes = DemoInk.strokes()
        pages[0].refreshVisibleStrokes()
        inkDidChange(onPageAt: 0)
        _ = normalizeTrailingPages()
    }
    #endif
}
