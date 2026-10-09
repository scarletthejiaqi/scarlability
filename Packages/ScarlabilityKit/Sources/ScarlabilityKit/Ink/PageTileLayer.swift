import QuartzCore
import Synchronization

/// Draws one page (paper + finished ink) in tiles on background threads, so the page stays sharp
/// at any zoom without needing one huge bitmap.
public final class PageTileLayer: CATiledLayer {
    public struct Content: Sendable {
        public var paper: PaperStyle
        public var size: CGSize
        public var strokes: [RenderedStroke]

        public init(paper: PaperStyle, size: CGSize, strokes: [RenderedStroke]) {
            self.paper = paper
            self.size = size
            self.strokes = strokes
        }
    }

    private let content = Mutex<Content?>(nil)

    // New tiles appear instantly instead of fading in.
    override public class func fadeDuration() -> CFTimeInterval { 0 }

    override public init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        // Sharp from 1/8× up to 8× the layer's own scale.
        levelsOfDetail = 7
        levelsOfDetailBias = 3
    }

    override public init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? PageTileLayer {
            content.withLock { $0 = other.content.withLock { $0 } }
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replaces what the page shows. Pass the changed area to redraw only those tiles.
    public func setContent(_ newContent: Content, changedRect: CGRect? = nil) {
        content.withLock { $0 = newContent }
        if let changedRect {
            setNeedsDisplay(changedRect.insetBy(dx: -2, dy: -2))
        } else {
            setNeedsDisplay()
        }
    }

    override public func draw(in context: CGContext) {
        guard let content = content.withLock({ $0 }) else { return }
        let clip = context.boundingBoxOfClipPath
        #if os(macOS)
        // AppKit layers have their origin at the bottom-left; page coordinates start at the top-left.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let pageClip = CGRect(x: clip.minX, y: bounds.height - clip.maxY, width: clip.width, height: clip.height)
        #else
        let pageClip = clip
        #endif
        PaperRenderer.draw(content.paper, pageSize: content.size, in: context, clip: pageClip)
        InkRenderer.draw(content.strokes, in: context, clip: pageClip)
    }
}
