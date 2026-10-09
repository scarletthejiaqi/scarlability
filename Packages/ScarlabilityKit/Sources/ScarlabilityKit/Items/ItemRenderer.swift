import CoreGraphics
import CoreText
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Lays out and draws typed text with Core Text, which (unlike UIKit text) is safe on the
/// background threads that draw page tiles.
public enum TextLayout {
    /// Space between a text box's edge and its text.
    public static let padding: CGFloat = 4
    /// Text boxes stop growing this far from the page's right edge.
    public static let pageMargin: CGFloat = 16

    /// The size a text box needs: its fixed width if it has one, otherwise as wide as the text
    /// (up to `maxWidth`, where it wraps).
    public static func size(of content: TextContent, maxWidth: CGFloat) -> CGSize {
        let limit = max(CGFloat(content.fixedWidth ?? Double(maxWidth)), 2 * padding + 10)
        let string = attributedString(content, paper: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: limit - 2 * padding, height: .greatestFiniteMagnitude), nil
        )
        let lineHeight = emptyLineHeight(content)
        let width = content.fixedWidth.map { CGFloat($0) } ?? min(limit, ceil(fitted.width) + 2 * padding + 2)
        var height = max(ceil(fitted.height), lineHeight) + 2 * padding
        // A trailing empty line (just after pressing Return) still takes up a line.
        if content.plainText.hasSuffix("\n") { height += lineHeight }
        return CGSize(width: max(width, 2 * padding + 10), height: height)
    }

    /// Draws text into `rect` (page coordinates, origin at the top-left).
    public static func draw(_ content: TextContent, in rect: CGRect, paper: PaperStyle?, context: CGContext) {
        let string = attributedString(content, paper: paper)
        guard string.length > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        context.saveGState()
        // Core Text draws with the origin at the bottom-left; flip within the box.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let textRect = CGRect(x: padding, y: padding, width: rect.width - 2 * padding, height: rect.height - 2 * padding + 1000)
        // Lay out from the top: the extra height hangs below the box and stays empty.
        let path = CGPath(rect: textRect.offsetBy(dx: 0, dy: -1000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// The text as a Core Text attributed string. Paragraphs starting with a list marker
    /// ("• " or "1. ") get a hanging indent, so wrapped lines line up after the marker.
    public static func attributedString(_ content: TextContent, paper: PaperStyle?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs where !run.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(for: run),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): (paper.map { run.color.displayed(on: $0) } ?? run.color).cgColor,
            ]
            if run.underline {
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = NSNumber(value: CTUnderlineStyle.single.rawValue)
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        // Hanging indents for list items.
        let text = result.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: paragraph)
            if let marker = listMarker(in: line) {
                let markerFont = result.attribute(NSAttributedString.Key(kCTFontAttributeName as String), at: paragraph.location, effectiveRange: nil)
                let markerString = NSAttributedString(string: marker, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): markerFont as Any])
                var indent = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(markerString), nil, nil, nil))
                let style = withUnsafeMutablePointer(to: &indent) { pointer -> CTParagraphStyle in
                    var setting = CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: pointer)
                    return CTParagraphStyleCreate(&setting, 1)
                }
                result.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style, range: paragraph)
            }
            location = NSMaxRange(paragraph)
        }
        return result
    }

    /// "• " or a number like "12. " at the start of a line.
    public static func listMarker(in line: String) -> String? {
        if line.hasPrefix("• ") { return "• " }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") { return digits + ". " }
        return nil
    }

    static func font(for run: TextRun) -> CTFont {
        platformFont(run.font, size: CGFloat(run.size), bold: run.bold, italic: run.italic)
    }

    private static func emptyLineHeight(_ content: TextContent) -> CGFloat {
        let font = content.runs.last.map(font(for:)) ?? platformFont(.system, size: 17, bold: false, italic: false)
        return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The platform font for a text style, as a Core Text font.
    public static func platformFont(_ font: TextFont, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size).fontDescriptor
        var descriptor: UIFontDescriptor
        switch font {
        case .system: descriptor = base
        case .serif: descriptor = base.withDesign(.serif) ?? base
        case .rounded: descriptor = base.withDesign(.rounded) ?? base
        case .monospaced: descriptor = base.withDesign(.monospaced) ?? base
        case .handwritten: descriptor = UIFontDescriptor(name: "Noteworthy-Light", size: size)
        case .marker: descriptor = UIFontDescriptor(name: "MarkerFelt-Thin", size: size)
        }
        var traits = descriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        return unsafeBitCast(UIFont(descriptor: descriptor, size: size), to: CTFont.self)
        #else
        let base = NSFont.systemFont(ofSize: size).fontDescriptor
        var descriptor: NSFontDescriptor
        switch font {
        case .system: descriptor = base
        case .serif: descriptor = base.withDesign(.serif) ?? base
        case .rounded: descriptor = base.withDesign(.rounded) ?? base
        case .monospaced: descriptor = base.withDesign(.monospaced) ?? base
        case .handwritten: descriptor = NSFontDescriptor(name: "Noteworthy-Light", size: size)
        case .marker: descriptor = NSFontDescriptor(name: "MarkerFelt-Thin", size: size)
        }
        var traits = descriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        descriptor = descriptor.withSymbolicTraits(traits)
        let nsFont = NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
        return unsafeBitCast(nsFont, to: CTFont.self)
        #endif
    }
}

/// An item with what it needs to draw, ready for any thread.
public struct RenderedItem: @unchecked Sendable {
    public let item: PageItem
    /// For image items: the cropped picture (nil while it's still loading).
    public let image: CGImage?

    public init(_ item: PageItem, image fullImage: CGImage? = nil) {
        self.item = item
        if let fullImage, let crop = item.image?.crop {
            let pixels = CGRect(x: crop.minX * CGFloat(fullImage.width), y: crop.minY * CGFloat(fullImage.height),
                                width: crop.width * CGFloat(fullImage.width), height: crop.height * CGFloat(fullImage.height)).integral
            image = crop == CGRect(x: 0, y: 0, width: 1, height: 1) ? fullImage : fullImage.cropping(to: pixels)
        } else {
            image = nil
        }
    }
}

public enum ItemRenderer {
    /// Draws items in order. The context must use page coordinates with the origin at the top-left.
    public static func draw(_ items: [RenderedItem], paper: PaperStyle?, in context: CGContext, clip: CGRect) {
        for rendered in items where rendered.item.bounds.intersects(clip) {
            draw(rendered, paper: paper, in: context)
        }
    }

    public static func draw(_ rendered: RenderedItem, paper: PaperStyle?, in context: CGContext) {
        let item = rendered.item
        context.saveGState()
        context.concatenate(item.rotationTransform)
        switch item.kind {
        case .text(let content):
            TextLayout.draw(content, in: item.frame, paper: paper, context: context)
        case .image:
            if let image = rendered.image {
                drawImage(image, in: item.frame, context: context)
            } else {
                // Still loading.
                context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                context.fill(item.frame)
            }
        }
        context.restoreGState()
    }

    /// Draws an image right side up in a top-left-origin context.
    public static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// The largest rect with the image's shape that fits in `bounds`, centered.
    public static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}

public enum ImageLoading {
    /// Decodes an image, upright (honoring photo orientation) and no bigger than `maxPixelSize`.
    public static func cgImage(from data: Data, maxPixelSize: Int = 2400) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
