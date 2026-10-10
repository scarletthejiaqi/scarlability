import CoreGraphics

/// A stroke together with its prebuilt outline, ready to draw from any thread.
public struct RenderedStroke: @unchecked Sendable {
    // CGPath is immutable once built, so sharing it between threads is safe.
    public let stroke: Stroke
    public let path: CGPath
    public let bounds: CGRect

    public init(_ stroke: Stroke) {
        self.stroke = stroke
        switch stroke.tool {
        case .pen: path = StrokeGeometry.path(for: stroke.points)
        case .highlighter: path = StrokeGeometry.chiselPath(for: stroke.points)
        }
        bounds = stroke.bounds
    }
}

/// Everything one page shows.
public struct PageContent: @unchecked Sendable {
    // The CGImage is immutable, and PDFBackground locks while drawing, so sharing them between
    // threads is safe.
    public var paper: PaperStyle
    public var size: CGSize
    /// Oldest first.
    public var strokes: [RenderedStroke]
    /// Text boxes and images, oldest first.
    public var items: [RenderedItem]
    /// A picture filling the page under everything (a scanned document).
    public var backgroundImage: CGImage?
    /// A PDF page filling the page under everything (an imported PDF).
    public var backgroundPDF: PDFBackground?
    /// A thin line along the bottom edge, separating this page from the next one on screen.
    public var bottomEdgeColor: InkColor?

    public init(paper: PaperStyle, size: CGSize, strokes: [RenderedStroke], items: [RenderedItem] = [],
                backgroundImage: CGImage? = nil, backgroundPDF: PDFBackground? = nil, bottomEdgeColor: InkColor? = nil) {
        self.paper = paper
        self.size = size
        self.strokes = strokes
        self.items = items
        self.backgroundImage = backgroundImage
        self.backgroundPDF = backgroundPDF
        self.bottomEdgeColor = bottomEdgeColor
    }
}

/// Draws a page in layers: paper (and a scanned or PDF background), then images and typed text, then
/// highlights, then pen ink on top, so you can write and highlight over text and pictures. The
/// canvas draws everything but the ink in one tiled layer and the ink in another, so the live
/// highlighter can slide between them and look exactly like the finished one.
public enum PageRenderer {
    public enum Layer: Sendable {
        /// Paper, background, page edge line, images, text and highlights.
        case background
        /// Pen ink.
        case ink
        /// Everything (for export and tests).
        case all
    }

    /// Highlights are drawn opaque into a transparency layer that's then composited at this
    /// opacity, so overlapping highlights stay one even color.
    public static let highlighterOpacity: CGFloat = 0.5

    /// The context must use page coordinates with the origin at the top-left.
    public static func draw(_ content: PageContent, layer: Layer, in context: CGContext, clip: CGRect) {
        if layer != .ink {
            PaperRenderer.draw(content.paper, pageSize: content.size, in: context, clip: clip)
            if let background = content.backgroundImage {
                let page = CGRect(origin: .zero, size: content.size)
                ItemRenderer.drawImage(background, in: ItemRenderer.aspectFit(CGSize(width: background.width, height: background.height), in: page),
                                       context: context)
            }
            content.backgroundPDF?.draw(in: context, pageSize: content.size)
            if let edge = content.bottomEdgeColor {
                // Under the ink, so writing that crosses onto the next page covers it.
                context.setFillColor(edge.cgColor)
                context.fill(CGRect(x: 0, y: content.size.height - 0.75, width: content.size.width, height: 0.75))
            }
            ItemRenderer.draw(content.items, paper: content.paper, in: context, clip: clip)
            drawHighlights(content.strokes, in: context, clip: clip, multiplies: !content.paper.isDark)
        }
        if layer != .background {
            drawInk(content.strokes, paper: content.paper, in: context, clip: clip)
        }
    }

    /// - Parameter multiplies: Like a real highlighter, darken what's under it instead of covering
    ///   it, so text and pictures under a highlight stay as dark as they were. On white it looks
    ///   the same either way. (Not on dark paper, where highlights have to brighten the page.)
    public static func drawHighlights(_ strokes: [RenderedStroke], in context: CGContext, clip: CGRect, multiplies: Bool = false) {
        let highlights = strokes.filter { $0.stroke.tool == .highlighter && $0.bounds.intersects(clip) }
        guard !highlights.isEmpty else { return }
        context.saveGState()
        context.setAlpha(highlighterOpacity)
        if multiplies {
            context.setBlendMode(.multiply)
        }
        context.beginTransparencyLayer(in: clip, auxiliaryInfo: nil)
        for rendered in highlights {
            context.setFillColor(rendered.stroke.color.cgColor)
            context.addPath(rendered.path)
            context.fillPath(using: .winding)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    public static func drawInk(_ strokes: [RenderedStroke], paper: PaperStyle, in context: CGContext, clip: CGRect) {
        for rendered in strokes where rendered.stroke.tool == .pen && rendered.bounds.intersects(clip) {
            context.setFillColor(rendered.stroke.color.displayed(on: paper).cgColor)
            context.addPath(rendered.path)
            context.fillPath(using: .winding)
        }
    }
}
