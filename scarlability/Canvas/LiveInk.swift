#if os(iOS)
import QuartzCore
import ScarlabilityKit
import UIKit

/// Everything drawn on top of the finished pages while you work: the stroke being written,
/// just-finished strokes waiting for the page tiles, the eraser circle, the lasso, the selection
/// box and the preview of a selection being moved.
///
/// Strokes are drawn inside the zoomed content at the same resolution and on the same pixel grid
/// as the tiles. Pen strokes sit above the pages; highlighter strokes go inside each page between
/// its paper and ink layers, so they're behind the writing like finished highlights. When the
/// tiles have redrawn a finished stroke, its copy here fades out over a moment instead of
/// vanishing, which hides the tiny difference in how the screen places tiles.
///
/// A see-through highlight drawn twice looks darker, so live highlights aren't see-through:
/// they're the color a highlight makes on that paper, and only ever darken what's under them
/// toward it. Over an older highlight, or over its own finished copy while it fades out, that
/// changes nothing, so a highlight never flashes darker while you draw it or when you lift.
final class LiveInk {
    struct Item {
        var path: CGPath
        var color: CGColor
        var tool: InkTool
        /// Origin of the page whose coordinates the path is in, in content coordinates.
        var pageOrigin: CGPoint
    }

    /// A page's layer for live highlights.
    struct HighlighterHost {
        var layer: CALayer
        /// The page's frame, in content coordinates.
        var frame: CGRect
        var paper: PaperStyle
    }

    /// Where ink may appear (all the pages), in content coordinates.
    var writingArea: CGRect = .infinite
    /// Pixels per content point; set to what the page tiles use at the current zoom.
    var rasterScale: CGFloat = 2
    /// The highlighter hosts of the pages overlapping a content rect.
    var highlighterHosts: (CGRect) -> [HighlighterHost] = { _ in [] }

    private let host: CALayer
    private var livePen = LiveStrokeTiles()
    private var liveHighlights: [StrokeInkLayer] = []
    private var handoffs: [UUID: [CALayer]] = [:]
    private let preview = StrokeInkLayer()
    private let eraser = CAShapeLayer()
    private let lasso = CAShapeLayer()
    private let selection = CAShapeLayer()
    private let selectionHandles = CAShapeLayer()

    /// If the pages somehow never report back, stop showing a handed-off stroke after this long.
    private static let handoffTimeout: TimeInterval = 0.6
    private static let fadeDuration: CFTimeInterval = 0.12

    init(host: CALayer) {
        self.host = host
        host.addSublayer(livePen)
        host.addSublayer(preview)
        let tint = UIColor.systemBlue.cgColor
        eraser.fillColor = UIColor.white.withAlphaComponent(0.4).cgColor
        eraser.strokeColor = UIColor.gray.cgColor
        lasso.fillColor = nil
        lasso.strokeColor = tint
        selection.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        selection.strokeColor = tint
        selectionHandles.fillColor = UIColor.white.cgColor
        selectionHandles.strokeColor = tint
        for (index, layer) in [eraser, lasso, selection, selectionHandles].enumerated() {
            layer.zPosition = 20 + CGFloat(index)
            layer.actions = ["path": NSNull(), "lineWidth": NSNull(), "lineDashPattern": NSNull(), "hidden": NSNull()]
            layer.isHidden = true
            host.addSublayer(layer)
        }
    }

    // MARK: - Strokes

    func showLiveStroke(_ points: [InkPoint], color: InkColor, tool: InkTool, pageOrigin: CGPoint) {
        if tool == .highlighter {
            let item = Item(path: StrokeGeometry.chiselPath(for: points), color: color.cgColor, tool: tool, pageOrigin: pageOrigin)
            liveHighlights = placeHighlight(item, color: color, reusing: liveHighlights, growing: true)
        } else {
            livePen.show(points, color: color.cgColor, pageOrigin: pageOrigin, writingArea: writingArea, rasterScale: rasterScale)
        }
    }

    /// A highlight snapped to PDF text: one sideways band per text line (page coordinates).
    func showLiveHighlight(lines: [[InkPoint]], color: InkColor, pageOrigin: CGPoint) {
        let item = Item(path: Self.highlightPath(lines), color: color.cgColor, tool: .highlighter, pageOrigin: pageOrigin)
        liveHighlights = placeHighlight(item, color: color, reusing: liveHighlights, growing: true)
    }

    /// Like `handOff`, for a highlight snapped to PDF text.
    func handOffHighlight(id: UUID, lines: [[InkPoint]], color: InkColor, pageOrigin: CGPoint) {
        let item = Item(path: Self.highlightPath(lines), color: color.cgColor, tool: .highlighter, pageOrigin: pageOrigin)
        handoffs[id] = placeHighlight(item, color: color, reusing: [], growing: false)
        clearLiveStroke()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffTimeout) { [weak self] in
            self?.endHandOff(id)
        }
    }

    private static func highlightPath(_ lines: [[InkPoint]]) -> CGPath {
        let path = CGMutablePath()
        for line in lines {
            path.addPath(StrokeGeometry.chiselPath(for: line))
        }
        return path
    }

    func clearLiveStroke() {
        livePen.reset()
        liveHighlights.forEach { $0.removeFromSuperlayer() }
        liveHighlights = []
    }

    /// Replaces the live stroke with its finished shape, shown until `endHandOff(id)`.
    ///
    /// For the pen, the live stroke's own tiles become the finished copy (just redrawn without
    /// the prediction), so nothing has to be rebuilt the moment the pen lifts.
    func handOff(id: UUID, points: [InkPoint], color: InkColor, tool: InkTool, pageOrigin: CGPoint) {
        if tool == .highlighter {
            let item = Item(path: StrokeGeometry.chiselPath(for: points), color: color.cgColor, tool: tool, pageOrigin: pageOrigin)
            handoffs[id] = placeHighlight(item, color: color, reusing: [], growing: false)
        } else {
            livePen.show(points, color: color.cgColor, pageOrigin: pageOrigin, writingArea: writingArea, rasterScale: rasterScale)
            handoffs[id] = [livePen]
            livePen = LiveStrokeTiles()
            host.addSublayer(livePen)
        }
        clearLiveStroke()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffTimeout) { [weak self] in
            self?.endHandOff(id)
        }
    }

    func endHandOff(_ id: UUID) {
        guard let layers = handoffs.removeValue(forKey: id) else { return }
        for layer in layers {
            CATransaction.begin()
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            fade.duration = Self.fadeDuration
            layer.opacity = 0
            layer.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    /// Shows strokes (in content coordinates) and text boxes/images (each with the transform
    /// from its page into content coordinates) being moved, resized or rotated.
    func showPreview(_ items: [Item], objects: [(RenderedItem, CGAffineTransform)] = []) {
        preview.configure(writingArea: writingArea, rasterScale: rasterScale, hostOrigin: .zero)
        preview.show(items, objects: objects, growing: false)
    }

    func clearPreview() {
        preview.clear()
    }

    /// A highlight is drawn in every page it overlaps, each part inside that page.
    private func placeHighlight(_ item: Item, color: InkColor, reusing existing: [StrokeInkLayer], growing: Bool) -> [StrokeInkLayer] {
        let bounds = item.path.boundingBoxOfPath.offsetBy(dx: item.pageOrigin.x, dy: item.pageOrigin.y)
        var layers: [StrokeInkLayer] = []
        for (index, page) in highlighterHosts(bounds).enumerated() {
            let layer = index < existing.count ? existing[index] : StrokeInkLayer()
            if layer.superlayer !== page.layer {
                page.layer.addSublayer(layer)
            }
            // What the highlight looks like on this paper, solid, only ever darkening what's
            // under it (lightening, on dark paper, where highlights brighten the page).
            var solid = item
            solid.color = color.highlighted(on: page.paper.color).cgColor
            layer.opacity = 1
            layer.drawsHighlightsSolid = true
            layer.compositingFilter = page.paper.isDark ? "lightenBlendMode" : "darkenBlendMode"
            layer.configure(writingArea: page.frame, rasterScale: rasterScale, hostOrigin: page.frame.origin)
            layer.show([solid], growing: growing)
            layers.append(layer)
        }
        existing.dropFirst(layers.count).forEach { $0.removeFromSuperlayer() }
        return layers
    }

    // MARK: - Eraser, lasso and selection

    /// - Parameter zoom: Current zoom, so outlines stay the same thickness on screen.
    func showEraser(at center: CGPoint, radius: CGFloat, zoom: CGFloat) {
        eraser.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        eraser.lineWidth = 1 / zoom
        eraser.isHidden = false
    }

    func hideEraser() {
        eraser.isHidden = true
    }

    func showLasso(_ path: CGPath, zoom: CGFloat) {
        lasso.path = path
        lasso.lineWidth = 1.5 / zoom
        lasso.lineDashPattern = [NSNumber(value: Double(6 / zoom)), NSNumber(value: Double(4 / zoom))]
        lasso.isHidden = false
    }

    func hideLasso() {
        lasso.isHidden = true
    }

    /// Draws the selection box, turned by `rotation` around its center, with its handles.
    func showSelection(_ handles: SelectionHandles, zoom: CGFloat) {
        selection.path = handles.outline
        selection.lineWidth = 1 / zoom
        selection.lineDashPattern = [NSNumber(value: Double(5 / zoom)), NSNumber(value: Double(3 / zoom))]
        let marks = CGMutablePath()
        let radius = SelectionHandles.handleRadius / zoom
        for center in [handles.resize, handles.rotate] {
            marks.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        }
        marks.move(to: handles.rotateStem.0)
        marks.addLine(to: handles.rotateStem.1)
        selectionHandles.path = marks
        selectionHandles.lineWidth = 1.5 / zoom
        selection.isHidden = false
        selectionHandles.isHidden = false
    }

    func hideSelection() {
        selection.isHidden = true
        selectionHandles.isHidden = true
    }
}

/// The pen stroke being written, drawn in small tiles so each frame only redraws the tile or two
/// where the pen is, however long the stroke gets.
private final class LiveStrokeTiles: CALayer {
    private struct TileKey: Hashable {
        var column: Int
        var row: Int
    }

    private var points: [InkPoint] = []
    private var color: CGColor = CGColor(gray: 0, alpha: 1)
    /// In content coordinates; the tile grid is anchored here, like that page's tiles.
    private var pageOrigin: CGPoint = .zero
    private var writingArea: CGRect = .infinite
    private var rasterScale: CGFloat = 2
    private var tiles: [TileKey: Tile] = [:]

    /// Tiles are this many pixels square.
    private static let tilePixels: CGFloat = 256

    override init() {
        super.init()
        zPosition = 10
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func action(forKey event: String) -> CAAction? { NSNull() }

    private var tileSize: CGFloat { Self.tilePixels / rasterScale }

    func show(_ newPoints: [InkPoint], color: CGColor, pageOrigin: CGPoint, writingArea: CGRect, rasterScale: CGFloat) {
        if points.isEmpty {
            self.pageOrigin = pageOrigin
            self.writingArea = writingArea
            self.rasterScale = rasterScale
        }
        self.color = color
        // Only the end of the stroke changes from frame to frame: find where.
        let common = min(points.count, newPoints.count)
        var first = max(0, common - 200)
        while first < common, points[first] == newPoints[first] {
            first += 1
        }
        let start = max(0, first - 3)
        var dirty = CGRect.null
        for point in points.dropFirst(start) + newPoints.dropFirst(start) {
            let r = CGFloat(point.width) / 2 + 2
            dirty = dirty.union(CGRect(x: CGFloat(point.x) - r, y: CGFloat(point.y) - r, width: 2 * r, height: 2 * r))
        }
        points = newPoints
        guard !dirty.isNull else { return }
        redrawTiles(in: dirty.offsetBy(dx: pageOrigin.x, dy: pageOrigin.y).intersection(writingArea))
    }

    func reset() {
        points = []
        tiles.values.forEach { $0.removeFromSuperlayer() }
        tiles = [:]
    }

    /// Redraws (creating if needed) the tiles covering a rect in content coordinates.
    private func redrawTiles(in rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        let size = tileSize
        let columns = Int(floor((rect.minX - pageOrigin.x) / size))...Int(floor((rect.maxX - pageOrigin.x) / size))
        let rows = Int(floor((rect.minY - pageOrigin.y) / size))...Int(floor((rect.maxY - pageOrigin.y) / size))
        for column in columns {
            for row in rows {
                let key = TileKey(column: column, row: row)
                let tile = tiles[key] ?? {
                    let tile = Tile()
                    tile.owner = self
                    tile.contentsScale = rasterScale
                    tile.frame = CGRect(x: pageOrigin.x + CGFloat(column) * size, y: pageOrigin.y + CGFloat(row) * size, width: size, height: size)
                    addSublayer(tile)
                    tiles[key] = tile
                    return tile
                }()
                tile.setNeedsDisplay()
            }
        }
    }

    fileprivate func draw(_ tile: Tile, in context: CGContext) {
        // Work in content coordinates, then in the stroke's page coordinates.
        context.translateBy(x: -tile.frame.minX, y: -tile.frame.minY)
        context.clip(to: writingArea.intersection(tile.frame))
        context.translateBy(x: pageOrigin.x, y: pageOrigin.y)
        let area = tile.frame.offsetBy(dx: -pageOrigin.x, dy: -pageOrigin.y)
        context.setFillColor(color)
        context.addPath(StrokeGeometry.path(for: points, near: area))
        context.fillPath(using: .winding)
    }

    fileprivate final class Tile: CALayer {
        weak var owner: LiveStrokeTiles?

        override func action(forKey event: String) -> CAAction? { NSNull() }

        override func draw(in context: CGContext) {
            owner?.draw(self, in: context)
        }
    }
}

/// Where a selection's box and handles are, in content coordinates.
struct SelectionHandles {
    /// Handle size on screen, in points.
    static let handleRadius: CGFloat = 7
    /// How far above the box the rotate handle sits, on screen.
    static let rotateOffset: CGFloat = 28

    var outline: CGPath
    var resize: CGPoint
    var rotate: CGPoint
    var rotateStem: (CGPoint, CGPoint)

    /// - Parameter shape: The outline to draw instead of the box (a freeform selection's loop),
    ///   already moved and turned like the selection.
    init(box: CGRect, rotation: CGFloat, zoom: CGFloat, shape: CGPath? = nil) {
        let center = CGPoint(x: box.midX, y: box.midY)
        let turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).translatedBy(x: -center.x, y: -center.y)
        var outlineTransform = turn
        outline = shape ?? CGPath(rect: box, transform: &outlineTransform)
        resize = CGPoint(x: box.maxX, y: box.maxY).applying(turn)
        let top = CGPoint(x: box.midX, y: box.minY)
        rotate = CGPoint(x: box.midX, y: box.minY - Self.rotateOffset / zoom).applying(turn)
        rotateStem = (top.applying(turn), rotate)
    }
}

/// Strokes rasterized like the page tiles.
private final class StrokeInkLayer: CALayer {
    private var writingArea: CGRect = .infinite
    private var rasterScale: CGFloat = 2
    /// Where this layer's parent sits, in content coordinates.
    private var hostOrigin: CGPoint = .zero
    private var items: [LiveInk.Item] = []
    /// Text boxes and images, drawn under the strokes.
    private var objects: [(RenderedItem, CGAffineTransform)] = []
    /// Highlights are already their final, solid color (live highlights), not see-through.
    var drawsHighlightsSolid = false

    override init() {
        super.init()
        zPosition = 10
        isOpaque = false
        isHidden = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Moving and resizing must be instant, not animated (fading is added explicitly).
    override func action(forKey event: String) -> CAAction? { NSNull() }

    func configure(writingArea: CGRect, rasterScale: CGFloat, hostOrigin: CGPoint) {
        self.writingArea = writingArea
        self.rasterScale = rasterScale
        self.hostOrigin = hostOrigin
    }

    /// - Parameter growing: Keep the layer at least as big as before. While a stroke grows, that
    ///   saves reallocating the backing image on every frame.
    func show(_ items: [LiveInk.Item], objects: [(RenderedItem, CGAffineTransform)] = [], growing: Bool) {
        self.items = items
        self.objects = objects
        guard !items.isEmpty || !objects.isEmpty else {
            clear()
            return
        }
        var area = CGRect.null
        for item in items {
            area = area.union(item.path.boundingBoxOfPath.offsetBy(dx: item.pageOrigin.x, dy: item.pageOrigin.y))
        }
        for (object, transform) in objects {
            area = area.union(object.item.bounds.applying(transform))
        }
        area = area.insetBy(dx: -2, dy: -2).intersection(writingArea)
        guard !area.isNull, !area.isEmpty else {
            clear()
            return
        }
        if growing, !isHidden, !frame.isEmpty {
            area = area.union(frame.offsetBy(dx: hostOrigin.x, dy: hostOrigin.y))
        }
        // Snap to the pixel grid of the first item's page, which is where that page's tiles are.
        let scale = rasterScale, grid = items.first?.pageOrigin ?? .zero
        func snapDown(_ value: CGFloat, _ origin: CGFloat) -> CGFloat { origin + floor((value - origin) * scale) / scale }
        func snapUp(_ value: CGFloat, _ origin: CGFloat) -> CGFloat { origin + ceil((value - origin) * scale) / scale }
        let minX = snapDown(area.minX, grid.x), minY = snapDown(area.minY, grid.y)
        let maxX = snapUp(area.maxX, grid.x), maxY = snapUp(area.maxY, grid.y)

        contentsScale = scale
        frame = CGRect(x: minX - hostOrigin.x, y: minY - hostOrigin.y, width: maxX - minX, height: maxY - minY)
        isHidden = false
        setNeedsDisplay()
    }

    func clear() {
        items = []
        objects = []
        isHidden = true
        frame = .zero
    }

    override func draw(in context: CGContext) {
        // Work in content coordinates.
        context.translateBy(x: -frame.minX - hostOrigin.x, y: -frame.minY - hostOrigin.y)
        context.clip(to: writingArea)
        for (object, transform) in objects {
            context.saveGState()
            context.concatenate(transform)
            ItemRenderer.draw(object, paper: nil, in: context)
            context.restoreGState()
        }
        // Live highlights are already their final color; anywhere else (a selection being moved),
        // highlights are drawn at their opacity, behind the ink.
        let highlights = items.filter { $0.tool == .highlighter }
        if drawsHighlightsSolid || highlights.isEmpty {
            fill(items, in: context)
        } else {
            context.saveGState()
            context.setAlpha(PageRenderer.highlighterOpacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            fill(highlights, in: context)
            context.endTransparencyLayer()
            context.restoreGState()
            fill(items.filter { $0.tool == .pen }, in: context)
        }
    }

    private func fill(_ items: [LiveInk.Item], in context: CGContext) {
        for item in items {
            context.saveGState()
            context.translateBy(x: item.pageOrigin.x, y: item.pageOrigin.y)
            context.setFillColor(item.color)
            context.addPath(item.path)
            context.fillPath(using: .winding)
            context.restoreGState()
        }
    }
}
#endif
