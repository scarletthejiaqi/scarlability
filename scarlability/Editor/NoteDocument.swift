import CoreGraphics
import Foundation
import Observation
import PDFKit
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

        /// A page of an imported PDF. Like Notability, a note ending in a PDF page doesn't get a
        /// blank page after it (add one from the page panel).
        var showsPDF: Bool {
            if case .pdf? = record.background { return true }
            return false
        }

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
        let noteID: UUID
        let folder: NotebookFolder

        init(_ url: URL, noteID: UUID, folder: NotebookFolder) {
            self.url = url
            self.noteID = noteID
            self.folder = folder
        }

        /// Where the note is now. If another device renamed or moved it, finds it again; nil if
        /// it's gone (deleted for good elsewhere), so a save never leaves a stray half-copy.
        func resolved() -> URL? {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
            guard let moved = folder.findNote(id: noteID) else { return nil }
            url = moved
            return moved
        }
    }
    @ObservationIgnored private let location: Location
    private(set) var pages: [Page]
    /// Set when writing to the notes folder fails; cleared by the next successful save.
    private(set) var saveFailed = false
    /// Another device moved the note to Recently Deleted while it was open here.
    private(set) var wasDeletedElsewhere = false
    private var history = UndoHistory<AppliedChange>()
    /// Changes applied since `beginGroup()`, recorded as one undo step by `endGroup()`.
    @ObservationIgnored private var openGroup: AppliedChange?
    /// The page in the middle of the screen; set by the canvas. Paper changes for "this page" use it.
    @ObservationIgnored var visiblePageID: UUID?
    /// Pages known to be saved in the folder, so a page missing there was deleted by another
    /// device (rather than made here and not written yet).
    @ObservationIgnored private var pagesOnDisk: Set<UUID> = []
    /// The last `NotebookFolder.changeStamp` seen, and the loop checking it.
    @ObservationIgnored private var lastStamp: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var pdfFiles: [String: PDFFile] = [:]
    @ObservationIgnored private var pdfData: [String: Data] = [:]
    @ObservationIgnored private var textPDFs: [String: PDFDocument] = [:]

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Called for every change, so the canvas can redraw just what changed.
    @ObservationIgnored var onChange: ((Change) -> Void)?

    /// The notes folder the note is in.
    @ObservationIgnored let folder: NotebookFolder
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
        self.location = Location(note.url, noteID: note.record.id, folder: folder)
        self.folder = folder
        self.pages = loadedPages.map { loaded in
            var others = loaded.inks
            let own = others.removeValue(forKey: folder.deviceID) ?? DeviceInk()
            var otherItems = loaded.items
            let ownItems = otherItems.removeValue(forKey: folder.deviceID) ?? DeviceItems()
            return Page(record: loaded.record, ownInk: own, otherInks: others, ownItems: ownItems, otherItems: otherItems, isSaved: true)
        }
        pagesOnDisk = Set(loadedPages.map(\.record.id))
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
                guard let current = location.resolved() else { return }
                location.url = try folder.renameNote(at: current, to: title)
            } catch {
                Self.logger.error("Renaming note failed: \(error)")
            }
        }
    }

    /// Where the note's package is, once every save and rename asked for so far has happened.
    func currentURL() async -> URL {
        saveNow()
        let location = location
        return await withCheckedContinuation { continuation in
            NotesIO.queue.async { continuation.resume(returning: location.resolved() ?? location.url) }
        }
    }

    // MARK: - Editing

    /// Called when a stroke starts. Writing on the blank last page adds a new blank page below it.
    func beginWriting(onPage pageID: UUID) {
        guard let last = pages.last, last.id == pageID, !last.showsPDF else { return }
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
                guard let noteURL = location.resolved() else { return }
                try folder.saveImage(data, named: fileName, inNoteAt: noteURL)
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
        insertPages(fileNames.map { fileName in
            var record = PageRecord(sortKey: 0, size: note.defaultPageSize, paper: PaperStyle(template: .blank, color: .white))
            record.background = .image(fileName: fileName)
            return (record, DeviceInk(), DeviceItems())
        }, after: pageID)
    }

    /// Adds a PDF's pages after a page (each the PDF page's size, on plain white paper), and
    /// saves the PDF into the note. Returns false if the data isn't a PDF.
    @discardableResult
    func insertPDF(_ data: Data, after pageID: UUID?) -> Bool {
        guard let file = PDFFile(data: data) else { return false }
        let fileName = "\(UUID().uuidString).pdf"
        savePDFFile(data, named: fileName, file: file)
        insertPages((0..<file.pageCount).compactMap { index in
            guard let page = file.page(at: index) else { return nil }
            var record = PageRecord(sortKey: 0, size: page.size, paper: PaperStyle(template: .blank, color: .white))
            record.background = .pdf(fileName: fileName, pageIndex: index)
            return (record, DeviceInk(), DeviceItems())
        }, after: pageID)
        return true
    }

    /// Saves a PDF into the note (before the pages that show it, on the same queue).
    private func savePDFFile(_ data: Data, named fileName: String, file: PDFFile) {
        let folder = folder, location = location
        NotesIO.queue.async {
            do {
                guard let noteURL = location.resolved() else { return }
                try folder.savePDF(data, named: fileName, inNoteAt: noteURL)
            } catch {
                Self.logger.error("Saving PDF failed: \(error)")
            }
        }
        pdfFiles[fileName] = file
        pdfData[fileName] = data
    }

    /// Inserts new, saved pages after a page (or before the blank last page), in order, and
    /// returns their IDs.
    @discardableResult
    private func insertPages(_ new: [(record: PageRecord, ink: DeviceInk, items: DeviceItems)], after pageID: UUID?) -> [UUID] {
        guard !new.isEmpty else { return [] }
        let index = pageID.flatMap { pageIndex($0) } ?? max(pages.count - 2, 0)
        // Adding after the blank last page makes it a real page, so the order stays.
        if pages.indices.contains(index), !pages[index].isSaved {
            pages[index].isSaved = true
            pageRecordsToSave.insert(pages[index].id)
        }
        let start = pages.indices.contains(index) ? pages[index].record.sortKey : 0
        let end = index + 1 < pages.count ? pages[index + 1].record.sortKey : start + 1
        var ids: [UUID] = []
        for (offset, page) in new.enumerated() {
            var record = page.record
            record.sortKey = start + (end - start) * Double(offset + 1) / Double(new.count + 1)
            pages.insert(Page(record: record, ownInk: page.ink, otherInks: [:], ownItems: page.items, isSaved: true),
                         at: min(index + 1 + offset, pages.count))
            pageRecordsToSave.insert(record.id)
            if !page.ink.strokes.isEmpty { inkToSave.insert(record.id) }
            if !page.items.items.isEmpty { itemsToSave.insert(record.id) }
            ids.append(record.id)
        }
        note.modifiedAt = Date()
        noteNeedsSave = true
        scheduleSave()
        _ = normalizeTrailingPages()
        onChange?(.pagesChanged)
        return ids
    }

    // MARK: - Page panel

    /// Adds a blank page right after a page (the page's ⋯ menu › Add page) and returns its ID.
    func addPage(after pageID: UUID) -> UUID? {
        insertPages([(PageRecord(sortKey: 0, size: note.defaultPageSize, paper: note.defaultPaper), DeviceInk(), DeviceItems())],
                    after: pageID).first
    }

    /// Everything on these pages (in note order), with the pictures and PDFs they use, for Copy.
    func copyPages(_ ids: Set<UUID>) async -> CopiedPages? {
        var copied: [CopiedPages.Page] = []
        var files: [String: Data] = [:]
        for page in pages where ids.contains(page.id) {
            guard let entry = try? CopiedPages.Page(size: page.record.size, paper: page.record.paper, background: page.record.background,
                                                     strokes: page.visibleStrokes, items: page.visibleItems) else { continue }
            copied.append(entry)
            for name in CopiedPages.fileNames(background: page.record.background, items: page.visibleItems) where files[name] == nil {
                if case .pdf(name, _)? = page.record.background {
                    _ = await loadPDF(named: name)
                    files[name] = pdfData[name]
                } else {
                    let folder = folder, location = location
                    files[name] = (try? await NotesIO.run { folder.loadImageData(named: name, inNoteAt: location.url) }) ?? nil
                }
            }
        }
        return copied.isEmpty ? nil : CopiedPages(pages: copied, files: files)
    }

    /// Pastes copied pages after a page, as new pages of this note (its files saved into it).
    @discardableResult
    func pastePages(_ copied: CopiedPages, after pageID: UUID?, savingFiles: Bool = true) -> [UUID] {
        let fresh = copied.freshPages()
        if savingFiles {
            let pdfNames = Set(fresh.compactMap { page -> String? in
                if case .pdf(let name, _)? = page.record.background { return name }
                return nil
            })
            for (name, data) in copied.files {
                if pdfNames.contains(name) {
                    if let file = PDFFile(data: data) { savePDFFile(data, named: name, file: file) }
                } else {
                    saveImageFile(data, named: name)
                }
            }
        }
        return insertPages(fresh.map { ($0.record, $0.ink, $0.items) }, after: pageID)
    }

    /// Copies pages, placing the copies right after the last of them.
    func duplicatePages(_ ids: Set<UUID>) async -> [UUID] {
        guard let copied = await copyPages(ids), let last = pages.last(where: { ids.contains($0.id) }) else { return [] }
        return pastePages(copied, after: last.id, savingFiles: false)
    }

    func deletePages(_ ids: Set<UUID>) {
        for id in ids {
            deletePage(id)
        }
    }

    /// Bookmarks pages (or takes their bookmarks off), so the page panel can show just those.
    func setBookmarked(_ bookmarked: Bool, pages ids: Set<UUID>) {
        for id in ids {
            guard let index = pageIndex(id) else { continue }
            pages[index].record.bookmarkedAt = bookmarked ? Date() : nil
            // A bookmarked blank last page is a real page.
            pages[index].isSaved = true
            pageRecordsToSave.insert(id)
        }
        if normalizeTrailingPages() {
            onChange?(.pagesChanged)
        }
        scheduleSave()
    }

    /// Removes everything written, typed and placed on a page (undo puts it back).
    func clearPage(_ id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        apply(Edit(removed: page.visibleStrokes.map { PlacedStroke(stroke: $0, pageID: id) },
                   items: page.visibleItems.map { ItemEdit(pageID: id, before: $0, after: nil) }))
    }

    /// The pages whose typed text, or PDF text, contains `query` (handwriting can't be searched).
    func pagesMatching(_ query: String) async -> Set<UUID> {
        var matches: Set<UUID> = []
        for page in pages {
            if page.visibleItems.contains(where: { $0.text?.plainText.localizedCaseInsensitiveContains(query) == true }) {
                matches.insert(page.id)
            } else if case .pdf(let name, let index)? = page.record.background,
                      let text = await textPDF(named: name)?.page(at: index)?.string,
                      text.localizedCaseInsensitiveContains(query) {
                matches.insert(page.id)
            }
        }
        return matches
    }

    /// An imported PDF in the note, opened once.
    func loadPDF(named fileName: String) async -> PDFFile? {
        if let cached = pdfFiles[fileName] { return cached }
        let folder = folder, location = location
        let data = try? await NotesIO.run { folder.loadPDFData(named: fileName, inNoteAt: location.url) }
        guard let data = data ?? nil, let file = PDFFile(data: data) else { return nil }
        pdfFiles[fileName] = file
        pdfData[fileName] = data
        return file
    }

    /// The same PDF opened with PDFKit, which can find its text (for the highlighter's text snap).
    func textPDF(named fileName: String) async -> PDFDocument? {
        if let cached = textPDFs[fileName] { return cached }
        _ = await loadPDF(named: fileName)
        guard let data = pdfData[fileName], let document = PDFDocument(data: data) else { return nil }
        textPDFs[fileName] = document
        return document
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
        pagesOnDisk.remove(pageID)
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
                    guard let noteURL = location.resolved() else { return }
                    try folder.save(record, inNoteAt: noteURL)
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
        if pages.last.map({ !$0.isBlank && !$0.showsPDF }) ?? true {
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

    // MARK: - Changes from other devices

    /// While the note is open, checks every few seconds whether another device changed it (or
    /// renamed or moved it) and merges what it wrote. iCloud Drive decides when files arrive,
    /// usually within seconds to a minute.
    func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            // What's there now, as loaded; changes after this get merged.
            if let self {
                let folder = self.folder, location = self.location
                self.lastStamp = try? await NotesIO.run { folder.changeStamp(inNoteAt: location.url) }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, !Task.isCancelled else { return }
                await self.checkForChanges()
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    static let watchInterval: Duration = .seconds(3)

    /// Checks right away (when the app comes back to the front).
    func checkForChangesNow() {
        Task { await checkForChanges() }
    }

    private func checkForChanges() async {
        let folder = folder, location = location
        let stamp = try? await NotesIO.run { () -> String? in
            // Renamed or moved on another device: follow it.
            guard let noteURL = location.resolved() else { return nil }
            return folder.changeStamp(inNoteAt: noteURL)
        }
        let trash = folder.root.appending(path: LibraryLayout.recentlyDeletedName).standardizedFileURL.path(percentEncoded: false)
        if location.url.standardizedFileURL.path(percentEncoded: false).hasPrefix(trash) {
            wasDeletedElsewhere = true
            return
        }
        guard let stamp = stamp ?? nil, stamp != lastStamp else { return }
        lastStamp = stamp
        await mergeFromDisk()
    }

    /// Reads the note again and merges other devices' changes into it.
    func mergeFromDisk() async {
        let folder = folder, location = location
        guard let (record, loaded) = try? await NotesIO.run({
            (try? folder.loadRecord(ofNoteAt: location.url), try folder.loadPages(inNoteAt: location.url))
        }) else { return }
        merge(record: record, pages: loaded)
    }

    /// Takes in what other devices saved: their ink, text and images on each page, pages they
    /// added or deleted, paper changes, and a new title. This device's own ink, and anything
    /// changed here but not saved yet, stay as they are.
    func merge(record: NoteRecord?, pages loaded: [NotebookFolder.LoadedPage]) {
        let device = folder.deviceID
        if let record, !noteNeedsSave, record.title != note.title || record.favoritedAt != note.favoritedAt || record.defaultPaper != note.defaultPaper {
            note.title = record.title
            note.favoritedAt = record.favoritedAt
            note.defaultPaper = record.defaultPaper
        }
        var pagesChanged = false
        var redraw: [UUID] = []
        let loadedIDs = Set(loaded.map(\.record.id))
        for page in loaded {
            var others = page.inks
            others.removeValue(forKey: device)
            var otherItems = page.items
            otherItems.removeValue(forKey: device)
            pagesOnDisk.insert(page.record.id)
            guard let index = pageIndex(page.record.id) else {
                // A page another device added.
                pages.append(Page(record: page.record, ownInk: page.inks[device] ?? DeviceInk(), otherInks: others,
                                  ownItems: page.items[device] ?? DeviceItems(), otherItems: otherItems, isSaved: true))
                pagesChanged = true
                continue
            }
            var changed = false
            if pages[index].otherInks != others || pages[index].otherItems != otherItems {
                pages[index].otherInks = others
                pages[index].otherItems = otherItems
                pages[index].refreshVisibleStrokes()
                changed = true
            }
            if !pageRecordsToSave.contains(page.record.id), pages[index].isSaved, page.record != pages[index].record {
                if page.record.sortKey != pages[index].record.sortKey { pagesChanged = true }
                pages[index].record = page.record
                pages[index].revision += 1
                changed = true
            }
            if changed { redraw.append(page.record.id) }
        }
        // Pages another device deleted.
        let deleted = pages.filter { pagesOnDisk.contains($0.id) && !loadedIDs.contains($0.id) }.map(\.id)
        if !deleted.isEmpty {
            pages.removeAll { deleted.contains($0.id) }
            pagesOnDisk.subtract(deleted)
            pagesChanged = true
        }
        if pagesChanged {
            // Saved pages in order; the blank last page (not saved yet) stays last.
            let saved = pages.filter(\.isSaved).sorted { ($0.record.sortKey, $0.id.uuidString) < ($1.record.sortKey, $1.id.uuidString) }
            pages = saved + pages.filter { !$0.isSaved }
            _ = normalizeTrailingPages()
            onChange?(.pagesChanged)
        }
        for pageID in redraw where pageIndex(pageID) != nil {
            onChange?(.pageRedraw(pageID: pageID))
        }
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
            let failed: Bool
            do {
                // The note may have been renamed or moved on another device since.
                guard let noteURL = location.resolved() else { throw CocoaError(.fileNoSuchFile) }
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
                if var note {
                    // Favorites are set from the library, maybe on another device: keep its choice.
                    if let saved = try? folder.loadRecord(ofNoteAt: noteURL) {
                        note.favoritedAt = saved.favoritedAt
                    }
                    try folder.save(note, at: noteURL)
                }
                failed = false
            } catch {
                Self.logger.error("Saving \(location.url.lastPathComponent) failed: \(error)")
                failed = true
            }
            Task { @MainActor [weak self] in
                self?.saveDidFinish(failed: failed, records: records.map(\.id), inks: inks.map(\.0) + items.map(\.0))
            }
        }
    }

    private func saveDidFinish(failed: Bool, records: [UUID], inks: [UUID]) {
        saveFailed = failed
        guard failed else {
            pagesOnDisk.formUnion(records)
            return
        }
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
