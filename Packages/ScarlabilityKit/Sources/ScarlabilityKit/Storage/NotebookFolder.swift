import Foundation

/// Reads and writes notes in the folder the user picked (normally in iCloud Drive):
///
///     library/notes/<noteID>.json
///     notes/<noteID>/pages/<pageID>/page.json
///     notes/<noteID>/pages/<pageID>/<deviceID>.ink
///
/// Every access is file-coordinated, because iCloud Drive may be updating the same files.
/// Methods block, so call them off the main thread.
public struct NotebookFolder: Sendable {
    public let root: URL
    /// This device's ID; it only ever writes `.ink` files named after it.
    public let deviceID: UUID

    public init(root: URL, deviceID: UUID) {
        self.root = root
        self.deviceID = deviceID
    }

    public struct LoadedPage: Sendable {
        public var record: PageRecord
        /// Each device's ink for this page, keyed by device ID.
        public var inks: [UUID: DeviceInk]
    }

    // MARK: - Notes

    public func loadNotes() throws -> [NoteRecord] {
        try jsonFiles(in: notesIndexDirectory).compactMap { url in
            try? decodeJSON(NoteRecord.self, from: url)
        }
    }

    public func save(_ note: NoteRecord) throws {
        try writeJSON(note, to: notesIndexDirectory.appending(path: "\(note.id.uuidString).json"))
    }

    // MARK: - Pages

    /// Loads a note's pages in order, with every device's ink.
    public func loadPages(ofNote noteID: UUID) throws -> [LoadedPage] {
        let pagesDirectory = pagesDirectory(noteID)
        let pageDirectories = (try? subdirectories(of: pagesDirectory)) ?? []
        var pages: [LoadedPage] = []
        for directory in pageDirectories {
            guard let record = try? decodeJSON(PageRecord.self, from: directory.appending(path: "page.json")) else {
                continue
            }
            var inks: [UUID: DeviceInk] = [:]
            for file in try files(in: directory, withExtension: "ink") {
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
            pages.append(LoadedPage(record: record, inks: inks))
        }
        return pages.sorted { ($0.record.sortKey, $0.record.id.uuidString) < ($1.record.sortKey, $1.record.id.uuidString) }
    }

    public func save(_ page: PageRecord, inNote noteID: UUID) throws {
        try writeJSON(page, to: pageDirectory(noteID, page.id).appending(path: "page.json"))
    }

    public func saveOwnInk(_ ink: DeviceInk, page pageID: UUID, inNote noteID: UUID) throws {
        let data = try InkCodec.encode(ink)
        try coordinatedWrite(to: pageDirectory(noteID, pageID).appending(path: "\(deviceID.uuidString).ink"), data: data)
    }

    // MARK: - Layout

    private var notesIndexDirectory: URL { root.appending(path: "library/notes", directoryHint: .isDirectory) }

    private func pagesDirectory(_ noteID: UUID) -> URL {
        root.appending(path: "notes/\(noteID.uuidString)/pages", directoryHint: .isDirectory)
    }

    private func pageDirectory(_ noteID: UUID, _ pageID: UUID) -> URL {
        pagesDirectory(noteID).appending(path: pageID.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Coordinated file access

    // Dates use Foundation's default encoding (seconds since 2001), which round-trips exactly.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private func decodeJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try coordinatedRead(url) { try Data(contentsOf: $0) }
        return try Self.decoder.decode(type, from: data)
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        try coordinatedWrite(to: url, data: try Self.encoder.encode(value))
    }

    private func coordinatedRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func coordinatedWrite(to url: URL, data: Data) throws {
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

    private func contents(of directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    private func subdirectories(of directory: URL) throws -> [URL] {
        try contents(of: directory).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func files(in directory: URL, withExtension pathExtension: String) throws -> [URL] {
        try contents(of: directory).filter { $0.pathExtension == pathExtension }
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try files(in: directory, withExtension: "json")
    }
}
