import Foundation

/// Reads and writes notes in the app's notes folder (normally `iCloud Drive/Scarlability`).
///
/// Each note is one `.scarnote` package, a folder that the Files app and Finder show as a single
/// item named after the note:
///
///     Scarlability/
///       Test Note.scarnote/
///         Note.json
///         Pages/<pageID>/Page.json
///         Pages/<pageID>/<deviceID>.ink
///
/// Notes at the top level are Unfiled; Divider and Subject folders arrive with the library (M3).
/// Every access is file-coordinated, because iCloud Drive may be updating the same files.
/// Methods block, so call them off the main thread.
public struct NotebookFolder: Sendable {
    public static let noteExtension = "scarnote"

    public let root: URL
    /// This device's ID; it only ever writes `.ink` files named after it.
    public let deviceID: UUID

    public init(root: URL, deviceID: UUID) {
        self.root = root
        self.deviceID = deviceID
    }

    public struct StoredNote: Sendable, Identifiable, Hashable {
        /// The note's package.
        public var url: URL
        public var record: NoteRecord

        public var id: URL { url }
    }

    public struct LoadedPage: Sendable {
        public var record: PageRecord
        /// Each device's ink for this page, keyed by device ID.
        public var inks: [UUID: DeviceInk]
        /// Each device's text boxes and images for this page, keyed by device ID.
        public var items: [UUID: DeviceItems] = [:]
    }

    // MARK: - Notes

    public func loadNotes() throws -> [StoredNote] {
        try contents(of: root)
            .filter { $0.pathExtension == Self.noteExtension }
            .compactMap { url in
                guard let record = try? decodeJSON(NoteRecord.self, from: url.appending(path: "Note.json")) else { return nil }
                return StoredNote(url: url, record: record)
            }
    }

    /// Creates a new note package named after `title` in `directory` (the top level, i.e. Unfiled,
    /// by default), adding " 2", " 3"… if that name is taken.
    public func createNote(title: String, in directory: URL? = nil) throws -> StoredNote {
        let record = NoteRecord(title: title)
        let url = availableURL(for: title, in: directory ?? root, pathExtension: Self.noteExtension)
        try save(record, at: url)
        return StoredNote(url: url, record: record)
    }

    /// Loads just the first page, for thumbnails.
    public func loadFirstPage(inNoteAt noteURL: URL) -> LoadedPage? {
        try? loadPages(inNoteAt: noteURL).first
    }

    public func save(_ record: NoteRecord, at noteURL: URL) throws {
        try writeJSON(record, to: noteURL.appending(path: "Note.json"))
    }

    // MARK: - Pages

    /// Loads a note's pages in order, with every device's ink. Deleted pages are left out.
    public func loadPages(inNoteAt noteURL: URL) throws -> [LoadedPage] {
        var pages: [LoadedPage] = []
        for directory in try subdirectories(of: pagesDirectory(noteURL)) {
            guard let record = try? decodeJSON(PageRecord.self, from: directory.appending(path: "Page.json")),
                  record.deletedAt == nil else {
                continue
            }
            var inks: [UUID: DeviceInk] = [:]
            var items: [UUID: DeviceItems] = [:]
            for file in try contents(of: directory) where file.lastPathComponent.hasSuffix(".items.json") {
                guard let device = UUID(uuidString: String(file.lastPathComponent.dropLast(".items.json".count))) else { continue }
                do {
                    items[device] = try decodeJSON(DeviceItems.self, from: file)
                } catch where device != deviceID {
                    continue
                }
            }
            for file in try contents(of: directory) where file.pathExtension == "ink" {
                guard let device = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    let data = try coordinatedRead(file) { try Data(contentsOf: $0) }
                    inks[device] = try InkCodec.decode(data)
                } catch where device != deviceID {
                    // Another device's file we can't read yet (still downloading, or from a newer
                    // app version). Skip it; this device never writes to it, so nothing is lost.
                    // Errors on this device's own file are thrown instead: opening the page
                    // without it would later overwrite it.
                    continue
                }
            }
            pages.append(LoadedPage(record: record, inks: inks, items: items))
        }
        return pages.sorted { ($0.record.sortKey, $0.record.id.uuidString) < ($1.record.sortKey, $1.record.id.uuidString) }
    }

    public func save(_ page: PageRecord, inNoteAt noteURL: URL) throws {
        try writeJSON(page, to: pageDirectory(noteURL, page.id).appending(path: "Page.json"))
    }

    public func saveOwnInk(_ ink: DeviceInk, page pageID: UUID, inNoteAt noteURL: URL) throws {
        let data = try InkCodec.encode(ink)
        try coordinatedWrite(to: pageDirectory(noteURL, pageID).appending(path: "\(deviceID.uuidString).ink"), data: data)
    }

    public func saveOwnItems(_ items: DeviceItems, page pageID: UUID, inNoteAt noteURL: URL) throws {
        try writeJSON(items, to: pageDirectory(noteURL, pageID).appending(path: "\(deviceID.uuidString).items.json"))
    }

    // MARK: - Images

    /// Saves an image into the note package's Images folder.
    public func saveImage(_ data: Data, named fileName: String, inNoteAt noteURL: URL) throws {
        try coordinatedWrite(to: noteURL.appending(path: "Images/\(fileName)"), data: data)
    }

    public func loadImageData(named fileName: String, inNoteAt noteURL: URL) -> Data? {
        let url = noteURL.appending(path: "Images/\(fileName)")
        return try? coordinatedRead(url) { try Data(contentsOf: $0) }
    }

    // MARK: - Layout

    func pagesDirectory(_ noteURL: URL) -> URL {
        noteURL.appending(path: "Pages", directoryHint: .isDirectory)
    }

    private func pageDirectory(_ noteURL: URL, _ pageID: UUID) -> URL {
        pagesDirectory(noteURL).appending(path: pageID.uuidString, directoryHint: .isDirectory)
    }

    /// A file name made from `name` that's free in `directory` (adding " 2", " 3"… if needed).
    func availableURL(for name: String, in directory: URL, pathExtension: String?) -> URL {
        let base = Self.fileName(for: name)
        func url(_ candidate: String) -> URL {
            let file = pathExtension.map { "\(candidate).\($0)" } ?? candidate
            return directory.appending(path: file, directoryHint: .isDirectory)
        }
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: url(candidate).path(percentEncoded: false)) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return url(candidate)
    }

    /// A name that's safe as a file name: no slashes or colons, not hidden.
    static func fileName(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Untitled" : cleaned
    }

    // MARK: - Coordinated file access

    // Dates use Foundation's default encoding (seconds since 2001), which round-trips exactly.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try coordinatedRead(url) { try Data(contentsOf: $0) }
        return try Self.decoder.decode(type, from: data)
    }

    func writeJSON(_ value: some Encodable, to url: URL) throws {
        try coordinatedWrite(to: url, data: try Self.encoder.encode(value))
    }

    func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    func coordinatedWrite(to url: URL, data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    func contents(of directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    func subdirectories(of directory: URL) throws -> [URL] {
        try contents(of: directory).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
