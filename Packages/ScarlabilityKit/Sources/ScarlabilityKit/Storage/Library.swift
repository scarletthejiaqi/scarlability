import Foundation

/// The library, stored as folders the Files app shows the same way the app does:
///
///     Scarlability/
///       Test Note.scarnote              ← Unfiled
///       Biology/                        ← a Subject on its own   (has .subject.json)
///         Lecture 1.scarnote
///       Spring 2026/                    ← a Divider               (has .divider.json)
///         Chemistry/                    ← a Subject in it         (has .subject.json)
///           Lab.scarnote
///       Recently Deleted/
///         Lecture 2.scarnote            ← Note.json says when and where from
///
/// Names are the folder names. The hidden files keep the rest (color, order). A folder without
/// one is treated as a Subject, so folders made in the Files app show up too.
public enum LibraryLayout {
    public static let recentlyDeletedName = "Recently Deleted"
    static let subjectMarker = ".subject.json"
    static let dividerMarker = ".divider.json"
    /// How long notes stay in Recently Deleted.
    public static let keepDeletedFor: TimeInterval = 30 * 24 * 60 * 60
}

extension NotebookFolder {
    public struct Subject: Identifiable, Sendable, Hashable {
        /// The folder path relative to the notes folder, e.g. "Spring 2026/Chemistry".
        public var id: String
        public var name: String
        public var url: URL
        public var color: InkColor
        public var sortIndex: Double
        public var notes: [StoredNote]

        public static func == (a: Subject, b: Subject) -> Bool { a.id == b.id && a.name == b.name && a.color == b.color && a.notes.map(\.record) == b.notes.map(\.record) }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    public struct Divider: Identifiable, Sendable, Hashable {
        /// The folder name.
        public var id: String
        public var name: String
        public var url: URL
        public var sortIndex: Double
        public var subjects: [Subject]

        public static func == (a: Divider, b: Divider) -> Bool { a.id == b.id && a.name == b.name && a.subjects == b.subjects }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Everything in the library.
    public struct LibrarySnapshot: Sendable {
        public var unfiled: [StoredNote] = []
        /// Subjects not in a divider.
        public var subjects: [Subject] = []
        public var dividers: [Divider] = []
        public var recentlyDeleted: [StoredNote] = []

        public init() {}

        public var allSubjects: [Subject] { subjects + dividers.flatMap(\.subjects) }

        /// Every note that isn't deleted.
        public var allNotes: [StoredNote] { unfiled + allSubjects.flatMap(\.notes) }

        public func subject(id: String) -> Subject? { allSubjects.first { $0.id == id } }

        /// The subject a note is in (nil for Unfiled).
        public func subject(containing noteURL: URL) -> Subject? {
            allSubjects.first { subject in subject.notes.contains { $0.url == noteURL } }
        }
    }

    private struct SubjectMarker: Codable {
        var color: InkColor
        var sortIndex: Double
    }

    private struct DividerMarker: Codable {
        var sortIndex: Double
    }

    // MARK: - Reading

    public func loadLibrary() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot()
        snapshot.unfiled = notes(in: root)
        for folder in try subdirectories(of: root) where folder.pathExtension != Self.noteExtension {
            let name = folder.lastPathComponent
            if name == LibraryLayout.recentlyDeletedName {
                snapshot.recentlyDeleted = notes(in: folder)
            } else if let marker = try? decodeJSON(DividerMarker.self, from: folder.appending(path: LibraryLayout.dividerMarker)) {
                let subjects = try subdirectories(of: folder)
                    .filter { $0.pathExtension != Self.noteExtension }
                    .map { subject(at: $0, id: "\(name)/\($0.lastPathComponent)") }
                    .sorted(by: Self.subjectOrder)
                snapshot.dividers.append(Divider(id: name, name: name, url: folder, sortIndex: marker.sortIndex, subjects: subjects))
            } else {
                snapshot.subjects.append(subject(at: folder, id: name))
            }
        }
        snapshot.subjects.sort(by: Self.subjectOrder)
        snapshot.dividers.sort { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
        return snapshot
    }

    private static func subjectOrder(_ a: Subject, _ b: Subject) -> Bool {
        (a.sortIndex, a.name.localizedLowercase) < (b.sortIndex, b.name.localizedLowercase)
    }

    private func subject(at folder: URL, id: String) -> Subject {
        let marker = try? decodeJSON(SubjectMarker.self, from: folder.appending(path: LibraryLayout.subjectMarker))
        return Subject(id: id, name: folder.lastPathComponent, url: folder, color: marker?.color ?? InkColor.subjectColors.last!,
                       sortIndex: marker?.sortIndex ?? .greatestFiniteMagnitude, notes: notes(in: folder))
    }

    private func notes(in folder: URL) -> [StoredNote] {
        ((try? contents(of: folder)) ?? [])
            .filter { $0.pathExtension == Self.noteExtension }
            .compactMap { url in
                guard let record = try? decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json")) else { return nil }
                return StoredNote(url: url, record: record)
            }
    }

    private func folderURL(forSubject id: String?) -> URL {
        guard let id else { return root }
        return root.appending(path: id, directoryHint: .isDirectory)
    }

    // MARK: - Subjects and dividers

    /// Creates a subject, on its own or in a divider. Returns its ID.
    @discardableResult
    public func createSubject(named name: String, color: InkColor, inDivider divider: String? = nil) throws -> String {
        let parent = divider.map { root.appending(path: $0, directoryHint: .isDirectory) } ?? root
        let url = availableURL(for: name, in: parent, pathExtension: nil)
        try writeJSON(SubjectMarker(color: color, sortIndex: Date().timeIntervalSinceReferenceDate), to: url.appending(path: LibraryLayout.subjectMarker))
        return divider.map { "\($0)/\(url.lastPathComponent)" } ?? url.lastPathComponent
    }

    @discardableResult
    public func createDivider(named name: String) throws -> String {
        let url = availableURL(for: name, in: root, pathExtension: nil)
        try writeJSON(DividerMarker(sortIndex: Date().timeIntervalSinceReferenceDate), to: url.appending(path: LibraryLayout.dividerMarker))
        return url.lastPathComponent
    }

    public func setColor(_ color: InkColor, ofSubject id: String) throws {
        let markerURL = folderURL(forSubject: id).appending(path: LibraryLayout.subjectMarker)
        let sortIndex = (try? decodeJSON(SubjectMarker.self, from: markerURL))?.sortIndex ?? Date().timeIntervalSinceReferenceDate
        try writeJSON(SubjectMarker(color: color, sortIndex: sortIndex), to: markerURL)
    }

    /// Renames a subject or divider folder (`id` is its path). Returns the new ID.
    @discardableResult
    public func renameFolder(_ id: String, to name: String) throws -> String {
        let url = root.appending(path: id, directoryHint: .isDirectory)
        let parent = url.deletingLastPathComponent()
        guard name != url.lastPathComponent else { return id }
        let destination = availableURL(for: name, in: parent, pathExtension: nil)
        try coordinatedMove(from: url, to: destination)
        let parentPath = id.split(separator: "/").dropLast().joined(separator: "/")
        return parentPath.isEmpty ? destination.lastPathComponent : "\(parentPath)/\(destination.lastPathComponent)"
    }

    /// Moves a subject into a divider, or out of one (nil). Returns the new ID.
    @discardableResult
    public func moveSubject(_ id: String, toDivider divider: String?) throws -> String {
        let url = folderURL(forSubject: id)
        let parent = divider.map { root.appending(path: $0, directoryHint: .isDirectory) } ?? root
        guard url.deletingLastPathComponent().standardizedFileURL != parent.standardizedFileURL else { return id }
        let destination = availableURL(for: url.lastPathComponent, in: parent, pathExtension: nil)
        try coordinatedMove(from: url, to: destination)
        return divider.map { "\($0)/\(destination.lastPathComponent)" } ?? destination.lastPathComponent
    }

    /// Deletes a subject; its notes go to Recently Deleted.
    public func deleteSubject(_ id: String) throws {
        let url = folderURL(forSubject: id)
        for note in notes(in: url) {
            try deleteNote(at: note.url)
        }
        try coordinatedDelete(url)
    }

    /// Deletes a divider and its subjects; all their notes go to Recently Deleted.
    public func deleteDivider(_ id: String) throws {
        let url = root.appending(path: id, directoryHint: .isDirectory)
        for subject in try subdirectories(of: url) where subject.pathExtension != Self.noteExtension {
            try deleteSubject("\(id)/\(subject.lastPathComponent)")
        }
        // Notes sitting directly in a divider folder (e.g. put there in the Files app).
        for note in notes(in: url) {
            try deleteNote(at: note.url)
        }
        try coordinatedDelete(url)
    }

    // MARK: - Notes

    /// Creates a note in a subject (or Unfiled, for nil).
    public func createNote(title: String, inSubject subject: String?) throws -> StoredNote {
        try createNote(title: title, in: folderURL(forSubject: subject))
    }

    /// Renames a note: its title, and its package so Files shows the new name. Returns the new URL.
    @discardableResult
    public func renameNote(at url: URL, to title: String) throws -> URL {
        var record = try decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json"))
        record.title = title
        record.modifiedAt = Date()
        try save(record, at: url)
        // Already named that (the package name is free for it, being its own).
        guard Self.fileName(for: title) != url.deletingPathExtension().lastPathComponent else { return url }
        let wanted = availableURL(for: title, in: url.deletingLastPathComponent(), pathExtension: Self.noteExtension)
        try coordinatedMove(from: url, to: wanted)
        return wanted
    }

    /// Moves a note into a subject (or Unfiled, for nil). Returns the new URL.
    @discardableResult
    public func moveNote(at url: URL, toSubject subject: String?) throws -> URL {
        let folder = folderURL(forSubject: subject)
        guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return url }
        let destination = availableURL(for: url.deletingPathExtension().lastPathComponent, in: folder, pathExtension: Self.noteExtension)
        try coordinatedMove(from: url, to: destination)
        return destination
    }

    /// Copies a note next to the original, as a new note titled "… copy".
    public func duplicateNote(at url: URL) throws -> StoredNote {
        var record = try decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json"))
        let destination = availableURL(for: "\(record.title) copy", in: url.deletingLastPathComponent(), pathExtension: Self.noteExtension)
        try coordinatedCopy(from: url, to: destination)
        record.id = UUID()
        record.title = "\(record.title) copy"
        record.createdAt = Date()
        record.modifiedAt = Date()
        try save(record, at: destination)
        return StoredNote(url: destination, record: record)
    }

    /// Moves a note to Recently Deleted, remembering where it came from.
    public func deleteNote(at url: URL) throws {
        var record = try decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json"))
        let from = url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        record.deletedFrom = from.count > rootPath.count && from.hasPrefix(rootPath)
            ? String(from.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : nil
        record.deletedAt = Date()
        try save(record, at: url)
        let trash = root.appending(path: LibraryLayout.recentlyDeletedName, directoryHint: .isDirectory)
        let destination = availableURL(for: url.deletingPathExtension().lastPathComponent, in: trash, pathExtension: Self.noteExtension)
        try coordinatedMove(from: url, to: destination)
    }

    /// Puts a deleted note back where it was (or Unfiled, if that subject is gone). Returns the new URL.
    @discardableResult
    public func restoreNote(at url: URL) throws -> URL {
        var record = try decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json"))
        var folder = folderURL(forSubject: record.deletedFrom)
        if !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = root
        }
        record.deletedAt = nil
        record.deletedFrom = nil
        try save(record, at: url)
        let destination = availableURL(for: url.deletingPathExtension().lastPathComponent, in: folder, pathExtension: Self.noteExtension)
        try coordinatedMove(from: url, to: destination)
        return destination
    }

    public func deleteNoteForever(at url: URL) throws {
        try coordinatedDelete(url)
    }

    /// Removes notes that have been in Recently Deleted longer than 30 days.
    public func purgeRecentlyDeleted(now: Date = Date()) throws {
        let trash = root.appending(path: LibraryLayout.recentlyDeletedName, directoryHint: .isDirectory)
        for note in notes(in: trash) {
            if let deletedAt = note.record.deletedAt, now.timeIntervalSince(deletedAt) > LibraryLayout.keepDeletedFor {
                try coordinatedDelete(note.url)
            }
        }
    }

    // MARK: - Coordinated moves, copies and deletes

    func coordinatedMove(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    func coordinatedCopy(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                                         options: .forReplacing, error: &coordinationError) { from, to in
            do {
                try FileManager.default.copyItem(at: from, to: to)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }
}

extension InkColor {
    /// The colors a subject can have.
    public static let subjectColors: [InkColor] = [
        InkColor(hex: 0xE5484D), // red
        InkColor(hex: 0xF76B15), // orange
        InkColor(hex: 0xF5B800), // yellow
        InkColor(hex: 0x30A46C), // green
        InkColor(hex: 0x12A594), // teal
        InkColor(hex: 0x0090FF), // blue
        InkColor(hex: 0x8E4EC6), // purple
        InkColor(hex: 0x8B8D98), // gray
    ]
}
