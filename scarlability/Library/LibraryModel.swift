import CoreGraphics
import Foundation
import Observation
import ScarlabilityKit
import os

/// The library: Dividers, Subjects and notes, as folders in the notes folder (see `LibraryLayout`).
@Observable
final class LibraryModel {
    enum Section: Hashable {
        case allNotes
        case unfiled
        case subject(String)
        case recentlyDeleted
    }

    enum Sort: String, CaseIterable {
        case modified
        case created
        case title

        var label: String {
            switch self {
            case .modified: "Date Modified"
            case .created: "Date Created"
            case .title: "Title"
            }
        }
    }

    let folder: NotebookFolder
    private(set) var snapshot = NotebookFolder.LibrarySnapshot()
    var section: Section = .allNotes
    var sort: Sort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey) }
    }
    var searchText = ""
    /// Dividers folded closed in the sidebar (kept on this device).
    var collapsedDividers: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedDividers), forKey: Self.collapsedKey) }
    }
    /// Set when a library action fails, to show the user.
    var errorMessage: String?
    private(set) var thumbnails: [UUID: Thumb] = [:]

    struct Thumb {
        var modifiedAt: Date
        var image: CGImage
    }

    @ObservationIgnored private var thumbnailsInProgress: Set<UUID> = []
    nonisolated private static let thumbnailQueue = DispatchQueue(label: "scarlability.thumbnails", qos: .utility)
    nonisolated private static let logger = Logger(subsystem: "scarlability", category: "Library")
    private static let sortKey = "librarySort"
    private static let collapsedKey = "collapsedDividers"
    nonisolated static let thumbnailWidth: CGFloat = 200

    init(folder: NotebookFolder) {
        self.folder = folder
        sort = UserDefaults.standard.string(forKey: Self.sortKey).flatMap(Sort.init(rawValue:)) ?? .modified
        collapsedDividers = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    // MARK: - What's shown

    /// The notes in the selected section, filtered by the search and sorted.
    var notes: [NotebookFolder.StoredNote] {
        var notes: [NotebookFolder.StoredNote]
        switch section {
        case .allNotes: notes = snapshot.allNotes
        case .unfiled: notes = snapshot.unfiled
        case .subject(let id): notes = snapshot.subject(id: id)?.notes ?? []
        case .recentlyDeleted: notes = snapshot.recentlyDeleted
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            notes = notes.filter { $0.record.title.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .modified: notes.sort { $0.record.modifiedAt > $1.record.modifiedAt }
        case .created: notes.sort { $0.record.createdAt > $1.record.createdAt }
        case .title: notes.sort { $0.record.title.localizedStandardCompare($1.record.title) == .orderedAscending }
        }
        if section == .recentlyDeleted {
            notes.sort { ($0.record.deletedAt ?? .distantPast) > ($1.record.deletedAt ?? .distantPast) }
        }
        return notes
    }

    var title: String {
        switch section {
        case .allNotes: "All Notes"
        case .unfiled: "Unfiled"
        case .subject(let id): snapshot.subject(id: id)?.name ?? "Subject"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    /// The subject new notes go into from this section (nil means Unfiled).
    private var currentSubject: String? {
        if case .subject(let id) = section { return id }
        return nil
    }

    // MARK: - Loading

    func reload() async {
        let folder = folder
        do {
            snapshot = try await NotesIO.run {
                try? folder.purgeRecentlyDeleted()
                return try folder.loadLibrary()
            }
            if case .subject(let id) = section, snapshot.subject(id: id) == nil {
                section = .allNotes
            }
        } catch {
            errorMessage = "Couldn't read your notes: \(error.localizedDescription)"
        }
    }

    /// Makes (in the background) a picture of the note's first page, if there isn't a current one.
    func requestThumbnail(for note: NotebookFolder.StoredNote) {
        let id = note.record.id, modifiedAt = note.record.modifiedAt
        guard thumbnails[id]?.modifiedAt != modifiedAt, !thumbnailsInProgress.contains(id) else { return }
        thumbnailsInProgress.insert(id)
        let folder = folder, record = note.record, url = note.url
        Self.thumbnailQueue.async {
            let page = folder.loadFirstPage(inNoteAt: url)
            let strokes = page.map { InkMerge.visibleStrokes(from: $0.inks.values) } ?? []
            func picture(_ fileName: String) -> CGImage? {
                folder.loadImageData(named: fileName, inNoteAt: url).flatMap { ImageLoading.cgImage(from: $0, maxPixelSize: 600) }
            }
            let items = (page.map { ItemMerge.visibleItems(from: $0.items.values) } ?? []).map { item in
                RenderedItem(item, image: item.image.flatMap { picture($0.fileName) })
            }
            var background: CGImage?
            if case .image(let fileName)? = page?.record.background {
                background = picture(fileName)
            }
            let content = PageContent(
                paper: page?.record.paper ?? record.defaultPaper,
                size: page?.record.size ?? record.defaultPageSize,
                strokes: strokes.map(RenderedStroke.init),
                items: items,
                backgroundImage: background
            )
            let image = Thumbnail.render(content, width: Self.thumbnailWidth, scale: 2)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thumbnailsInProgress.remove(id)
                if let image {
                    self.thumbnails[id] = Thumb(modifiedAt: modifiedAt, image: image)
                }
            }
        }
    }

    // MARK: - Actions

    /// Runs a file action, then reloads the library. Failures show as `errorMessage`.
    @discardableResult
    private func perform<T: Sendable>(_ what: String, _ work: @escaping @Sendable (NotebookFolder) throws -> T) async -> T? {
        let folder = folder
        do {
            let result = try await NotesIO.run { try work(folder) }
            await reload()
            return result
        } catch {
            Self.logger.error("\(what) failed: \(error)")
            errorMessage = "Couldn't \(what): \(error.localizedDescription)"
            await reload()
            return nil
        }
    }

    /// Creates a note in the current subject (or Unfiled), named after the date and time.
    func createNote() async -> NotebookFolder.StoredNote? {
        let now = Date()
        let title = "Note \(now.formatted(.dateTime.month(.abbreviated).day().year())) \(now.formatted(date: .omitted, time: .shortened))"
        let subject = currentSubject
        return await perform("create a note") { try $0.createNote(title: title, inSubject: subject) }
    }

    func createSubject(named name: String, color: InkColor, inDivider divider: String?) async {
        if let id = await perform("create the subject", { try $0.createSubject(named: name, color: color, inDivider: divider) }) {
            section = .subject(id)
        }
    }

    func createDivider(named name: String) async {
        await perform("create the divider") { try $0.createDivider(named: name) }
    }

    func renameFolder(_ id: String, to name: String) async {
        let wasSelected = section == .subject(id)
        if let newID = await perform("rename it", { try $0.renameFolder(id, to: name) }), wasSelected {
            section = .subject(newID)
        }
    }

    func renameDivider(_ id: String, to name: String) async {
        let collapsed = collapsedDividers.contains(id)
        if let newID = await perform("rename the divider", { try $0.renameFolder(id, to: name) }), collapsed {
            collapsedDividers.remove(id)
            collapsedDividers.insert(newID)
        }
    }

    func setColor(_ color: InkColor, ofSubject id: String) async {
        await perform("change the color") { try $0.setColor(color, ofSubject: id) }
    }

    func moveSubject(_ id: String, toDivider divider: String?) async {
        let wasSelected = section == .subject(id)
        if let newID = await perform("move the subject", { try $0.moveSubject(id, toDivider: divider) }), wasSelected {
            section = .subject(newID)
        }
    }

    func deleteSubject(_ id: String) async {
        await perform("delete the subject") { try $0.deleteSubject(id) }
    }

    func deleteDivider(_ id: String) async {
        await perform("delete the divider") { try $0.deleteDivider(id) }
    }

    func renameNote(_ note: NotebookFolder.StoredNote, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let url = note.url
        await perform("rename the note") { try $0.renameNote(at: url, to: title) }
    }

    func move(_ notes: [NotebookFolder.StoredNote], toSubject subject: String?) async {
        let urls = notes.map(\.url)
        await perform("move the notes") { folder in
            for url in urls { try folder.moveNote(at: url, toSubject: subject) }
        }
    }

    /// Moves notes dragged onto a subject (identified by their file paths).
    func moveDropped(_ paths: [String], toSubject subject: String?) async -> Bool {
        let notes = snapshot.allNotes.filter { paths.contains($0.url.path(percentEncoded: false)) }
        guard !notes.isEmpty else { return false }
        await move(notes, toSubject: subject)
        return true
    }

    func duplicate(_ note: NotebookFolder.StoredNote) async {
        let url = note.url
        await perform("duplicate the note") { try $0.duplicateNote(at: url) }
    }

    func delete(_ notes: [NotebookFolder.StoredNote]) async {
        let urls = notes.map(\.url)
        await perform("delete the notes") { folder in
            for url in urls { try folder.deleteNote(at: url) }
        }
    }

    func restore(_ notes: [NotebookFolder.StoredNote]) async {
        let urls = notes.map(\.url)
        await perform("restore the notes") { folder in
            for url in urls { try folder.restoreNote(at: url) }
        }
    }

    func deleteForever(_ notes: [NotebookFolder.StoredNote]) async {
        let urls = notes.map(\.url)
        await perform("delete the notes") { folder in
            for url in urls { try folder.deleteNoteForever(at: url) }
        }
    }

    func emptyRecentlyDeleted() async {
        await deleteForever(snapshot.recentlyDeleted)
    }

    #if DEBUG
    /// Launch with `-SeedLibrary` (and an empty library) to get demo dividers, subjects and notes.
    func seedDemoLibraryIfEmpty() async {
        guard snapshot.allNotes.isEmpty, snapshot.allSubjects.isEmpty else { return }
        await perform("seed") { folder in
            let spring = try folder.createDivider(named: "Spring 2026")
            let biology = try folder.createSubject(named: "Biology", color: InkColor.subjectColors[3], inDivider: spring)
            let chemistry = try folder.createSubject(named: "Chemistry", color: InkColor.subjectColors[5], inDivider: spring)
            let ideas = try folder.createSubject(named: "Ideas", color: InkColor.subjectColors[6])
            for (title, subject) in [("Cells", biology), ("Genetics", biology), ("Lab 1", chemistry), ("Sketches", ideas), ("Groceries", nil as String?)] {
                let note = try folder.createNote(title: title, inSubject: subject)
                let page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
                try folder.save(page, inNoteAt: note.url)
                try folder.saveOwnInk(DeviceInk(strokes: DemoInk.strokes()), page: page.id, inNoteAt: note.url)
            }
        }
    }
    #endif
}
