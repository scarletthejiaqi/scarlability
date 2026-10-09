#if os(iOS)
import ScarlabilityKit
import UIKit

/// Converts typed text between the saved form (`TextContent` runs) and the attributed string a
/// `UITextView` edits. The editor shows text at the current zoom, so sizes are scaled; the saved
/// style is also kept in private attributes, so nothing is lost in the round trip.
enum TextBridge {
    static let fontKey = NSAttributedString.Key("scarlability.font")
    static let sizeKey = NSAttributedString.Key("scarlability.size")
    static let boldKey = NSAttributedString.Key("scarlability.bold")
    static let italicKey = NSAttributedString.Key("scarlability.italic")
    /// The saved color (what's shown can differ: black shows white on dark paper).
    static let colorKey = NSAttributedString.Key("scarlability.color")

    static func attributedString(_ content: TextContent, zoom: CGFloat, paper: PaperStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs where !run.text.isEmpty {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run, zoom: zoom, paper: paper)))
        }
        applyListIndents(result, zoom: zoom)
        return result
    }

    static func attributes(for run: TextRun, zoom: CGFloat, paper: PaperStyle) -> [NSAttributedString.Key: Any] {
        let font = unsafeBitCast(TextLayout.platformFont(run.font, size: CGFloat(run.size) * zoom, bold: run.bold, italic: run.italic), to: UIFont.self)
        let color = run.color
        return [
            .font: font,
            .foregroundColor: UIColor(cgColor: color.displayed(on: paper).cgColor),
            .underlineStyle: run.underline ? NSUnderlineStyle.single.rawValue : 0,
            fontKey: run.font.rawValue,
            sizeKey: run.size,
            boldKey: run.bold,
            italicKey: run.italic,
            colorKey: [Int(color.red), Int(color.green), Int(color.blue), Int(color.alpha)],
        ]
    }

    /// Reads a run's style back. Bold, italic and size come from the font itself, because
    /// `UITextView`'s typing attributes don't always keep private attributes.
    static func run(text: String, attributes: [NSAttributedString.Key: Any], fallback: TextRun, zoom: CGFloat, paper: PaperStyle) -> TextRun {
        var run = fallback
        run.text = text
        if let font = attributes[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            run.bold = traits.contains(.traitBold)
            run.italic = traits.contains(.traitItalic)
            run.size = (Double(font.pointSize / zoom) * 2).rounded() / 2
            run.font = (attributes[fontKey] as? String).flatMap(TextFont.init(rawValue:)) ?? family(of: font)
        }
        run.underline = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
        if let rgba = attributes[colorKey] as? [Int], rgba.count == 4 {
            run.color = InkColor(red: UInt8(rgba[0]), green: UInt8(rgba[1]), blue: UInt8(rgba[2]), alpha: UInt8(rgba[3]))
        } else if let color = attributes[.foregroundColor] as? UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let shown = InkColor(srgbRed: r, green: g, blue: b, alpha: a)
            // Undo the dark-paper swap (black is shown white).
            run.color = paper.isDark && shown == InkColor.black.displayed(on: paper) ? .black : shown
        }
        return run
    }

    private static func family(of font: UIFont) -> TextFont {
        let name = (font.familyName + " " + font.fontName).lowercased()
        if name.contains("noteworthy") { return .handwritten }
        if name.contains("marker") { return .marker }
        if name.contains("new york") || name.contains("newyork") { return .serif }
        if name.contains("rounded") { return .rounded }
        if name.contains("mono") { return .monospaced }
        return .system
    }

    static func content(from attributed: NSAttributedString, fallback: TextRun, fixedWidth: Double?, zoom: CGFloat, paper: PaperStyle) -> TextContent {
        var runs: [TextRun] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            let next = run(text: text, attributes: attributes, fallback: fallback, zoom: zoom, paper: paper)
            // Merge neighbors with the same style.
            if var last = runs.last, TextRun(text: "", font: last.font, size: last.size, bold: last.bold, italic: last.italic, underline: last.underline, color: last.color)
                == TextRun(text: "", font: next.font, size: next.size, bold: next.bold, italic: next.italic, underline: next.underline, color: next.color) {
                last.text += next.text
                runs[runs.count - 1] = last
            } else {
                runs.append(next)
            }
        }
        return TextContent(runs: runs, fixedWidth: fixedWidth)
    }

    /// Gives list paragraphs ("• " or "1. ") a hanging indent, like `TextLayout` does.
    static func applyListIndents(_ text: NSMutableAttributedString, zoom: CGFloat) {
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            let style = NSMutableParagraphStyle()
            if let marker = TextLayout.listMarker(in: string.substring(with: paragraph)) {
                let font = text.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 17 * zoom)
                style.headIndent = (marker as NSString).size(withAttributes: [.font: font]).width
            }
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
            location = NSMaxRange(paragraph)
        }
    }
}
#endif
