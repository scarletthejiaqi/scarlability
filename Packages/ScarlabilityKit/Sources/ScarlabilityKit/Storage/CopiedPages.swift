import CoreGraphics
import Foundation

/// Pages copied (or cut) in the page panel, ready to paste into any note: everything on them,
/// plus the pictures and PDFs they use, so they paste the same into another note.
public struct CopiedPages: Codable, Sendable {
    public struct Page: Codable, Sendable {
        public var size: CGSize
        public var paper: PaperStyle
        public var background: PageBackground?
        /// The page's strokes, encoded like an ink file.
        public var ink: Data
        public var items: [PageItem]

        public init(size: CGSize, paper: PaperStyle, background: PageBackground?, strokes: [Stroke], items: [PageItem]) throws {
            self.size = size
            self.paper = paper
            self.background = background
            self.ink = try InkCodec.encode(DeviceInk(strokes: strokes))
            self.items = items
        }
    }

    public var pages: [Page]
    /// Picture and PDF files the pages use, by file name.
    public var files: [String: Data]

    public static let pasteboardType = "scarlability.pages"

    public init(pages: [Page], files: [String: Data]) {
        self.pages = pages
        self.files = files
    }

    /// The file names (pictures, scans and PDFs) a page needs.
    public static func fileNames(background: PageBackground?, items: [PageItem]) -> Set<String> {
        var names = Set(items.compactMap { $0.image?.fileName })
        switch background {
        case .image(let name)?: names.insert(name)
        case .pdf(let name, _)?: names.insert(name)
        case nil: break
        }
        return names
    }

    /// New pages to paste: fresh IDs for the pages, their strokes and items, so pasting twice
    /// gives two independent copies. Sort keys are left at 0 for the note to set.
    public func freshPages(now: Date = Date()) -> [(record: PageRecord, ink: DeviceInk, items: DeviceItems)] {
        pages.map { page in
            var record = PageRecord(sortKey: 0, size: page.size, paper: page.paper)
            record.background = page.background
            let strokes = ((try? InkCodec.decode(page.ink))?.strokes ?? []).map {
                Stroke(tool: $0.tool, color: $0.color, points: $0.points, createdAt: now)
            }
            let items = page.items.enumerated().map { offset, item in
                var copy = item
                copy.id = UUID()
                // Keeps their order (newer draws on top).
                copy.createdAt = now.addingTimeInterval(Double(offset) * 0.001)
                copy.modifiedAt = copy.createdAt
                return copy
            }
            return (record, DeviceInk(strokes: strokes), DeviceItems(items: items))
        }
    }
}
