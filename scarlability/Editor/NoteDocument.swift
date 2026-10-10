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
        /// This device's versions of text boxes and images on the page, and its deletions.
        var ownItems = DeviceItems()
        var otherItems: [UUID: DeviceItems] = [:]
        /// False for the blank last page until someone writes on it.
        var isSaved: Bool
        private(set) var visibleStrokes: [Stroke] = []
        private(set) var visibleItems: [PageItem] = []
        /// Goes up whenever what's on the page changes, so page thumbnails know to redraw.
        var revision = 0

        var id: UUID { record.id }

        /// Nothing on it: no ink, text, images or scanned background.
        var isBlank: Bool { visibleStrokes.isEmpty && visibleItems.isEmpty && record.background == nil }

        init(record: PageRecord, ownInk: DeviceInk, otherInks: [UUID: DeviceInk], ownItems: DeviceItems = DeviceItems(),
             otherItems: [UUID: DeviceItems] = [:], isSaved: Bool) {
            self.record = record
            self.ownInk = ownInk
            self.otherInks = otherInks
            self.ownItems = ownItems
            self.otherItems = otherItems
            self.isSaved = isSaved
            refreshVisibleStrokes()
        }

        mutating func refreshVisibleStrokes() {
            visibleStrokes = InkMerge.visibleStrokes(from: [ownInk] + otherInks.values)
            visibleItems = ItemMerge.visibleItems(from: [ownItems] + otherItems.values)
            revision += 1
        }
    }

    enum Change {
        case pagesChanged
        case inkChanged(pageID: UUID, area: CGRect)
        /// The page's paper changed; redraw all of it.
        case pageRedraw(pageID: UUID)
    }

    /// A stroke (or one piece of a stroke that crossed onto another page) and its page.
    struct PlacedStroke {
        var stroke: Stroke
        var pageID: UUID
    }

    /// A text box or image and its page.
    struct PlacedItem {
        var item: PageItem
        var pageID: UUID
    }

    /// A text box or image changing: created (no `before`), edited, or deleted (no `after`).
    struct ItemEdit {
        var pageID: UUID
        var before: PageItem?
        var after: PageItem?
    }

    /// One undoable step. Every edit is one of these: writing adds strokes, erasing removes them
    /// (and adds the leftover pieces), moving/recoloring removes the originals and adds changed
    /// copies; text boxes and images get new versions.
    struct Edit {
        var removed: [PlacedStroke] = []
        var added: [PlacedStroke] = []
        var items: [ItemEdit] = []
    }

    /// A change as it was applied, with what's needed to undo it.
    private struct AppliedChange {
        struct Removal {
            var placed: PlacedStroke
            /// This device's own stroke (deleted from its ink), or another device's (marked erased).
            var wasOwn: Bool
        }

        var added: [PlacedStroke] = []
        var removed: [Removal] = []
        var items: [ItemEdit] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && items.isEmpty }

        /// Folds a later change into this one, so a whole eraser swipe undoes in one step.
        mutating func merge(_ later: AppliedChange) {
            for edit in later.items {
                let id = edit.before?.id ?? edit.after?.id
                if let index = items.firstIndex(where: { ($0.before?.id ?? $0.after?.id) == id && $0.pageID == edit.pageID }) {
                    items[index].after = edit.after
                } else {
                    items.append(edit)
                }
            }
            for removal in later.removed {
                if let index = added.firstIndex(where: { $0.stroke.id == removal.placed.stroke.id }) {
                    // Added and removed within the group: it never existed before or after.
                    added.remove(at: index)
                } else {
                    removed.append(removal)
                }
            }
            added += later.added
        }
    }

    private(set) var note: NoteRecord
    /// Where the note's package is. Only read or changed on `NotesIO.queue`, so a rename and the
    /// saves queued around it always agree on where the note is.
    nonisolated private final class Location: @unchecked Sendable {
        var url: URL
        init(_ url: URL) { self.url = url }
    }
    @ObservationIgnored private let location: Location
    private(set) var pages: [Page]
    /// Set when writing to the notes folder fails; cleared by the next successful save.
    private(set) var saveFailed = false
    private var history = UndoHistory<AppliedChange>()
    /// Changes applied since `beginGroup()`, recorded as one undo step by `endGroup()`.
    @ObservationIgnored private var openGroup: AppliedChange?
    /// The page in the middle of the screen; set by the canvas. Paper changes for "this page" use it.
    @ObservationIgnored var visiblePageID: UUID?

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Called for every change, so the canvas can redraw just what changed.
    @ObservationIgnored var onChange: ((Change) -> Void)?

    @ObservationIgnored private let folder: NotebookFolder
    @ObservationIgnored private var noteNeedsSave = false
    @ObservationIgnored private var pageRecordsToSave: Set<UUID> = []
    @ObservationIgnored private var inkToSave: Set<UUID> = []
    @ObservationIgnored private var itemsToSave: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Changes are written this long after the last edit, so a burst of writing is one save.
    private static let saveDelay: Duration = .seconds(1)
    nonisolated private static let logger = Logger(subsystem: "scarlability", category: "NoteDocument")

    init(note: NotebookFolder.StoredNote, loadedPages: [NotebookFolder.LoadedPage], folder: NotebookFolder) {
        self.note = note.record
        self.location = Location(note.url)
        self.folder = folder
        self.pages = loadedPages.map { loaded in
            var others = loaded.inks
            let own = others.removeValue(forKey: folder.deviceID) ?? DeviceInk()
            var otherItems = loaded.items
            let ownItems = otherItems.removeValue(forKey: folder.deviceID) ?? DeviceItems()
            return Page(record: loaded.record, ownInk: own, otherInks: others, ownItems: ownItems, otherItems: otherItems, isSaved: true)
        }
        _ = normalizeTrailingPages()
    }

    /// Loads a note's pages and ink.
    static func open(_ note: NotebookFolder.StoredNote, in folder: NotebookFolder) async throws -> NoteDocument {
        let pages = try await NotesIO.run { try folder.loadPages(inNoteAt: note.url) }
        return NoteDocument(note: note, loadedPages: pages, folder: folder)
    }

    /// Renames the note (and its package, so Files shows the new name).
    func rename(to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != note.title else { return }
        note.title = title
        note.modifiedAt = Date()
        noteNeedsSave = true
        // Save under the current name first; the rename then runs after it on the same queue.
        saveNow()
        let folder = folder, location = location
        NotesIO.queue.async {
            do {
                location.url = try folder.renameNote(at: location.url, to: title)
            } catch {
                Self.logger.error("Renaming note failed: \(error)")
            }
        }
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

    /// Adds one pen stroke: a single piece, or one piece per page if it crossed a page edge.
    func addStroke(_ pieces: [PlacedStroke]) {
        apply(Edit(added: pieces))
    }

    /// Applies a change and records it for undo (as part of the open group, if any).
    func apply(_ change: Edit) {
        var applied = AppliedChange()
        var touched: [UUID: CGRect] = [:]
        for placed in change.removed {
            // Only strokes the page still shows can be removed (a stale selection might hold others).
            guard let index = pageIndex(placed.pageID),
                  pages[index].visibleStrokes.contains(where: { $0.id == placed.stroke.id }) else { continue }
            let wasOwn = pages[index].ownInk.strokes.contains { $0.id == placed.stroke.id }
            remove(placed.stroke.id, wasOwn: wasOwn, fromPageAt: index)
            applied.removed.append(.init(placed: placed, wasOwn: wasOwn))
            touched[placed.pageID, default: .null] = touched[placed.pageID, default: .null].union(placed.stroke.bounds)
        }
        for placed in change.added {
            guard let index = pageIndex(placed.pageID) else { continue }
            pages[index].ownInk.strokes.append(placed.stroke)
            applied.added.append(placed)
            touched[placed.pageID, default: .null] = touched[placed.pageID, default: .null].union(placed.stroke.bounds)
        }
        for edit in change.items {
            guard let index = pageIndex(edit.pageID) else { continue }
            let after = setItem(edit.after, replacing: edit.before, onPageAt: index)
            applied.items.append(ItemEdit(pageID: edit.pageID, before: edit.before, after: after))
            let area = (edit.before?.bounds ?? .null).union(edit.after?.bounds ?? .null)
            touched[edit.pageID, default: .null] = touched[edit.pageID, default: .null].union(area)
        }
        guard !applied.isEmpty else { return }
        finish(touched)
        if openGroup != nil {
            openGroup?.merge(applied)
        } else {
            history.record(applied)
        }
    }

    /// Starts collecting changes into one undo step (e.g. for an eraser swipe).
    func beginGroup() {
        openGroup = AppliedChange()
    }

    func endGroup() {
        if let group = openGroup, !group.isEmpty {
            history.record(group)
        }
        openGroup = nil
    }

    func undo() {
        guard openGroup == nil, let change = history.popUndo() else { return }
        var touched: [UUID: CGRect] = [:]
        for placed in change.added {
            guard let index = pageIndex(placed.pageID) else { continue }
            remove(placed.stroke.id, wasOwn: true, fromPageAt: index)
            touched[placed.pageID, default: .null] = touched[placed.pageID, default: .null].union(placed.stroke.bounds)
        }
        for removal in change.removed {
            guard let index = pageIndex(removal.placed.pageID) else { continue }
            if removal.wasOwn {
                pages[index].ownInk.strokes.append(removal.placed.stroke)
            } else {
                pages[index].ownInk.erasedStrokeIDs.remove(removal.placed.stroke.id)
            }
            touched[removal.placed.pageID, default: .null] = touched[removal.placed.pageID, default: .null].union(removal.placed.stroke.bounds)
        }
        for edit in change.items.reversed() {
            guard let index = pageIndex(edit.pageID) else { continue }
            _ = setItem(edit.before, replacing: edit.after, onPageAt: index)
            touched[edit.pageID, default: .null] = touched[edit.pageID, default: .null].union((edit.before?.bounds ?? .null).union(edit.after?.bounds ?? .null))
        }
        finish(touched)
    }

    func redo() {
        guard openGroup == nil, let change = history.popRedo() else { return }
        var touched: [UUID: CGRect] = [:]
        for removal in change.removed {
            guard let index = pageIndex(removal.placed.pageID) else { continue }
            remove(removal.placed.stroke.id, wasOwn: removal.wasOwn, fromPageAt: index)
            touched[removal.placed.pageID, default: .null] = touched[removal.placed.pageID, default: .null].union(removal.placed.stroke.bounds)
        }
        for placed in change.added {
            guard let index = pageIndex(placed.pageID) else { continue }
            pages[index].ownInk.strokes.append(placed.stroke)
            touched[placed.pageID, default: .null] = touched[placed.pageID, default: .null].union(placed.stroke.bounds)
        }
        for edit in change.items {
            guard let index = pageIndex(edit.pageID) else { continue }
            _ = setItem(edit.after, replacing: edit.before, onPageAt: index)
            touched[edit.pageID, default: .null] = touched[edit.pageID, default: .null].union((edit.before?.bounds ?? .null).union(edit.after?.bounds ?? .null))
        }
        finish(touched)
    }

    /// Saves a new version of an item (stamped now, so it wins over every device's older
    /// versions), or deletes `previous` when `item` is nil. Returns the version saved.
    private func setItem(_ item: PageItem?, replacing previous: PageItem?, onPageAt index: Int) -> PageItem? {
        let now = Date()
        if var item {
            item.modifiedAt = max(now, (pages[index].visibleItems.first { $0.id == item.id }?.modifiedAt ?? .distantPast) + 0.001)
            pages[index].ownItems.items.removeAll { $0.id == item.id }
            pages[index].ownItems.items.append(item)
            pages[index].ownItems.deleted[item.id] = nil
            return item
        }
        if let previous {
            pages[index].ownItems.items.removeAll { $0.id == previous.id }
            pages[index].ownItems.deleted[previous.id] = now
        }
        return nil
    }

    // MARK: - Images

    /// Saves an image file into the note package (after any saves already queued).
    func saveImageFile(_ data: Data, named fileName: String) {
        let folder = folder, location = location
        NotesIO.queue.async {
            do {
                try folder.saveImage(data, named: fileName, inNoteAt: location.url)
            } catch {
                Self.logger.error("Saving image failed: \(error)")
            }
        }
    }

    /// The raw file of an image in the note package (for copying it elsewhere).
    func imageData(named fileName: String) async -> Data? {
        let folder = folder, location = location
        return (try? await NotesIO.run { folder.loadImageData(named: fileName, inNoteAt: location.url) }) ?? nil
    }

    /// Reads and decodes an image from the note package.
    func loadImage(named fileName: String, maxPixelSize: Int = 2400) async -> CGImage? {
        let folder = folder, location = location
        let data = try? await NotesIO.run { folder.loadImageData(named: fileName, inNoteAt: location.url) }
        guard let data = data ?? nil else { return nil }
        return await Task.detached(priority: .userInitiated) { ImageLoading.cgImage(from: data, maxPixelSize: maxPixelSize) }.value
    }

    /// Adds scanned pages (each an image file already saved) after a page, as page backgrounds.
    func insertScannedPages(_ fileNames: [String], after pageID: UUID?) {
        guard !fileNames.isEmpty else { return }
        let index = pageID.flatMap { pageIndex($0) } ?? max(pages.count - 2, 0)
        let start = pages.indices.contains(index) ? pages[index].record.sortKey : 0
        let end = index + 1 < pages.count ? pages[index + 1].record.sortKey : start + 1
        for (offset, fileName) in fileNames.enumerated() {
            var record = PageRecord(
                sortKey: start + (end - start) * Double(offset + 1) / Double(fileNames.count + 1),
                size: note.defaultPageSize,
                paper: PaperStyle(template: .blank, color: .white)
            )
            record.background = .image(fileName: fileName)
            pages.insert(Page(record: record, ownInk: DeviceInk(), otherInks: [:], isSaved: true), at: min(index + 1 + offset, pages.count))
            pageRecordsToSave.insert(record.id)
        }
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
        _ = normalizeTrailingPages()
        onChange?(.pagesChanged)
    }

    /// Changes the paper of the whole note (and pages added later), or of one page.
    func setPaper(_ paper: PaperStyle, onlyPage pageID: UUID? = nil) {
        if let pageID {
            guard let index = pageIndex(pageID) else { return }
            pages[index].record.paper = paper
            paperDidChange(onPageAt: index)
        } else {
            note.defaultPaper = paper
            for index in pages.indices {
                pages[index].record.paper = paper
                paperDidChange(onPageAt: index)
            }
        }
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
    }

    /// Adds a blank page at the end (the + in the page panel) and returns its ID. The blank last
    /// page that's always there becomes a real page, so the note grows by one.
    @discardableResult
    func addPage() -> UUID {
        if let last = pages.indices.last, !pages[last].isSaved {
            pages[last].isSaved = true
            pageRecordsToSave.insert(pages[last].id)
        }
        appendBlankPage()
        let index = pages.count - 1
        pages[index].isSaved = true
        pageRecordsToSave.insert(pages[index].id)
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
        onChange?(.pagesChanged)
        return pages[index].id
    }

    /// Deletes a page. Its files stay in the package with the page marked deleted, so another
    /// device that still has the note open can't bring the page back by saving to it.
    func deletePage(_ pageID: UUID) {
        guard let index = pageIndex(pageID) else { return }
        var record = pages[index].record
        let wasSaved = pages[index].isSaved
        pages.remove(at: index)
        pageRecordsToSave.remove(pageID)
        inkToSave.remove(pageID)
        itemsToSave.remove(pageID)
        if wasSaved {
            record.deletedAt = Date()
            let folder = folder, location = location
            // Queued after any save already on its way, so this is the page's last word.
            NotesIO.queue.async {
                do {
                    try folder.save(record, inNoteAt: location.url)
                } catch {
                    Self.logger.error("Deleting a page failed: \(error)")
                }
            }
        }
        if visiblePageID == pageID {
            visiblePageID = nil
        }
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
        _ = normalizeTrailingPages()
        onChange?(.pagesChanged)
    }

    func pageIndex(_ pageID: UUID) -> Int? {
        pages.firstIndex { $0.id == pageID }
    }

    private func remove(_ strokeID: UUID, wasOwn: Bool, fromPageAt index: Int) {
        if wasOwn {
            pages[index].ownInk.strokes.removeAll { $0.id == strokeID }
        } else {
            // Another device's stroke: this device can't change their file, so it records the erase.
            pages[index].ownInk.erasedStrokeIDs.insert(strokeID)
        }
    }

    private func finish(_ touched: [UUID: CGRect]) {
        for (pageID, area) in touched {
            guard let index = pageIndex(pageID) else { continue }
            pages[index].refreshVisibleStrokes()
            inkDidChange(onPageAt: index)
            onChange?(.inkChanged(pageID: pageID, area: area))
        }
        if normalizeTrailingPages() {
            onChange?(.pagesChanged)
        }
    }

    private func paperDidChange(onPageAt index: Int) {
        // Only saved pages have a Page.json; the blank last page picks up the paper when it's saved.
        if pages[index].isSaved {
            pageRecordsToSave.insert(pages[index].id)
        }
        pages[index].revision += 1
        onChange?(.pageRedraw(pageID: pages[index].id))
    }

    /// Keeps exactly one blank page at the end. Returns whether pages were added or removed.
    private func normalizeTrailingPages() -> Bool {
        var changed = false
        while pages.count >= 2,
              let last = pages.last, !last.isSaved, last.isBlank,
              pages[pages.count - 2].isBlank {
            pages.removeLast()
            changed = true
        }
        if pages.last.map({ !$0.isBlank }) ?? true {
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
        itemsToSave.insert(pages[index].id)
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
        let items = pages.filter { itemsToSave.contains($0.id) }.map { ($0.id, $0.ownItems) }
        guard note != nil || !records.isEmpty || !inks.isEmpty || !items.isEmpty else { return }
        noteNeedsSave = false
        pageRecordsToSave.removeAll()
        inkToSave.removeAll()
        itemsToSave.removeAll()

        let folder = folder
        let location = location
        NotesIO.queue.async {
            let noteURL = location.url
            let failed: Bool
            do {
                // Page records first, so another device never sees ink for a page it doesn't know.
                for record in records {
                    try folder.save(record, inNoteAt: noteURL)
                }
                for (pageID, ink) in inks {
                    try folder.saveOwnInk(ink, page: pageID, inNoteAt: noteURL)
                }
                for (pageID, pageItems) in items {
                    try folder.saveOwnItems(pageItems, page: pageID, inNoteAt: noteURL)
                }
                if let note {
                    try folder.save(note, at: noteURL)
                }
                failed = false
            } catch {
                Self.logger.error("Saving \(noteURL.lastPathComponent) failed: \(error)")
                failed = true
            }
            Task { @MainActor [weak self] in
                self?.saveDidFinish(failed: failed, records: records.map(\.id), inks: inks.map(\.0) + items.map(\.0))
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
        itemsToSave.formUnion(inks)
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

/// Lets the open note drive a full-screen cover.
extension NoteDocument: Identifiable {}
