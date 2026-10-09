#if os(iOS)
import ScarlabilityKit
import UIKit

/// One page on the canvas, drawn by two tiled layers: the paper with its highlights, and the pen
/// ink on top. The highlighter being drawn goes between them, so it's behind the writing just like
/// finished highlights are.
final class PageView: UIView {
    private let backgroundTiles = TileView(role: .background)
    private let inkTiles = TileView(role: .ink)
    /// Holds live highlighter strokes, between the two tile layers. In page coordinates.
    let highlighterHost = CALayer()

    /// Resolution for both tile layers (see `NoteCanvasView.tileScale`).
    var tileScale: CGFloat = 2 {
        didSet {
            backgroundTiles.contentScaleFactor = tileScale
            inkTiles.contentScaleFactor = tileScale
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(backgroundTiles)
        addSubview(inkTiles)
        layer.insertSublayer(highlighterHost, above: backgroundTiles.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundTiles.frame = bounds
        inkTiles.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlighterHost.frame = bounds
        CATransaction.commit()
    }

    func tiles(_ role: PageRenderer.Layer) -> PageTileLayer {
        role == .ink ? inkTiles.tileLayer : backgroundTiles.tileLayer
    }

    func setContent(_ content: PageContent, changedRect: CGRect?) {
        backgroundTiles.tileLayer.setContent(content, changedRect: changedRect)
        inkTiles.tileLayer.setContent(content, changedRect: changedRect)
    }

    /// Called on a background thread after a tile is drawn.
    func setTileDrawnHandler(_ handler: @escaping @Sendable (PageRenderer.Layer, CGRect, Int) -> Void) {
        backgroundTiles.tileLayer.setTileDrawnHandler { handler(.background, $0, $1) }
        inkTiles.tileLayer.setTileDrawnHandler { handler(.ink, $0, $1) }
    }

    private final class TileView: UIView {
        override class var layerClass: AnyClass { PageTileLayer.self }
        var tileLayer: PageTileLayer { layer as! PageTileLayer }

        init(role: PageRenderer.Layer) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isOpaque = role == .background
            tileLayer.role = role
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }
}
#endif
