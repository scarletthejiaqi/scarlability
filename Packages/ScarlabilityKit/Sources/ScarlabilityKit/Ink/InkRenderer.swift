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
public struct PageContent: Sendable {
    public var paper: PaperStyle
    public var size: CGSize
    /// Oldest first.
    public var strokes: [RenderedStroke]
    /// A thin line along the bottom edge, separating this page from the next one on screen.
    public var bottomEdgeColor: InkColor?

    public init(paper: PaperStyle, size: CGSize, strokes: [RenderedStroke], bottomEdgeColor: InkColor? = nil) {
        self.paper = paper
        self.size = size
        self.strokes = strokes
        self.bottomEdgeColor = bottomEdgeColor
    }
}

/// Draws a page in layers: paper, then highlights, then pen ink on top. The canvas draws the
/// first two and the ink in separate tiled layers, so the live highlighter can slide between them
/// and look exactly like the finished one (behind the writing).
public enum PageRenderer {
    public enum Layer: Sendable {
        /// Paper, the page edge line and highlights.
        case background
        /// Pen ink.
        case ink
        /// Everything (for export and tests).
        case all
    }

    /// Highlights are drawn opaque into a transparency layer that's then composited at this
    /// opacity, so overlapping highlights stay one even color.
    public static let highlighterOpacity: CGFloat = 0.38

    /// The context must use page coordinates with the origin at the top-left.
    public static func draw(_ content: PageContent, layer: Layer, in context: CGContext, clip: CGRect) {
        if layer != .ink {
            PaperRenderer.draw(content.paper, pageSize: content.size, in: context, clip: clip)
            if let edge = content.bottomEdgeColor {
                // Under the ink, so writing that crosses onto the next page covers it.
                context.setFillColor(edge.cgColor)
                context.fill(CGRect(x: 0, y: content.size.height - 0.75, width: content.size.width, height: 0.75))
            }
            drawHighlights(content.strokes, in: context, clip: clip)
        }
        if layer != .background {
            drawInk(content.strokes, paper: content.paper, in: context, clip: clip)
        }
    }

    public static func drawHighlights(_ strokes: [RenderedStroke], in context: CGContext, clip: CGRect) {
        let highlights = strokes.filter { $0.stroke.tool == .highlighter && $0.bounds.intersects(clip) }
        guard !highlights.isEmpty else { return }
        context.saveGState()
        context.setAlpha(highlighterOpacity)
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
