#if os(iOS)
import QuartzCore
import ScarlabilityKit
import UIKit

/// The stroke being written, plus just-finished strokes waiting for the page tiles to show them.
///
/// Strokes are drawn inside the zoomed content, on top of the pages, at the same resolution and
/// on the same pixel grid as the tiles. When the tiles have redrawn a finished stroke, its copy
/// here fades out over a moment instead of disappearing at once, which hides the tiny difference
/// in how the screen places tiles, so nothing visibly changes when the pen lifts.
final class LiveInk {
    /// Where ink may appear (all the pages), in content coordinates. Writing can run from one
    /// page onto the next, so this isn't just the page the stroke started on.
    var writingArea: CGRect = .infinite {
        didSet { live.writingArea = writingArea }
    }

    /// Pixels per content point; set to what the page tiles use at the current zoom.
    var rasterScale: CGFloat = 2 {
        didSet { live.rasterScale = rasterScale }
    }

    private let host: CALayer
    private let live = StrokeInkLayer()
    private var handoffs: [UUID: StrokeInkLayer] = [:]

    /// If the pages somehow never report back, stop showing a handed-off stroke after this long.
    private static let handoffTimeout: TimeInterval = 0.6
    private static let fadeDuration: CFTimeInterval = 0.12

    init(host: CALayer) {
        self.host = host
        host.addSublayer(live)
    }

    func showLiveStroke(_ points: [InkPoint], color: InkColor, pageOrigin: CGPoint) {
        live.show(StrokeGeometry.path(for: points), color: color.cgColor, pageOrigin: pageOrigin, growing: true)
    }

    func clearLiveStroke() {
        live.clear()
    }

    /// Replaces the live stroke with its finished shape, shown until `endHandOff(id)`.
    func handOff(id: UUID, path: CGPath, color: InkColor, pageOrigin: CGPoint) {
        let layer = StrokeInkLayer()
        layer.writingArea = writingArea
        layer.rasterScale = rasterScale
        layer.show(path, color: color.cgColor, pageOrigin: pageOrigin, growing: false)
        host.addSublayer(layer)
        handoffs[id] = layer
        live.clear()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffTimeout) { [weak self] in
            self?.endHandOff(id)
        }
    }

    func endHandOff(_ id: UUID) {
        guard let layer = handoffs.removeValue(forKey: id) else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeDuration
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

/// One stroke, rasterized like the page tiles.
private final class StrokeInkLayer: CALayer {
    var writingArea: CGRect = .infinite
    var rasterScale: CGFloat = 2

    private var path: CGPath?
    private var color: CGColor?
    /// Origin of the page whose coordinates the path is in, in content coordinates. The pixel
    /// grid is anchored there, like that page's tiles.
    private var pageOrigin: CGPoint = .zero

    override init() {
        super.init()
        zPosition = 10
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Moving and resizing must be instant, not animated.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// - Parameter growing: Keep the layer at least as big as before. While a stroke grows, that
    ///   saves reallocating the backing image on every frame.
    func show(_ path: CGPath, color: CGColor, pageOrigin: CGPoint, growing: Bool) {
        self.path = path
        self.color = color
        self.pageOrigin = pageOrigin

        var area = path.boundingBoxOfPath
            .offsetBy(dx: pageOrigin.x, dy: pageOrigin.y)
            .insetBy(dx: -2, dy: -2)
            .intersection(writingArea)
        guard !area.isNull, !area.isEmpty else {
            clear()
            return
        }
        if growing, !isHidden, !frame.isEmpty {
            area = area.union(frame)
        }
        let scale = rasterScale
        func snapDown(_ value: CGFloat, _ origin: CGFloat) -> CGFloat { origin + floor((value - origin) * scale) / scale }
        func snapUp(_ value: CGFloat, _ origin: CGFloat) -> CGFloat { origin + ceil((value - origin) * scale) / scale }
        let minX = snapDown(area.minX, pageOrigin.x), minY = snapDown(area.minY, pageOrigin.y)
        let maxX = snapUp(area.maxX, pageOrigin.x), maxY = snapUp(area.maxY, pageOrigin.y)

        contentsScale = scale
        frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        isHidden = false
        setNeedsDisplay()
    }

    func clear() {
        path = nil
        isHidden = true
        frame = .zero
    }

    override func draw(in context: CGContext) {
        guard let path, let color else { return }
        // Work in content coordinates, then in the stroke's page coordinates.
        context.translateBy(x: -frame.minX, y: -frame.minY)
        context.clip(to: writingArea)
        context.translateBy(x: pageOrigin.x, y: pageOrigin.y)
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath(using: .winding)
    }
}
#endif
