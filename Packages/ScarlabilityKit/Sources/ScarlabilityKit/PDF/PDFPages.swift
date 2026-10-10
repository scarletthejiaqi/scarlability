import CoreGraphics
import Foundation

/// An imported PDF file, opened once and shared by all the note pages showing its pages.
///
/// The file itself is never changed: writing, highlights, text and images go on top of it.
public final class PDFFile: @unchecked Sendable {
    public let document: CGPDFDocument
    /// Page tiles draw on several threads at once; drawing from one document is kept to one
    /// thread at a time.
    let lock = NSLock()

    public init?(data: Data) {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return nil }
        self.document = document
    }

    public var pageCount: Int { document.numberOfPages }

    /// - Parameter index: Zero-based.
    public func page(at index: Int) -> PDFBackground? {
        guard let page = document.page(at: index + 1) else { return nil }
        return PDFBackground(page: page, file: self)
    }
}

/// A page of an imported PDF, drawn under everything on its note page. Drawing is vector, so it
/// stays sharp at any zoom and in exported PDFs.
public final class PDFBackground: @unchecked Sendable {
    public let page: CGPDFPage
    private let file: PDFFile

    init(page: CGPDFPage, file: PDFFile) {
        self.page = page
        self.file = file
    }

    /// The size a note page needs to show this PDF page: its crop box, turned by its rotation.
    public var size: CGSize {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        return turned ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Maps PDF page space onto a page of `size` with its origin at the bottom-left.
    func drawingTransform(for size: CGSize) -> CGAffineTransform {
        page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
    }

    /// Draws the PDF page filling a note page of `pageSize` (page coordinates, origin top-left).
    public func draw(in context: CGContext, pageSize: CGSize) {
        file.lock.lock()
        defer { file.lock.unlock() }
        context.saveGState()
        context.translateBy(x: 0, y: pageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(drawingTransform(for: pageSize))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Converts a point on the note page (origin top-left) into PDF page space.
    public func pdfPoint(_ point: CGPoint, pageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x, y: pageSize.height - point.y).applying(drawingTransform(for: pageSize).inverted())
    }

    /// Converts a rectangle in PDF page space onto the note page (origin top-left).
    public func pageRect(_ rect: CGRect, pageSize: CGSize) -> CGRect {
        let flipped = rect.applying(drawingTransform(for: pageSize))
        return CGRect(x: flipped.minX, y: pageSize.height - flipped.maxY, width: flipped.width, height: flipped.height)
    }
}

/// Which pages to export, typed like "1-3, 5, 8-".
public enum PageRange {
    /// Zero-based page indexes in the order written (each once), or nil if the text isn't a
    /// valid range for `pageCount` pages.
    public static func parse(_ text: String, pageCount: Int) -> [Int]? {
        var pages: [Int] = []
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
        guard !parts.isEmpty else { return nil }
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let range: ClosedRange<Int>
            switch bounds.count {
            case 1:
                guard let page = Int(bounds[0]) else { return nil }
                range = page...page
            case 2:
                guard let first = bounds[0].isEmpty ? 1 : Int(bounds[0]),
                      let last = bounds[1].isEmpty ? pageCount : Int(bounds[1]), first <= last else { return nil }
                range = first...last
            default:
                return nil
            }
            guard range.lowerBound >= 1, range.upperBound <= pageCount else { return nil }
            for page in range where !pages.contains(page - 1) {
                pages.append(page - 1)
            }
        }
        return pages.isEmpty ? nil : pages
    }
}

/// Writes notes as PDF. Paper, PDF pages, text and ink stay vector (sharp at any size); only
/// pictures are images.
public enum PDFExport {
    /// - Parameter includePaper: Draw the paper (lines and color). Without it, pages are plain
    ///   white, and ink that showed white on dark paper is black again.
    public static func data(pages: [PageContent], includePaper: Bool) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return Data() }
        for var content in pages {
            if !includePaper {
                content.paper = PaperStyle(template: .blank, color: .white)
            }
            content.bottomEdgeColor = nil
            var box = CGRect(origin: .zero, size: content.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            // Page coordinates have their origin at the top-left.
            context.translateBy(x: 0, y: content.size.height)
            context.scaleBy(x: 1, y: -1)
            PageRenderer.draw(content, layer: .all, in: context, clip: CGRect(origin: .zero, size: content.size))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
