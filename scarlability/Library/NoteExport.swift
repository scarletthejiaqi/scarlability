import Foundation
import ScarlabilityKit

/// Makes PDFs of notes, in the background after any saves already queued, as files ready to
/// share (in a temporary folder, named after the note).
enum NoteExport {
    struct Options: Sendable {
        /// Zero-based page indexes, or nil for every page. Only used for a single note.
        var pages: [Int]?
        var includePaper = true
    }

    /// One PDF of all the notes, one after another, in the order given.
    static func pdf(of notes: [NotebookFolder.StoredNote], named name: String, options: Options,
                    folder: NotebookFolder) async throws -> URL {
        let urls = notes.map(\.url)
        return try await NotesIO.run {
            var pages: [PageContent] = []
            for url in urls {
                let rendered = try folder.renderPages(inNoteAt: url)
                if let wanted = options.pages, urls.count == 1 {
                    pages += wanted.filter(rendered.indices.contains).map { rendered[$0] }
                } else {
                    pages += rendered
                }
            }
            return try write(PDFExport.data(pages: pages, includePaper: options.includePaper), named: name)
        }
    }

    /// One PDF per note.
    static func pdfs(of notes: [NotebookFolder.StoredNote], options: Options, folder: NotebookFolder) async throws -> [URL] {
        var files: [URL] = []
        for note in notes {
            files.append(try await pdf(of: [note], named: note.record.title, options: Options(includePaper: options.includePaper),
                                       folder: folder))
        }
        return files
    }

    nonisolated private static func write(_ data: Data, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "\(cleaned.isEmpty ? "Note" : cleaned).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
