import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import ScarlabilityKit

struct PDFTests {
    /// A two-page Letter PDF, each page with a line of text at (72, 100) from the top-left.
    static func samplePDF(text: String = "Hello highlighter world") -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<2 {
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            context.textPosition = CGPoint(x: 72, y: 792 - 100)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @Test func opensPagesAtTheirSize() throws {
        let file = try #require(PDFFile(data: Self.samplePDF()))
        #expect(file.pageCount == 2)
        #expect(file.page(at: 0)?.size == CGSize(width: 612, height: 792))
        #expect(file.page(at: 2) == nil)
        #expect(PDFFile(data: Data("not a pdf".utf8)) == nil)
    }

    @Test func drawsThePDFUnderThePage() throws {
        let file = try #require(PDFFile(data: Self.samplePDF()))
        let background = try #require(file.page(at: 0))
        let content = PageContent(paper: PaperStyle(template: .blank, color: .white), size: background.size, strokes: [],
                                  backgroundPDF: background)
        let image = try #require(Thumbnail.render(content, width: 612, scale: 1))
        // The text sits about 100 points from the top, starting 72 points in; somewhere along
        // there it's dark, and well below it the page is white.
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        func brightness(_ x: Int, _ yFromTop: Int) -> Int {
            let offset = (yFromTop * image.width + x) * 4
            return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
        }
        let darkest = (72..<300).flatMap { x in (85..<100).map { brightness(x, $0) } }.min()!
        #expect(darkest < 200)
        #expect(brightness(300, 400) == 765)
    }

    @Test func highlighterSnapsToTheTextLine() throws {
        let data = Self.samplePDF()
        let file = try #require(PDFFile(data: data))
        let background = try #require(file.page(at: 0))
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let lines = PDFTextSnap.lineRects(on: page, background: background, pageSize: background.size,
                                          from: CGPoint(x: 70, y: 92), to: CGPoint(x: 330, y: 93))
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        // Covers the text line (24 pt Helvetica, baseline 100 points from the top).
        #expect(line.minY < 85 && line.maxY > 98 && line.minX < 80 && line.maxX > 250)
        #expect(!PDFTextSnap.highlightPoints(for: line).isEmpty)

        let blank = PDFTextSnap.lineRects(on: page, background: background, pageSize: background.size,
                                          from: CGPoint(x: 70, y: 500), to: CGPoint(x: 330, y: 500))
        #expect(blank.isEmpty)
    }

    @Test func pageRanges() {
        #expect(PageRange.parse("1-3, 5", pageCount: 6) == [0, 1, 2, 4])
        #expect(PageRange.parse("4-", pageCount: 6) == [3, 4, 5])
        #expect(PageRange.parse(" 2 ,2, 1", pageCount: 3) == [1, 0])
        #expect(PageRange.parse("0", pageCount: 3) == nil)
        #expect(PageRange.parse("2-9", pageCount: 3) == nil)
        #expect(PageRange.parse("a", pageCount: 3) == nil)
        #expect(PageRange.parse("", pageCount: 3) == nil)
    }

    @Test func pdfBackgroundsAreSaved() throws {
        var page = PageRecord(sortKey: 1, size: CGSize(width: 612, height: 792), paper: .whiteLined)
        page.background = .pdf(fileName: "a.pdf", pageIndex: 3)
        let decoded = try JSONDecoder().decode(PageRecord.self, from: JSONEncoder().encode(page))
        #expect(decoded.background == .pdf(fileName: "a.pdf", pageIndex: 3))
    }

    /// Exported PDFs keep pages at their size, and imported PDF text stays real text.
    @Test func exportKeepsPagesAndText() throws {
        let file = try #require(PDFFile(data: Self.samplePDF(text: "Exported text stays text")))
        let pdfPage = try #require(file.page(at: 0))
        let ink = RenderedStroke(Stroke(color: .black, points: [InkPoint(x: 50, y: 50, width: 2), InkPoint(x: 200, y: 80, width: 2)]))
        let pages = [
            PageContent(paper: .whiteLined, size: PageSize.a4, strokes: [ink]),
            PageContent(paper: PaperStyle(template: .blank, color: .white), size: pdfPage.size, strokes: [], backgroundPDF: pdfPage),
        ]
        let exported = try #require(PDFDocument(data: PDFExport.data(pages: pages, includePaper: false)))
        #expect(exported.pageCount == 2)
        #expect(exported.page(at: 0)?.bounds(for: .mediaBox).size == PageSize.a4)
        #expect(exported.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(exported.page(at: 1)?.string?.contains("Exported text stays text") == true)
    }

    /// Like a real highlighter: black text under a highlight stays black.
    @Test func highlightsKeepTextUnderThemDark() throws {
        let file = try #require(PDFFile(data: Self.samplePDF(text: "████████")))
        let background = try #require(file.page(at: 0))
        let highlight = RenderedStroke(Stroke(tool: .highlighter, color: InkColor(hex: 0xF6FF00),
                                              points: [InkPoint(x: 60, y: 92, width: 30), InkPoint(x: 300, y: 92, width: 30)]))
        let content = PageContent(paper: PaperStyle(template: .blank, color: .white), size: background.size, strokes: [highlight],
                                  backgroundPDF: background)
        let image = try #require(Thumbnail.render(content, width: 612, scale: 1))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let darkest = (80..<200).flatMap { x in (85..<98).map { y -> Int in
            let offset = (y * image.width + x) * 4
            return Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
        } }.min()!
        #expect(darkest < 60)
    }
}

struct PDFNoteTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "PDFNoteTests-\(UUID().uuidString)")
    var folder: NotebookFolder { NotebookFolder(root: root, deviceID: UUID()) }

    @Test func importingAPDFMakesOnePagePerPDFPage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = PDFTests.samplePDF()
        let note = try #require(try folder.createNote(fromPDF: pdf, title: "Lecture Slides", inSubject: nil))
        let pages = try folder.loadPages(inNoteAt: note.url)
        #expect(pages.count == 2)
        #expect(pages.map(\.record.size) == [CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
        guard case .pdf(let fileName, let index)? = pages[1].record.background else {
            Issue.record("no PDF background")
            return
        }
        #expect(index == 1)
        #expect(folder.loadPDFData(named: fileName, inNoteAt: note.url) == pdf)
        #expect(try folder.createNote(fromPDF: Data("nope".utf8), title: "Bad", inSubject: nil) == nil)
    }

    @Test func savedNotesRenderWithEveryDevicesInk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(try folder.createNote(fromPDF: PDFTests.samplePDF(), title: "Slides", inSubject: nil))
        let page = try folder.loadPages(inNoteAt: note.url)[0].record
        let stroke = Stroke(color: .red, points: [InkPoint(x: 10, y: 10, width: 2), InkPoint(x: 90, y: 10, width: 2)])
        let other = NotebookFolder(root: root, deviceID: UUID())
        try other.saveOwnInk(DeviceInk(strokes: [stroke]), page: page.id, inNoteAt: note.url)
        let rendered = try folder.renderPages(inNoteAt: note.url)
        #expect(rendered.count == 2)
        #expect(rendered[0].strokes.map(\.stroke.id) == [stroke.id])
        #expect(rendered[0].backgroundPDF != nil)
    }
}
