import CoreGraphics
import Foundation
import Testing
@testable import ScarlabilityKit

struct LibraryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID().uuidString)")
    var folder: NotebookFolder { NotebookFolder(root: root, deviceID: UUID()) }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false)).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test func subjectsAndDividersAreFolders() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let divider = try folder.createDivider(named: "Spring 2026")
        let chemistry = try folder.createSubject(named: "Chemistry", color: InkColor.subjectColors[3], inDivider: divider)
        let biology = try folder.createSubject(named: "Biology", color: InkColor.subjectColors[0])
        _ = try folder.createNote(title: "Lab", inSubject: chemistry)
        _ = try folder.createNote(title: "Lecture 1", inSubject: biology)
        _ = try folder.createNote(title: "Loose", inSubject: nil)

        #expect(try names(in: root) == ["Biology", "Loose.scarnote", "Spring 2026"])
        #expect(try names(in: root.appending(path: "Spring 2026/Chemistry")) == ["Lab.scarnote"])

        let library = try folder.loadLibrary()
        #expect(library.unfiled.map(\.record.title) == ["Loose"])
        #expect(library.subjects.map(\.name) == ["Biology"])
        #expect(library.subjects[0].color == InkColor.subjectColors[0])
        #expect(library.dividers.map(\.name) == ["Spring 2026"])
        #expect(library.dividers[0].subjects.map(\.id) == ["Spring 2026/Chemistry"])
        #expect(library.allNotes.count == 3)
    }

    @Test func plainFoldersMadeInFilesAreSubjects() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "Made In Files"), withIntermediateDirectories: true)
        let library = try folder.loadLibrary()
        #expect(library.subjects.map(\.name) == ["Made In Files"])
    }

    @Test func renameMoveAndDuplicateNotes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let biology = try folder.createSubject(named: "Biology", color: .black)
        let note = try folder.createNote(title: "Note Oct 9", inSubject: nil)

        let renamed = try folder.renameNote(at: note.url, to: "Cells")
        #expect(renamed.lastPathComponent == "Cells.scarnote")
        #expect(try folder.renameNote(at: renamed, to: "Cells") == renamed)

        let moved = try folder.moveNote(at: renamed, toSubject: biology)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Biology")

        let copy = try folder.duplicateNote(at: moved)
        #expect(copy.record.title == "Cells copy")
        #expect(copy.record.id != note.record.id)

        let library = try folder.loadLibrary()
        #expect(Set(library.subjects[0].notes.map(\.record.title)) == ["Cells", "Cells copy"])
        #expect(library.unfiled.isEmpty)
    }

    @Test func deleteRestoreAndPurge() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let biology = try folder.createSubject(named: "Biology", color: .black)
        let note = try folder.createNote(title: "Cells", inSubject: biology)

        try folder.deleteNote(at: note.url)
        var library = try folder.loadLibrary()
        #expect(library.subjects[0].notes.isEmpty)
        #expect(library.recentlyDeleted.map(\.record.deletedFrom) == ["Biology"])

        let restored = try folder.restoreNote(at: library.recentlyDeleted[0].url)
        #expect(restored.deletingLastPathComponent().lastPathComponent == "Biology")
        library = try folder.loadLibrary()
        #expect(library.subjects[0].notes.first?.record.deletedAt == nil)

        // Deleted 31 days ago: purged. Deleted just now: kept.
        try folder.deleteNote(at: restored)
        try folder.purgeRecentlyDeleted(now: Date().addingTimeInterval(29 * 24 * 3600))
        #expect(try folder.loadLibrary().recentlyDeleted.count == 1)
        try folder.purgeRecentlyDeleted(now: Date().addingTimeInterval(31 * 24 * 3600))
        #expect(try folder.loadLibrary().recentlyDeleted.isEmpty)
    }

    @Test func deletingASubjectSendsItsNotesToRecentlyDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let divider = try folder.createDivider(named: "Spring")
        let chemistry = try folder.createSubject(named: "Chemistry", color: .black, inDivider: divider)
        _ = try folder.createNote(title: "Lab 1", inSubject: chemistry)
        _ = try folder.createNote(title: "Lab 2", inSubject: chemistry)

        try folder.deleteDivider(divider)
        let library = try folder.loadLibrary()
        #expect(library.dividers.isEmpty)
        #expect(Set(library.recentlyDeleted.map(\.record.title)) == ["Lab 1", "Lab 2"])
        // The subject is gone, so restoring puts the note in Unfiled.
        _ = try folder.restoreNote(at: library.recentlyDeleted[0].url)
        #expect(try folder.loadLibrary().unfiled.count == 1)
    }

    @Test func renameAndMoveSubjects() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let divider = try folder.createDivider(named: "Spring")
        let id = try folder.createSubject(named: "Bio", color: .black)
        _ = try folder.createNote(title: "Cells", inSubject: id)
        let renamed = try folder.renameFolder(id, to: "Biology")
        #expect(renamed == "Biology")
        let moved = try folder.moveSubject(renamed, toDivider: divider)
        #expect(moved == "Spring/Biology")
        try folder.setColor(InkColor.subjectColors[5], ofSubject: moved)
        let library = try folder.loadLibrary()
        #expect(library.dividers[0].subjects.first?.color == InkColor.subjectColors[5])
        #expect(library.dividers[0].subjects.first?.notes.map(\.record.title) == ["Cells"])
    }

    @Test func favoritesAndDividerColorsAreSaved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let divider = try folder.createDivider(named: "Completed course")
        try folder.setColor(InkColor.subjectColors[1], ofDivider: divider)
        let note = try folder.createNote(title: "HW1", inSubject: nil)
        try folder.setFavorite(true, noteAt: note.url)

        var library = try folder.loadLibrary()
        #expect(library.dividers[0].color == InkColor.subjectColors[1])
        #expect(library.unfiled[0].record.isFavorite)
        // A copy starts out not a favorite.
        _ = try folder.duplicateNote(at: note.url)
        library = try folder.loadLibrary()
        #expect(library.unfiled.filter(\.record.isFavorite).map(\.record.title) == ["HW1"])

        try folder.setFavorite(false, noteAt: note.url)
        #expect(try folder.loadLibrary().unfiled.allSatisfy { !$0.record.isFavorite })
    }

    @Test func deletedPagesAreLeftOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try folder.createNote(title: "Pages", inSubject: nil)
        var first = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        let second = PageRecord(sortKey: 2, size: PageSize.a4, paper: .whiteLined)
        try folder.save(first, inNoteAt: note.url)
        try folder.save(second, inNoteAt: note.url)
        #expect(try folder.loadPages(inNoteAt: note.url).count == 2)
        first.deletedAt = Date()
        try folder.save(first, inNoteAt: note.url)
        #expect(try folder.loadPages(inNoteAt: note.url).map(\.record.id) == [second.id])
    }

    @Test func thumbnailHasThePageShape() throws {
        let content = PageContent(paper: .whiteLined, size: PageSize.a4, strokes: DemoInk.strokes().map(RenderedStroke.init))
        let image = try #require(Thumbnail.render(content, width: 150, scale: 2))
        #expect(image.width == 300)
        #expect(abs(Double(image.height) / Double(image.width) - PageSize.a4.height / PageSize.a4.width) < 0.01)
    }
}

struct SyncTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "SyncTests-\(UUID().uuidString)")
    let me = UUID(), other = UUID()
    var mine: NotebookFolder { NotebookFolder(root: root, deviceID: me) }
    var theirs: NotebookFolder { NotebookFolder(root: root, deviceID: other) }

    /// Saving on this device leaves the stamp alone; another device's ink changes it.
    @Test func noteStampOnlyChangesForOtherDevices() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try mine.createNote(title: "Shared", inSubject: nil)
        let page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        try mine.save(page, inNoteAt: note.url)
        let before = mine.changeStamp(inNoteAt: note.url)
        try mine.saveOwnInk(DeviceInk(strokes: DemoInk.strokes()), page: page.id, inNoteAt: note.url)
        #expect(mine.changeStamp(inNoteAt: note.url) == before)
        try theirs.saveOwnInk(DeviceInk(strokes: DemoInk.strokes()), page: page.id, inNoteAt: note.url)
        let afterInk = mine.changeStamp(inNoteAt: note.url)
        #expect(afterInk != before)
        // A page added on the other device changes it too.
        try theirs.save(PageRecord(sortKey: 2, size: PageSize.a4, paper: .whiteLined), inNoteAt: note.url)
        #expect(mine.changeStamp(inNoteAt: note.url) != afterInk)
    }

    @Test func libraryStampChangesWhenAnotherDeviceAddsANote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try mine.createSubject(named: "Math 185", color: .black)
        let before = mine.libraryStamp()
        #expect(mine.libraryStamp() == before)
        _ = try theirs.createNote(title: "From the Mac", inSubject: subject)
        #expect(mine.libraryStamp() != before)
    }

    /// A note renamed and moved on the other device is found again by its ID.
    @Test func findsAMovedNote() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = try mine.createSubject(named: "Bio", color: .black)
        let note = try mine.createNote(title: "Cells", inSubject: nil)
        let renamed = try theirs.renameNote(at: note.url, to: "Cell Biology")
        let moved = try theirs.moveNote(at: renamed, toSubject: subject)
        #expect(mine.findNote(id: note.record.id)?.standardizedFileURL == moved.standardizedFileURL)
        #expect(mine.findNote(id: UUID()) == nil)
    }

    /// Notes iCloud hasn't downloaded yet are counted (and their download is asked for).
    @Test func placeholdersAreCountedAsDownloading() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: ".Lecture 4.scarnote.icloud"))
        try Data().write(to: root.appending(path: ".photo.jpg.icloud"))
        #expect(try mine.loadLibrary().downloading == 1)
    }
}

struct CopiedPagesTests {
    @Test func pastedPagesAreIndependentCopies() throws {
        let strokes = DemoInk.strokes()
        let text = PageItem(kind: .text(TextContent(runs: [TextRun(text: "Hello")])), frame: CGRect(x: 10, y: 10, width: 100, height: 30))
        let picture = PageItem(kind: .image(ImageContent(fileName: "a.jpg")), frame: CGRect(x: 0, y: 100, width: 50, height: 50))
        let page = try CopiedPages.Page(size: PageSize.a4, paper: .whiteLined, background: .pdf(fileName: "s.pdf", pageIndex: 2),
                                        strokes: strokes, items: [text, picture])
        let copied = CopiedPages(pages: [page], files: ["a.jpg": Data([1]), "s.pdf": Data([2])])
        let decoded = try JSONDecoder().decode(CopiedPages.self, from: JSONEncoder().encode(copied))
        #expect(CopiedPages.fileNames(background: page.background, items: page.items) == ["a.jpg", "s.pdf"])

        let first = decoded.freshPages(), second = decoded.freshPages()
        #expect(first[0].ink.strokes.count == strokes.count)
        #expect(first[0].ink.strokes.map(\.points) == strokes.map(\.points))
        #expect(Set(first[0].ink.strokes.map(\.id)).isDisjoint(with: strokes.map(\.id)))
        #expect(first[0].record.id != second[0].record.id)
        #expect(first[0].items.items.map(\.id) != second[0].items.items.map(\.id))
        #expect(first[0].items.items.map(\.kind) == [text.kind, picture.kind])
        #expect(first[0].record.background == .pdf(fileName: "s.pdf", pageIndex: 2))
    }

    @Test func bookmarksAreSaved() throws {
        var page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        page.bookmarkedAt = Date()
        let decoded = try JSONDecoder().decode(PageRecord.self, from: JSONEncoder().encode(page))
        #expect(decoded.isBookmarked)
    }
}
