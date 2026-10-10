import CoreGraphics
import Foundation
import Observation
import ScarlabilityKit
import os

/// The library: folders (Subjects), folders that hold folders (Dividers) and notes, as folders
/// in the notes folder (see `LibraryLayout`).
@Observable
final class LibraryModel {
    enum Section: Hashable {
        case allNotes
        case recents
        case favorites
        case unfiled
        case subject(String)
        case recentlyDeleted

        /// The tabs under "Notes".
        static let noteTabs: [Section] = [.allNotes, .recents, .favorites, .unfiled]

        var isNoteTab: Bool { Self.noteTabs.contains(self) }

        var tabTitle: String {
            switch self {
            case .allNotes: "All Notes"
            case .recents: "Recents"
            case .favorites: "Favorites"
            case .unfiled: "Unfiled"
            case .subject: "Folder"
            case .recentlyDeleted: "Recently Deleted"
            }
        }
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
    /// When each note was last opened on this device, for Recents.
    private var openedAt: [UUID: Date] {
        didSet { UserDefaults.standard.set(openedAt.reduce(into: [String: Date]()) { $0[$1.key.uuidString] = $1.value }, forKey: Self.openedKey) }
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
    private static let openedKey = "notesOpenedAt"
    /// Recents shows notes opened or changed within this long.
    private static let recentsWindow: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let thumbnailWidth: CGFloat = 200

    init(folder: NotebookFolder) {
        self.folder = folder
        sort = UserDefaults.standard.string(forKey: Self.sortKey).flatMap(Sort.init(rawValue:)) ?? .modified
        collapsedDividers = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        let opened = UserDefaults.standard.dictionary(forKey: Self.openedKey) as? [String: Date] ?? [:]
        openedAt = opened.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    // MARK: - What's shown

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The notes in the selected section, sorted. While searching, every note whose title matches.
    var notes: [NotebookFolder.StoredNote] {
        var notes: [NotebookFolder.StoredNote]
        if isSearching {
            let query = searchText.trimmingCharacters(in: .whitespaces)
            notes = snapshot.allNotes.filter { $0.record.title.localizedCaseInsensitiveContains(query) }
        } else {
            switch section {
            case .allNotes: notes = snapshot.allNotes
            case .recents:
                let cutoff = Date().addingTimeInterval(-Self.recentsWindow)
                return snapshot.allNotes
                    .map { ($0, max(openedAt[$0.record.id] ?? .distantPast, $0.record.modifiedAt)) }
                    .filter { $0.1 > cutoff }
                    .sorted { $0.1 > $1.1 }
                    .map(\.0)
            case .favorites: notes = snapshot.allNotes.filter(\.record.isFavorite)
            case .unfiled: notes = snapshot.unfiled
            case .subject(let id): notes = snapshot.subject(id: id)?.notes ?? []
            case .recentlyDeleted: notes = snapshot.recentlyDeleted
            }
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
        if isSearching { return "Search" }
        switch section {
        case .subject(let id): return snapshot.subject(id: id)?.name ?? "Folder"
        case .recentlyDeleted: return "Recently Deleted"
        default: return "All Notes"
        }
    }

    /// Remembers that a note was opened, for Recents.
    func noteOpened(_ note: NotebookFolder.StoredNote) {
        openedAt[note.record.id] = Date()
        // Forget notes not opened in a long time, so the list doesn't grow forever.
        let cutoff = Date().addingTimeInterval(-Self.recentsWindow)
        openedAt = openedAt.filter { $0.value > cutoff }
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

    func createDivider(named name: String, color: InkColor) async {
        await perform("create the folder") { try $0.createDivider(named: name, color: color) }
    }

    func setColor(_ color: InkColor, ofDivider id: String) async {
        await perform("change the color") { try $0.setColor(color, ofDivider: id) }
    }

    func setFavorite(_ isFavorite: Bool, _ notes: [NotebookFolder.StoredNote]) async {
        let urls = notes.map(\.url)
        await perform(isFavorite ? "add to Favorites" : "remove from Favorites") { folder in
            for url in urls { try folder.setFavorite(isFavorite, noteAt: url) }
        }
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
    /// Launch with `-SeedLibrary` (and an empty library) to get demo folders, a folder group and notes.
    func seedDemoLibraryIfEmpty() async {
        guard snapshot.allNotes.isEmpty, snapshot.allSubjects.isEmpty else { return }
        await perform("seed") { folder in
            let colors = InkColor.subjectColors
            let finance = try folder.createSubject(named: "FINM 330", color: colors[2])
            let math = try folder.createSubject(named: "Math 185", color: colors[0])
            let completed = try folder.createDivider(named: "Completed course")
            let analysis = try folder.createSubject(named: "Math 211", color: colors[1], inDivider: completed)
            _ = try folder.createSubject(named: "STAT 24500", color: colors[3], inDivider: completed)
            _ = try folder.createSubject(named: "ECON 20100", color: colors[6], inDivider: completed)
            let notes: [(String, String?)] = [("FINM 330 HW1", finance), ("MATH 185 HW1", math), ("Lecture 3", math),
                                              ("Proofs", analysis), ("Groceries", nil)]
            for (title, subject) in notes {
                let note = try folder.createNote(title: title, inSubject: subject)
                let page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
                try folder.save(page, inNoteAt: note.url)
                try folder.saveOwnInk(DeviceInk(strokes: DemoInk.strokes()), page: page.id, inNoteAt: note.url)
                if title == "FINM 330 HW1" {
                    try folder.setFavorite(true, noteAt: note.url)
                }
            }
        }
    }
    #endif
}
