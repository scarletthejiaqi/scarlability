#if os(iOS)
import ScarlabilityKit
import UIKit

/// Draws the stroke being written, on top of the pages and at screen resolution.
///
/// It covers the visible area rather than living inside the zoomed content, so the live stroke is
/// sharp at any zoom without a huge backing image. When a stroke finishes, the page's tiles redraw
/// in the background; the overlay keeps showing the stroke briefly until they've caught up, so it
/// never flickers out.
final class LiveStrokeOverlay: UIView {
    private struct Item {
        var path: CGPath
        var color: CGColor
        weak var pageView: UIView?
    }

    private var live: Item?
    private var liveRect: CGRect = .null
    private var handoffs: [UUID: Item] = [:]

    private static let handoffDuration: TimeInterval = 0.35

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showLiveStroke(_ points: [InkPoint], color: InkColor, on pageView: UIView) {
        let item = Item(path: StrokeGeometry.path(for: points), color: color.cgColor, pageView: pageView)
        live = item
        let rect = screenRect(of: item)
        setNeedsDisplay(rect.union(liveRect).insetBy(dx: -4, dy: -4))
        liveRect = rect
    }

    func clearLiveStroke() {
        if !liveRect.isNull {
            setNeedsDisplay(liveRect.insetBy(dx: -4, dy: -4))
        }
        live = nil
        liveRect = .null
    }

    /// Takes over the finished stroke from the live stroke until the page tiles show it.
    func handOff(_ rendered: RenderedStroke, on pageView: UIView) {
        let id = rendered.stroke.id
        let item = Item(path: rendered.path, color: rendered.stroke.color.cgColor, pageView: pageView)
        handoffs[id] = item
        clearLiveStroke()
        setNeedsDisplay(screenRect(of: item).insetBy(dx: -4, dy: -4))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffDuration) { [weak self] in
            guard let self, let item = self.handoffs.removeValue(forKey: id) else { return }
            self.setNeedsDisplay(self.screenRect(of: item).insetBy(dx: -4, dy: -4))
        }
    }

    /// Call when the canvas scrolls or zooms, since the strokes move on screen.
    func viewportDidChange() {
        guard live != nil || !handoffs.isEmpty else { return }
        liveRect = live.map(screenRect(of:)) ?? .null
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for item in Array(handoffs.values) + [live].compactMap({ $0 }) {
            guard let pageView = item.pageView else { continue }
            context.saveGState()
            context.clip(to: pageView.convert(pageView.bounds, to: self))
            context.concatenate(pageTransform(pageView))
            context.setFillColor(item.color)
            context.addPath(item.path)
            context.fillPath(using: .winding)
            context.restoreGState()
        }
    }

    /// Maps page coordinates to overlay coordinates (the canvas only scales and moves pages).
    private func pageTransform(_ pageView: UIView) -> CGAffineTransform {
        let origin = pageView.convert(CGPoint.zero, to: self)
        let unit = pageView.convert(CGPoint(x: 1, y: 0), to: self)
        let scale = unit.x - origin.x
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
    }

    private func screenRect(of item: Item) -> CGRect {
        guard let pageView = item.pageView else { return .null }
        return item.path.boundingBoxOfPath.applying(pageTransform(pageView))
    }
}
#endif
