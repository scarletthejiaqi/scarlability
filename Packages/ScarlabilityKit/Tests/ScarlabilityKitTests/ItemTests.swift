import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ScarlabilityKit

struct ItemMergeTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func text(_ string: String, id: UUID, modified: Date) -> PageItem {
        PageItem(id: id, kind: .text(TextContent(runs: [TextRun(text: string)])), frame: CGRect(x: 0, y: 0, width: 50, height: 20),
                 createdAt: t0, modifiedAt: modified)
    }

    @Test func newestVersionWins() {
        let id = UUID()
        let ipad = DeviceItems(items: [text("old", id: id, modified: t0 + 1)])
        let mac = DeviceItems(items: [text("new", id: id, modified: t0 + 2)])
        #expect(ItemMerge.visibleItems(from: [ipad, mac]).map { $0.text?.plainText } == ["new"])
        #expect(ItemMerge.visibleItems(from: [mac, ipad]).map { $0.text?.plainText } == ["new"])
    }

    @Test func deletionOnlyBeatsOlderVersions() {
        let id = UUID()
        let ipad = DeviceItems(items: [text("hi", id: id, modified: t0 + 1)])
        let macDeletedLater = DeviceItems(deleted: [id: t0 + 2])
        #expect(ItemMerge.visibleItems(from: [ipad, macDeletedLater]).isEmpty)
        // Edited again after the delete (e.g. undo): it's back.
        let ipadEditedAgain = DeviceItems(items: [text("hi again", id: id, modified: t0 + 3)])
        #expect(ItemMerge.visibleItems(from: [ipadEditedAgain, macDeletedLater]).count == 1)
    }

    @Test func rotatedItemHitTesting() {
        var item = text("x", id: UUID(), modified: t0)
        item.frame = CGRect(x: 0, y: 0, width: 100, height: 10)
        #expect(item.contains(CGPoint(x: 90, y: 5)))
        item.rotation = .pi / 2
        // Turned upright around its center (50, 5): it now spans y -45…55 at x≈50.
        #expect(!item.contains(CGPoint(x: 90, y: 5)))
        #expect(item.contains(CGPoint(x: 50, y: 40)))
        #expect(abs(item.bounds.height - 100) < 0.01)
    }
}

struct TextLayoutTests {
    @Test func boxGrowsWithTextThenWraps() {
        let short = TextContent(runs: [TextRun(text: "Hi")])
        let long = TextContent(runs: [TextRun(text: String(repeating: "Notes are great. ", count: 40))])
        let shortSize = TextLayout.size(of: short, maxWidth: 400)
        let longSize = TextLayout.size(of: long, maxWidth: 400)
        #expect(shortSize.width < 60)
        #expect(longSize.width <= 400 && longSize.width > 350)
        #expect(longSize.height > shortSize.height * 5)
    }

    @Test func fixedWidthIsKept() {
        let content = TextContent(runs: [TextRun(text: "Hi")], fixedWidth: 250)
        #expect(TextLayout.size(of: content, maxWidth: 400).width == 250)
    }

    @Test func listItemsGetAHangingIndent() {
        #expect(TextLayout.listMarker(in: "• milk") == "• ")
        #expect(TextLayout.listMarker(in: "12. eggs") == "12. ")
        #expect(TextLayout.listMarker(in: "1.5 cups") == nil)
        let string = TextLayout.attributedString(TextContent(runs: [TextRun(text: "• a very long line")]), paper: nil)
        #expect(string.attribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), at: 0, effectiveRange: nil) != nil)
    }
}

struct ItemStorageTests {
    @Test func itemsAndImagesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ItemStorageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = NotebookFolder(root: root, deviceID: UUID())
        let note = try folder.createNote(title: "Pictures")
        var page = PageRecord(sortKey: 1, size: PageSize.a4, paper: .whiteLined)
        page.background = .image(fileName: "scan.jpg")
        try folder.save(page, inNoteAt: note.url)
        let item = PageItem(kind: .image(ImageContent(fileName: "cat.png")), frame: CGRect(x: 10, y: 10, width: 100, height: 80), rotation: 0.3)
        let items = DeviceItems(items: [item], deleted: [UUID(): Date()])
        try folder.saveOwnItems(items, page: page.id, inNoteAt: note.url)
        try folder.saveImage(Data([1, 2, 3]), named: "cat.png", inNoteAt: note.url)

        let loaded = try folder.loadPages(inNoteAt: note.url)
        #expect(loaded.first?.record.background == .image(fileName: "scan.jpg"))
        #expect(loaded.first?.items[folder.deviceID] == items)
        #expect(folder.loadImageData(named: "cat.png", inNoteAt: note.url) == Data([1, 2, 3]))
    }
}

struct ItemRenderingTests {
    @Test func textAndImagesDrawUnderInk() throws {
        let size = CGSize(width: 200, height: 120)
        let context = try #require(CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 120)
        context.scaleBy(x: 1, y: -1)
        // A solid red 10×10 picture, stretched over the left half.
        let red = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        red.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        red.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let image = RenderedItem(PageItem(kind: .image(ImageContent(fileName: "x")), frame: CGRect(x: 0, y: 0, width: 100, height: 120)),
                                 image: red.makeImage())
        let text = RenderedItem(PageItem(kind: .text(TextContent(runs: [TextRun(text: "MMMM", size: 40)])), frame: CGRect(x: 100, y: 20, width: 100, height: 60)))
        // A black pen line across both.
        let ink = RenderedStroke(Stroke(color: .black, points: [InkPoint(x: 0, y: 100, width: 6), InkPoint(x: 200, y: 100, width: 6)]))
        let content = PageContent(paper: PaperStyle(template: .blank, color: .white), size: size, strokes: [ink], items: [image, text])
        PageRenderer.draw(content, layer: .all, in: context, clip: CGRect(origin: .zero, size: size))
        let pixels = try #require(context.makeImage()?.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = y * context.bytesPerRow + x * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        #expect(pixel(50, 40) == (255, 0, 0))            // the picture
        #expect(pixel(50, 100).0 < 40)                    // ink drawn over the picture
        let textPixels = (100..<200).flatMap { x in (25..<75).map { y in pixel(x, y) } }
        #expect(textPixels.contains { $0.0 < 100 })        // some dark text pixels
    }
}
