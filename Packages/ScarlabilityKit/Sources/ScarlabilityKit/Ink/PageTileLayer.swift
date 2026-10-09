import QuartzCore
import Synchronization

/// Draws one layer of a page (see `PageRenderer.Layer`) in tiles on background threads, so the
/// page stays sharp at any zoom without needing one huge bitmap.
public final class PageTileLayer: CATiledLayer {
    /// Which part of the page this layer draws. Set it before content.
    public var role: PageRenderer.Layer {
        get { state.withLock { $0.role } }
        set { state.withLock { $0.role = newValue } }
    }

    /// Called (on a background thread) after each tile is drawn, with the tile's rect in page
    /// coordinates and the content version it showed.
    public typealias TileDrawnHandler = @Sendable (_ rect: CGRect, _ version: Int) -> Void

    private struct State {
        var role: PageRenderer.Layer = .all
        var content: PageContent?
        var version = 0
        var onTileDrawn: TileDrawnHandler?
    }

    private let state = Mutex(State())

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
            let copied = other.state.withLock { $0 }
            state.withLock { $0 = copied }
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The version of the latest content; tiles report which version they drew.
    public var contentVersion: Int { state.withLock { $0.version } }

    public func setTileDrawnHandler(_ handler: @escaping TileDrawnHandler) {
        state.withLock { $0.onTileDrawn = handler }
    }

    /// Replaces what the page shows. Pass the changed area to redraw only those tiles.
    public func setContent(_ newContent: PageContent, changedRect: CGRect? = nil) {
        state.withLock {
            $0.content = newContent
            $0.version += 1
        }
        if let changedRect {
            setNeedsDisplay(changedRect.insetBy(dx: -2, dy: -2))
        } else {
            setNeedsDisplay()
        }
    }

    override public func draw(in context: CGContext) {
        let (role, content, version, onTileDrawn) = state.withLock { ($0.role, $0.content, $0.version, $0.onTileDrawn) }
        guard let content else { return }
        let clip = context.boundingBoxOfClipPath
        #if os(macOS)
        // AppKit layers have their origin at the bottom-left; page coordinates start at the top-left.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let pageClip = CGRect(x: clip.minX, y: bounds.height - clip.maxY, width: clip.width, height: clip.height)
        #else
        let pageClip = clip
        #endif
        PageRenderer.draw(content, layer: role, in: context, clip: pageClip)
        onTileDrawn?(pageClip, version)
    }
}
