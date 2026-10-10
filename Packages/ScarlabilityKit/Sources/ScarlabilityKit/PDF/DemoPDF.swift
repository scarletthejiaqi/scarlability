import CoreGraphics
import CoreText
import Foundation

/// A small lecture-notes PDF for tests and debug builds: Letter pages with a title and lines of
/// real text (so the highlighter's text snap has something to find).
public enum DemoPDF {
    public static let pageSize = CGSize(width: 612, height: 792)
    /// Where line `i` of the body text starts, measured from the top-left (its baseline).
    public static func lineOrigin(_ i: Int) -> CGPoint { CGPoint(x: 72, y: 160 + CGFloat(i) * 30) }

    public static func data(pages: Int = 3) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let body = [
            "Derivatives measure how a function changes.",
            "The slope of the tangent line at a point is f'(x).",
            "Power rule: d/dx x^n = n x^(n-1).",
            "Product rule: (fg)' = f'g + fg'.",
            "Chain rule: (f(g(x)))' = f'(g(x)) g'(x).",
            "Practice: differentiate x^3 + 2x^2 - 5x + 1.",
        ]
        for page in 1...pages {
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            draw("Lecture \(page): Derivatives", size: 26, at: CGPoint(x: 72, y: 100), in: context)
            for (i, line) in body.enumerated() {
                draw(line, size: 17, at: lineOrigin(i), in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ text: String, size: CGFloat, at topLeftOrigin: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        context.textPosition = CGPoint(x: topLeftOrigin.x, y: pageSize.height - topLeftOrigin.y)
        CTLineDraw(line, context)
    }
}
