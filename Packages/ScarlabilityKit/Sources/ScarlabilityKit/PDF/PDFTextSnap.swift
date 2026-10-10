#if canImport(PDFKit)
import CoreGraphics
import PDFKit

/// The highlighter's "snap to text" on PDF pages: instead of a freehand stroke, the text the
/// stroke went over is highlighted line by line, like selecting it.
public enum PDFTextSnap {
    /// The text lines between `start` and `end` (note page coordinates, origin top-left), as
    /// rectangles in note page coordinates. Empty if the stroke didn't go over any text.
    public static func lineRects(on page: PDFPage, background: PDFBackground, pageSize: CGSize,
                                 from start: CGPoint, to end: CGPoint) -> [CGRect] {
        let from = background.pdfPoint(start, pageSize: pageSize)
        let to = background.pdfPoint(end, pageSize: pageSize)
        guard let selection = page.selection(from: from, to: to),
              let text = selection.string, text.contains(where: { !$0.isWhitespace }) else { return [] }
        let rects = selection.selectionsByLine()
            .filter { ($0.string ?? "").contains(where: { !$0.isWhitespace }) }
            .map { background.pageRect($0.bounds(for: page), pageSize: pageSize) }
            .filter { $0.width > 0.5 && $0.height > 0.5 }
        // The stroke has to actually touch the text it would highlight.
        let stroke = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -4, dy: -4)
        guard rects.contains(where: { $0.intersects(stroke) }) else { return [] }
        return rects
    }

    /// Highlighter points covering a text line: a sideways stroke whose chisel height is the
    /// line's height, pulled in at the ends so the tip's width stays inside the line.
    public static func highlightPoints(for line: CGRect) -> [InkPoint] {
        let height = line.height * 1.1
        let inset = min(StrokeGeometry.chiselAspect * height / 2, line.width / 2)
        let y = Float(line.midY)
        return stride(from: line.minX + inset, through: line.maxX - inset, by: max(1, (line.width - 2 * inset) / 40))
            .map { InkPoint(x: Float($0), y: y, width: Float(height)) }
    }
}
#endif
