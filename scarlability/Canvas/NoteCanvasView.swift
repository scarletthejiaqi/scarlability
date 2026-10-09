#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

struct NoteCanvas: UIViewRepresentable {
    let document: NoteDocument
    let settings: ToolSettings

    func makeUIView(context: Context) -> NoteCanvasView {
        NoteCanvasView(document: document, settings: settings)
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        canvas.drawsWithFinger = settings.drawsWithFinger
        canvas.tool = settings.tool
    }
}

/// The writing surface: pages stacked edge to edge in a scroll view.
///
/// - Apple Pencil uses the current tool (pen, highlighter, eraser, select); fingers scroll and
///   pinch-zoom (unless "Draw with finger" is on: then one finger uses the tool and two scroll).
/// - Writing can run from one page onto the next.
/// - Draw a shape and hold still to snap it to a clean line, circle, rectangle or polygon.
/// - Pinch-zoom locks at "page width fills the screen" and "whole page fits".
/// - Two-finger tap undoes, three-finger tap redoes; Apple Pencil double-tap does what the iPad's
///   Apple Pencil setting says.
/// - Content is laid out in page points; zooming scales it, and the page tiles redraw sharply.
final class NoteCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    UIEditMenuInteractionDelegate, UIPencilInteractionDelegate {
    private let document: NoteDocument
    private let settings: ToolSettings

    private let scrollView = CanvasScrollView()
    private let contentView = UIView()
    private lazy var liveInk = LiveInk(host: contentView.layer)
    private let strokeRecognizer = StrokeGestureRecognizer()
    private let zoomPinch = UIPinchGestureRecognizer()
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()
    /// One finger moving or resizing a selection (when fingers don't draw).
    private let selectionPan = UIPanGestureRecognizer()
    /// One finger tapping with the select tool: show the menu, deselect, or offer Paste.
    private let selectionTap = UITapGestureRecognizer()
    private var editMenu: UIEditMenuInteraction?

    private var pageViews: [UUID: PageView] = [:]
    /// Which pages currently show the thin line along their bottom edge (all but the last).
    private var pagesWithBottomEdge: Set<UUID> = []
    /// Stroke outlines are built once and reused for every redraw.
    private var renderedStrokes: [UUID: RenderedStroke] = [:]
    /// Strokes left out of the page tiles while a selection of them is being dragged.
    private var hiddenStrokeIDs: Set<UUID> = []
    private var pendingHandoffs: [PendingHandoff] = []
    private var pinchStart: (position: CGFloat, anchor: CGPoint)?
    private var zoomDetents = ZoomDetents(zooms: [])
    private var lastPencilActivity = Date.distantPast
    private var laidOutSize: CGSize = .zero
    /// Zoom relative to "page width fills the screen", kept when the window resizes or rotates.
    private var relativeZoom: CGFloat = 1

    // What the current touch is doing.
    private var activeStroke: ActiveStroke?
    private var eraserPosition: CGPoint?
    private var lasso: [CGPoint]?
    private var manipulation: Manipulation?
    private var selection: Selection?

    private struct ActiveStroke {
        var pageID: UUID
        var pageView: PageView
        var tool: InkTool
        var builder: StrokeBuilder
        /// The color saved with the stroke.
        var color: InkColor
        /// The color it's drawn in (black ink shows white on dark paper).
        var displayColor: InkColor
        var sampleIndexByEstimationIndex: [Int: Int] = [:]
        /// Where the pen last moved to; if it stays near here long enough, the shape snaps.
        var holdAnchor: CGPoint?
        var holdTimer: DispatchWorkItem?
        /// Set once the stroke has snapped to a clean shape.
        var shape: ShapeRecognizer.Shape?
    }

    /// Selected strokes and the box around them, in content coordinates.
    private struct Selection {
        var strokes: [NoteDocument.PlacedStroke]
        var box: CGRect
    }

    /// A selection being moved, resized or rotated. The transform is in content coordinates.
    private struct Manipulation {
        enum Kind {
            case move(start: CGPoint)
            case resize(anchor: CGPoint, startDistance: CGFloat)
            case rotate(center: CGPoint, startAngle: CGFloat)
        }

        var kind: Kind
        var transform: CGAffineTransform = .identity
        var widthScale: CGFloat = 1
        var rotation: CGFloat = 0
    }

    /// A finished stroke that the live ink keeps showing until the page tiles have drawn it.
    private struct PendingHandoff {
        struct Key: Hashable {
            var pageID: UUID
            var isInk: Bool
        }

        struct Wait {
            /// The tile content version that includes the stroke.
            var version: Int
            /// The visible part of the stroke on this page, in page coordinates.
            var area: CGRect
            var drawnTiles: [CGRect] = []
        }

        var id: UUID
        var waits: [Key: Wait]
        var startedAt = Date()
    }

    /// Gray space around the column of pages, in page points.
    private static let pageMargin: CGFloat = 14
    private static let bottomMargin: CGFloat = 80
    /// Maximum zoom, relative to "page width fills the screen".
    private static let maxZoom: CGFloat = 5
    private static let pageEdgeColor = InkColor(hex: 0xD1D1D6)
    /// Touches bigger than this (in points) are a palm, not a finger. iPads report touch size in
    /// steps of about 10.4 points, and a fingertip is often 31.
    private static let maxFingerRadius: CGFloat = 45
    /// Finger taps right after writing are usually the palm lifting, not an undo.
    private static let tapQuietPeriod: TimeInterval = 0.35
    /// Hold the pen this still (screen points) for this long to snap a shape.
    private static let holdTolerance: CGFloat = 3
    private static let holdDuration: TimeInterval = 0.5
    /// How far the select tool can move (screen points) and still count as a tap.
    private static let tapSlop: CGFloat = 6
    /// How close (screen points) a touch must be to a selection handle to grab it.
    private static let handleReach: CGFloat = 22
    private static let duplicateOffset: CGFloat = 24
    private static let inkPasteboardType = "scarlability.ink"

    var drawsWithFinger = false {
        didSet {
            if drawsWithFinger != oldValue { configureTouchTypes() }
        }
    }

    var tool: Tool = .pen {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .select { clearSelection() }
            configureTouchTypes()
        }
    }

    init(document: NoteDocument, settings: ToolSettings) {
        self.document = document
        self.settings = settings
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.blocksPanning = { [weak self] location in
            guard let self else { return false }
            if self.activeStroke != nil || self.manipulation != nil { return true }
            // Dragging a selection with a finger moves it instead of scrolling.
            return self.tool == .select && self.selectionGrab(at: self.scrollView.convert(location, to: self.contentView)) != nil
        }
        // Real limits are set at layout. Zooming must be enabled for setZoomScale to work, but
        // pinching is handled by `zoomPinch` (for the zoom locks), so the built-in pinch is off.
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5
        scrollView.pinchGestureRecognizer?.isEnabled = false
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        liveInk.highlighterHosts = { [weak self] bounds in self?.highlighterHosts(overlapping: bounds) ?? [] }

        strokeRecognizer.coordinateView = contentView
        strokeRecognizer.addTarget(self, action: #selector(handleStroke(_:)))
        strokeRecognizer.delegate = self
        scrollView.addGestureRecognizer(strokeRecognizer)

        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        zoomPinch.allowedTouchTypes = [finger]
        zoomPinch.addTarget(self, action: #selector(handlePinch(_:)))
        zoomPinch.delegate = self
        scrollView.addGestureRecognizer(zoomPinch)

        for (tap, touches, action) in [(undoTap, 2, #selector(handleUndoTap)), (redoTap, 3, #selector(handleRedoTap))] {
            tap.numberOfTouchesRequired = touches
            tap.allowedTouchTypes = [finger]
            tap.addTarget(self, action: action)
            tap.delegate = self
            scrollView.addGestureRecognizer(tap)
        }

        selectionPan.allowedTouchTypes = [finger]
        selectionPan.maximumNumberOfTouches = 1
        selectionPan.addTarget(self, action: #selector(handleSelectionPan(_:)))
        selectionPan.delegate = self
        scrollView.addGestureRecognizer(selectionPan)
        selectionTap.allowedTouchTypes = [finger]
        selectionTap.addTarget(self, action: #selector(handleSelectionTap(_:)))
        selectionTap.delegate = self
        scrollView.addGestureRecognizer(selectionTap)

        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
        let pencil = UIPencilInteraction(delegate: self)
        addInteraction(pencil)

        drawsWithFinger = settings.drawsWithFinger
        tool = settings.tool
        configureTouchTypes()

        document.onChange = { [weak self] change in
            self?.documentDidChange(change)
        }
        syncPageViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout and zoom

    private var contentWidth: CGFloat {
        (document.pages.map(\.record.size.width).max() ?? PageSize.a4.width) + 2 * Self.pageMargin
    }

    /// Zoom at which the page width fills the screen.
    private var widthFitZoom: CGFloat { bounds.width / contentWidth }

    /// Resolution for the page tiles, chosen so they match the screen pixel for pixel at the
    /// normal writing zoom (page width fills the screen) and at 2×, 4×… that zoom.
    ///
    /// Tiles draw at the layer's scale times a power of two, the smallest one that's at least as
    /// sharp as the screen needs. With the screen's own scale, the normal zoom would get tiles at
    /// 4 px/pt shrunk to 2.6, so finished ink looked softer than the live stroke the moment the
    /// pen lifted. The 0.1% extra keeps rounding from picking the next level up.
    private var tileScale: CGFloat {
        let zoom = widthFitZoom
        guard zoom > 0 else { return traitCollection.displayScale }
        let level = pow(2, ceil(log2(zoom)))
        return traitCollection.displayScale * zoom / level * 1.001
    }

    /// Pixels per content point that the page tiles use at the current zoom.
    private var tileRasterScale: CGFloat {
        let base = tileScale
        let needed = scrollView.zoomScale * traitCollection.displayScale / base
        // PageTileLayer has levels from 1/8× to 8×.
        let level = min(max(ceil(log2(needed) - 1e-6), -3), 3)
        return base * pow(2, level)
    }

    /// Zoom at which a whole page fits on screen.
    private var pageFitZoom: CGFloat {
        guard let size = document.pages.first?.record.size else { return widthFitZoom }
        let inset = scrollView.adjustedContentInset
        let height = bounds.height - inset.top - inset.bottom
        return min(bounds.width / (size.width + 2 * Self.pageMargin), height / (size.height + 2 * Self.pageMargin))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0, bounds.size != laidOutSize else { return }
        let isFirstLayout = laidOutSize == .zero
        let widthChanged = bounds.width != laidOutSize.width
        laidOutSize = bounds.size

        zoomDetents = ZoomDetents(zooms: [widthFitZoom, pageFitZoom])
        for view in pageViews.values {
            view.tileScale = tileScale
        }
        scrollView.minimumZoomScale = min(widthFitZoom, pageFitZoom) * 0.6
        scrollView.maximumZoomScale = widthFitZoom * Self.maxZoom
        if widthChanged {
            scrollView.zoomScale = widthFitZoom * relativeZoom
        }
        layoutPages()
        if isFirstLayout {
            // Changing the zoom moves the scroll position; open the note at the top of page 1.
            let inset = scrollView.adjustedContentInset
            scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
            #if DEBUG
            startDebugScenarioIfRequested()
            #endif
        }
    }

    private func layoutPages() {
        let width = contentWidth
        var y = Self.pageMargin
        for page in document.pages {
            guard let view = pageViews[page.id] else { continue }
            let size = page.record.size
            view.frame = CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height)
            y += size.height
        }
        y += Self.bottomMargin
        let zoom = scrollView.zoomScale
        let size = CGSize(width: width, height: y)
        contentView.bounds = CGRect(origin: .zero, size: size)
        contentView.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scrollView.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        centerContent()
        liveInk.writingArea = pagesColumn()
    }

    /// Centers the pages horizontally when zoomed out narrower than the screen.
    private func centerContent() {
        let inset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    }

    /// All the pages, in content coordinates.
    private func pagesColumn() -> CGRect {
        let frames = document.pages.compactMap { pageViews[$0.id]?.frame }
        guard let first = frames.first else { return .null }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func highlighterHosts(overlapping bounds: CGRect) -> [LiveInk.HighlighterHost] {
        document.pages.compactMap { page in
            guard let view = pageViews[page.id], view.frame.intersects(bounds) else { return nil }
            return LiveInk.HighlighterHost(layer: view.highlighterHost, frame: view.frame)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if widthFitZoom > 0 {
            relativeZoom = scrollView.zoomScale / widthFitZoom
        }
        showSelectionOverlay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Remember which page is in the middle of the screen, for "this page" paper changes.
        let middle = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
        if let page = document.pages.first(where: { pageViews[$0.id]?.frame.minY ?? .infinity <= middle.y && middle.y < pageViews[$0.id]?.frame.maxY ?? -.infinity }) {
            document.visiblePageID = page.id
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            // The pinch moves the page itself from here on, including two-finger panning.
            scrollView.cancelPanning()
            editMenu?.dismissMenu()
            pinchStart = (zoomDetents.pinchPosition(forZoom: scrollView.zoomScale), pinch.location(in: contentView))
        case .changed:
            // Lifting one finger mid-pinch would make the center jump; wait for both.
            guard let start = pinchStart, pinch.numberOfTouches >= 2 else { return }
            let zoom = min(max(zoomDetents.zoom(forPinchPosition: start.position + log(pinch.scale)),
                               scrollView.minimumZoomScale), scrollView.maximumZoomScale)
            scrollView.zoomScale = zoom
            // Keep the spot that started under the fingers under them.
            let fingers = pinch.location(in: self)
            let inset = scrollView.adjustedContentInset
            let maxX = max(-inset.left, scrollView.contentSize.width - bounds.width + inset.right)
            let maxY = max(-inset.top, scrollView.contentSize.height - bounds.height + inset.bottom)
            scrollView.contentOffset = CGPoint(
                x: min(max(start.anchor.x * zoom - fingers.x, -inset.left), maxX),
                y: min(max(start.anchor.y * zoom - fingers.y, -inset.top), maxY)
            )
        default:
            pinchStart = nil
        }
    }

    // MARK: - Document changes

    private func documentDidChange(_ change: NoteDocument.Change) {
        if let selection, manipulation == nil, selection.strokes.contains(where: { placed in
            !(document.pages.first { $0.id == placed.pageID }?.visibleStrokes.contains { $0.id == placed.stroke.id } ?? false)
        }) {
            clearSelection()
        }
        switch change {
        case .pagesChanged:
            syncPageViews()
        case .inkChanged(let pageID, let area):
            updateInk(onPage: pageID, changedRect: area)
        case .pageRedraw(let pageID):
            updateInk(onPage: pageID, changedRect: nil)
        }
    }

    private func syncPageViews() {
        let ids = Set(document.pages.map(\.id))
        for (id, view) in pageViews where !ids.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
            pagesWithBottomEdge.remove(id)
        }
        for page in document.pages where pageViews[page.id] == nil {
            let view = PageView()
            view.tileScale = tileScale
            let id = page.id
            view.setTileDrawnHandler { [weak self] role, rect, version in
                Task { @MainActor [self] in self?.tileDidDraw(onPage: id, isInk: role == .ink, rect: rect, version: version) }
            }
            contentView.addSubview(view)
            pageViews[id] = view
            updateInk(onPage: id, changedRect: nil)
        }
        // Every page but the last has a thin line along its bottom edge.
        for page in document.pages where (page.id != document.pages.last?.id) != pagesWithBottomEdge.contains(page.id) {
            updateInk(onPage: page.id, changedRect: CGRect(x: 0, y: page.record.size.height - 2, width: page.record.size.width, height: 2))
        }
        layoutPages()
    }

    private func updateInk(onPage pageID: UUID, changedRect: CGRect?) {
        guard let page = document.pages.first(where: { $0.id == pageID }), let view = pageViews[pageID] else { return }
        let strokes = page.visibleStrokes.filter { !hiddenStrokeIDs.contains($0.id) }.map(rendered)
        let hasBottomEdge = pageID != document.pages.last?.id
        if hasBottomEdge {
            pagesWithBottomEdge.insert(pageID)
        } else {
            pagesWithBottomEdge.remove(pageID)
        }
        view.setContent(
            PageContent(
                paper: page.record.paper,
                size: page.record.size,
                strokes: strokes,
                bottomEdgeColor: hasBottomEdge ? Self.pageEdgeColor : nil
            ),
            changedRect: changedRect
        )
    }

    private func rendered(_ stroke: Stroke) -> RenderedStroke {
        if let cached = renderedStrokes[stroke.id] { return cached }
        let rendered = RenderedStroke(stroke)
        renderedStrokes[stroke.id] = rendered
        return rendered
    }

    private func pageOrigin(_ pageID: UUID) -> CGPoint {
        pageViews[pageID]?.frame.origin ?? .zero
    }

    // MARK: - Touches

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        if recognizer.touchType == .pencil {
            lastPencilActivity = Date()
        }
        switch tool {
        case .pen, .highlighter:
            handleDrawing(recognizer)
        case .eraser:
            handleEraser(recognizer)
        case .select:
            handleSelect(recognizer)
        }
    }

    // MARK: - Pen and highlighter

    private func handleDrawing(_ recognizer: StrokeGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginStroke(recognizer)
        case .changed:
            consumeSamples(recognizer)
        case .ended:
            consumeSamples(recognizer)
            finishStroke()
        case .cancelled, .failed:
            cancelStroke()
        default:
            break
        }
    }

    private func beginStroke(_ recognizer: StrokeGestureRecognizer) {
        let samples = recognizer.takeSamples()
        guard let start = samples.first,
              let page = document.pages.first(where: { pageViews[$0.id]?.frame.contains(start.location) == true }),
              let pageView = pageViews[page.id] else {
            // Started outside the pages: ignore this stroke.
            return
        }
        // Writing stops any scrolling in progress (e.g. a palm that landed first).
        scrollView.stopScrolling()
        liveInk.rasterScale = tileRasterScale

        let isHighlighter = tool == .highlighter
        let presets = isHighlighter ? settings.highlighter : settings.pen
        activeStroke = ActiveStroke(
            pageID: page.id,
            pageView: pageView,
            tool: isHighlighter ? .highlighter : .pen,
            builder: StrokeBuilder(
                baseWidth: presets.currentSize,
                // The highlighter's chisel tip doesn't respond to pressure.
                curve: isHighlighter ? PressureCurve(sensitivity: 0) : settings.pressureCurve,
                // Smoothing is set in screen points, so it feels the same at any zoom.
                smoothing: StrokeSmoothing.screenRadius / scrollView.zoomScale
            ),
            color: presets.currentColor,
            displayColor: isHighlighter ? presets.currentColor : presets.currentColor.displayed(on: page.record.paper)
        )
        add(samples, forceUpdates: [], predicted: recognizer.predictedLocations)
        document.beginWriting(onPage: page.id)
    }

    private func consumeSamples(_ recognizer: StrokeGestureRecognizer) {
        add(recognizer.takeSamples(), forceUpdates: recognizer.takeForceUpdates(), predicted: recognizer.predictedLocations)
    }

    private func add(_ samples: [StrokeGestureRecognizer.Sample], forceUpdates: [StrokeGestureRecognizer.ForceUpdate], predicted: [CGPoint]) {
        guard var active = activeStroke else { return }
        // Once snapped to a shape, the stroke stays that shape until the pen lifts.
        guard active.shape == nil else { return }
        let origin = active.pageView.frame.origin
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }

        for sample in samples {
            if let index = active.builder.add(local(sample.location), force: sample.force), let estimation = sample.estimationIndex {
                active.sampleIndexByEstimationIndex[estimation] = index
            }
        }
        for update in forceUpdates {
            if let index = active.sampleIndexByEstimationIndex[update.estimationIndex] {
                active.builder.updateForce(update.force, at: index)
            }
        }
        // Moving more than a little restarts the "hold still to snap" countdown.
        if let tip = samples.last.map({ local($0.location) }),
           active.holdAnchor.map({ tip.distance(to: $0) > Self.holdTolerance / scrollView.zoomScale }) ?? true {
            active.holdAnchor = tip
            active.holdTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in self?.snapToShape() }
            active.holdTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: timer)
        }
        activeStroke = active
        liveInk.showLiveStroke(active.builder.livePoints(predicted: predicted.map(local)),
                               color: active.displayColor, tool: active.tool, pageOrigin: origin)
    }

    /// The pen has held still: if the stroke looks like a shape, replace it with a clean one.
    private func snapToShape() {
        guard var active = activeStroke, active.shape == nil else { return }
        let points = active.builder.finishedPoints()
        guard let shape = ShapeRecognizer.recognize(points.map(\.location), linesOnly: active.tool == .highlighter) else { return }
        active.shape = shape
        activeStroke = active
        liveInk.showLiveStroke(shapePoints(shape, from: points), color: active.displayColor, tool: active.tool,
                               pageOrigin: active.pageView.frame.origin)
    }

    /// A snapped shape is drawn at the stroke's average width.
    private func shapePoints(_ shape: ShapeRecognizer.Shape, from points: [InkPoint]) -> [InkPoint] {
        let width = points.map(\.width).reduce(0, +) / Float(max(points.count, 1))
        return ShapeRecognizer.points(for: shape, width: width)
    }

    private func finishStroke() {
        guard let active = activeStroke else { return }
        activeStroke = nil
        active.holdTimer?.cancel()
        var points = active.builder.finishedPoints()
        if let shape = active.shape {
            points = shapePoints(shape, from: points)
        }
        guard !points.isEmpty else {
            liveInk.clearLiveStroke()
            document.cancelWriting()
            return
        }

        let origin = active.pageView.frame.origin
        let path = active.tool == .highlighter ? StrokeGeometry.chiselPath(for: points) : StrokeGeometry.path(for: points)
        let pieces = place(toContent(points, from: origin), tool: active.tool, color: active.color, createdAt: Date())
        let handoffID = UUID()
        liveInk.handOff(id: handoffID, path: path, color: active.displayColor, tool: active.tool, pageOrigin: origin)
        document.addStroke(pieces)
        waitForTiles(handoffID, toShow: pieces)
    }

    private func cancelStroke() {
        guard let active = activeStroke else { return }
        active.holdTimer?.cancel()
        activeStroke = nil
        liveInk.clearLiveStroke()
        document.cancelWriting()
    }

    private func toContent(_ points: [InkPoint], from origin: CGPoint) -> [InkPoint] {
        points.map { InkPoint(x: $0.x + Float(origin.x), y: $0.y + Float(origin.y), width: $0.width) }
    }

    /// Turns points in content coordinates into strokes, one piece per page they touch.
    private func place(_ contentPoints: [InkPoint], tool: InkTool, color: InkColor, createdAt: Date) -> [NoteDocument.PlacedStroke] {
        let pages = document.pages
        let frames = pages.map { pageViews[$0.id]?.frame ?? .null }
        return PageSplitter.split(contentPoints, pageFrames: frames).map { piece in
            let stroke = Stroke(tool: tool, color: color, points: piece.points, createdAt: createdAt)
            renderedStrokes[stroke.id] = RenderedStroke(stroke)
            return NoteDocument.PlacedStroke(stroke: stroke, pageID: pages[piece.pageIndex].id)
        }
    }

    // MARK: - Eraser

    private func handleEraser(_ recognizer: StrokeGestureRecognizer) {
        let locations = recognizer.takeSamples().map(\.location)
        switch recognizer.state {
        case .began:
            guard let start = locations.first else { return }
            scrollView.stopScrolling()
            document.beginGroup()
            eraserPosition = start
            erase(along: [start] + locations)
        case .changed:
            erase(along: locations)
        default:
            erase(along: locations)
            eraserPosition = nil
            liveInk.hideEraser()
            document.endGroup()
        }
    }

    /// Erases along a path in content coordinates, continuing from the last eraser position.
    private func erase(along locations: [CGPoint]) {
        guard var from = eraserPosition, let last = locations.last else { return }
        let radius = CGFloat(settings.eraserRadius)
        var change = NoteDocument.StrokeChange()
        for to in locations {
            for page in document.pages {
                let reach = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                    .insetBy(dx: -radius, dy: -radius)
                guard let view = pageViews[page.id], view.frame.intersects(reach) else { continue }
                let a = CGPoint(x: from.x - view.frame.minX, y: from.y - view.frame.minY)
                let b = CGPoint(x: to.x - view.frame.minX, y: to.y - view.frame.minY)
                let alreadyRemoved = Set(change.removed.map(\.stroke.id))
                for stroke in page.visibleStrokes where !alreadyRemoved.contains(stroke.id) {
                    if settings.erasesHighlighterOnly, stroke.tool != .highlighter { continue }
                    switch settings.eraserMode {
                    case .wholeStroke:
                        if StrokeHitTesting.eraser(from: a, to: b, radius: radius, touches: stroke) {
                            change.removed.append(.init(stroke: stroke, pageID: page.id))
                        }
                    case .partial:
                        if let pieces = StrokeHitTesting.erase(stroke, from: a, to: b, radius: radius) {
                            change.removed.append(.init(stroke: stroke, pageID: page.id))
                            change.added += pieces.map { .init(stroke: stroke.replacement(points: $0), pageID: page.id) }
                        }
                    }
                }
            }
            from = to
        }
        eraserPosition = last
        liveInk.showEraser(at: last, radius: radius, zoom: scrollView.zoomScale)
        if !change.removed.isEmpty {
            document.apply(change)
        }
    }

    // MARK: - Select

    private func handleSelect(_ recognizer: StrokeGestureRecognizer) {
        let locations = recognizer.takeSamples().map(\.location)
        switch recognizer.state {
        case .began:
            guard let start = locations.first else { return }
            scrollView.stopScrolling()
            beginSelectGesture(at: start)
            locations.dropFirst().forEach(continueSelectGesture)
        case .changed:
            locations.forEach(continueSelectGesture)
        case .ended:
            locations.forEach(continueSelectGesture)
            endSelectGesture()
        default:
            cancelSelectGesture()
        }
    }

    @objc private func handleSelectionPan(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: contentView)
        switch pan.state {
        case .began:
            beginSelectGesture(at: location)
        case .changed:
            continueSelectGesture(location)
        case .ended:
            endSelectGesture()
        default:
            cancelSelectGesture()
        }
    }

    @objc private func handleSelectionTap(_ tap: UITapGestureRecognizer) {
        selectToolTapped(at: tap.location(in: contentView))
    }

    /// Which part of the selection a touch at `point` (content coordinates) grabs.
    private func selectionGrab(at point: CGPoint) -> Manipulation.Kind? {
        guard let selection else { return nil }
        let zoom = scrollView.zoomScale
        let handles = SelectionHandles(box: selection.box, rotation: 0, zoom: zoom)
        let reach = Self.handleReach / zoom
        let center = CGPoint(x: selection.box.midX, y: selection.box.midY)
        if point.distance(to: handles.rotate) <= reach {
            return .rotate(center: center, startAngle: atan2(point.y - center.y, point.x - center.x))
        }
        if point.distance(to: handles.resize) <= reach {
            let anchor = selection.box.origin
            return .resize(anchor: anchor, startDistance: max(point.distance(to: anchor), 1))
        }
        if selection.box.insetBy(dx: -8 / zoom, dy: -8 / zoom).contains(point) {
            return .move(start: point)
        }
        return nil
    }

    private var lassoStart: CGPoint?

    private func beginSelectGesture(at point: CGPoint) {
        editMenu?.dismissMenu()
        if let grab = selectionGrab(at: point) {
            manipulation = Manipulation(kind: grab)
            lassoStart = point
            return
        }
        clearSelection()
        lassoStart = point
        lasso = [point]
    }

    private func continueSelectGesture(_ point: CGPoint) {
        if var current = manipulation, let selection {
            switch current.kind {
            case .move(let start):
                current.transform = CGAffineTransform(translationX: point.x - start.x, y: point.y - start.y)
            case .resize(let anchor, let startDistance):
                let scale = min(max(point.distance(to: anchor) / startDistance, 0.1), 10)
                current.transform = CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: scale, y: scale).translatedBy(x: -anchor.x, y: -anchor.y)
                current.widthScale = scale
            case .rotate(let center, let startAngle):
                let angle = atan2(point.y - center.y, point.x - center.x) - startAngle
                current.transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).translatedBy(x: -center.x, y: -center.y)
                current.rotation = angle
            }
            manipulation = current
            if hiddenStrokeIDs.isEmpty, !current.transform.isIdentity {
                hide(selection.strokes)
            }
            liveInk.showPreview(selection.strokes.map { placed in
                let rendered = rendered(placed.stroke)
                let origin = pageOrigin(placed.pageID)
                var transform = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(current.transform)
                let page = document.pages.first { $0.id == placed.pageID }
                let color = placed.stroke.tool == .pen ? placed.stroke.color.displayed(on: page?.record.paper ?? .whiteLined) : placed.stroke.color
                return LiveInk.Item(path: rendered.path.copy(using: &transform) ?? rendered.path, color: color.cgColor,
                                    tool: placed.stroke.tool, pageOrigin: .zero)
            })
            showSelectionOverlay()
            return
        }
        guard lasso != nil else { return }
        lasso?.append(point)
        if let path = lassoPath() {
            liveInk.showLasso(path, zoom: scrollView.zoomScale)
        }
    }

    private func endSelectGesture() {
        defer {
            lassoStart = nil
            lasso = nil
            liveInk.hideLasso()
        }
        if let current = manipulation {
            manipulation = nil
            let moved = !current.transform.isIdentity
            if moved {
                commitManipulation(current)
            } else {
                unhideAll()
                showSelectionOverlay()
            }
            presentMenu()
            return
        }
        guard let points = lasso, let start = lassoStart else { return }
        let travel = points.map { $0.distance(to: start) }.max() ?? 0
        if travel < Self.tapSlop / scrollView.zoomScale {
            selectToolTapped(at: start)
            return
        }
        guard let outline = lassoOutline() else { return }
        select(strokesInside: outline)
    }

    private func cancelSelectGesture() {
        if manipulation != nil {
            manipulation = nil
            unhideAll()
            showSelectionOverlay()
        }
        lassoStart = nil
        lasso = nil
        liveInk.hideLasso()
    }

    private func selectToolTapped(at point: CGPoint) {
        if let selection {
            if selection.box.insetBy(dx: -8, dy: -8).contains(point) {
                presentMenu()
            } else {
                clearSelection()
            }
        } else if UIPasteboard.general.contains(pasteboardTypes: [Self.inkPasteboardType]) {
            presentMenu(at: point)
        }
    }

    /// The lasso outline: freeform as drawn, or the rectangle from start to current point.
    private func lassoOutline() -> [CGPoint]? {
        guard let points = lasso, let first = points.first, let last = points.last else { return nil }
        switch settings.selectMode {
        case .freeform:
            return points.count >= 3 ? points : nil
        case .box:
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        }
    }

    private func lassoPath() -> CGPath? {
        guard let outline = lassoOutline() else { return nil }
        let path = CGMutablePath()
        path.addLines(between: outline)
        if settings.selectMode == .box { path.closeSubpath() }
        return path
    }

    private func select(strokesInside outline: [CGPoint]) {
        let xs = outline.map(\.x), ys = outline.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        var chosen: [NoteDocument.PlacedStroke] = []
        for page in document.pages {
            guard let view = pageViews[page.id], view.frame.intersects(bounds) else { continue }
            let local = outline.map { CGPoint(x: $0.x - view.frame.minX, y: $0.y - view.frame.minY) }
            for stroke in page.visibleStrokes where StrokeHitTesting.lasso(local, selects: stroke) {
                chosen.append(.init(stroke: stroke, pageID: page.id))
            }
        }
        setSelection(chosen)
        if selection != nil {
            presentMenu()
        }
    }

    private func setSelection(_ strokes: [NoteDocument.PlacedStroke]) {
        guard !strokes.isEmpty else {
            clearSelection()
            return
        }
        let box = strokes.reduce(CGRect.null) { box, placed in
            let origin = pageOrigin(placed.pageID)
            return box.union(placed.stroke.bounds.offsetBy(dx: origin.x, dy: origin.y))
        }
        selection = Selection(strokes: strokes, box: box)
        showSelectionOverlay()
    }

    private func clearSelection() {
        selection = nil
        unhideAll()
        liveInk.hideSelection()
        editMenu?.dismissMenu()
    }

    private func showSelectionOverlay() {
        guard let selection else {
            liveInk.hideSelection()
            return
        }
        var box = selection.box
        var rotation: CGFloat = 0
        if let current = manipulation {
            switch current.kind {
            case .rotate:
                rotation = current.rotation
            case .move, .resize:
                box = box.applying(current.transform)
            }
        }
        liveInk.showSelection(SelectionHandles(box: box, rotation: rotation, zoom: scrollView.zoomScale), zoom: scrollView.zoomScale)
    }

    /// Leaves strokes out of the page tiles while their moving preview is shown.
    private func hide(_ strokes: [NoteDocument.PlacedStroke]) {
        hiddenStrokeIDs = Set(strokes.map(\.stroke.id))
        for pageID in Set(strokes.map(\.pageID)) {
            updateInk(onPage: pageID, changedRect: nil)
        }
    }

    private func unhideAll() {
        guard !hiddenStrokeIDs.isEmpty else { return }
        let pageIDs = Set(document.pages.filter { $0.visibleStrokes.contains { hiddenStrokeIDs.contains($0.id) } }.map(\.id))
        hiddenStrokeIDs = []
        liveInk.clearPreview()
        pageIDs.forEach { updateInk(onPage: $0, changedRect: nil) }
    }

    private func commitManipulation(_ current: Manipulation) {
        guard let selection else { return }
        let added = transformedCopies(of: selection.strokes, by: current.transform, widthScale: current.widthScale, keepDepth: true)
        hiddenStrokeIDs = []
        liveInk.clearPreview()
        document.apply(NoteDocument.StrokeChange(removed: selection.strokes, added: added))
        setSelection(added)
    }

    /// Copies of strokes moved by a transform in content coordinates, re-split across pages.
    private func transformedCopies(of strokes: [NoteDocument.PlacedStroke], by transform: CGAffineTransform, widthScale: CGFloat,
                                   keepDepth: Bool) -> [NoteDocument.PlacedStroke] {
        let now = Date()
        return strokes.flatMap { placed -> [NoteDocument.PlacedStroke] in
            let origin = pageOrigin(placed.pageID)
            let toContent = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(transform)
            let moved = placed.stroke.transformed(toContent, widthScale: widthScale)
            return place(moved.points, tool: moved.tool, color: moved.color, createdAt: keepDepth ? moved.createdAt : now)
        }
    }

    // MARK: - Selection menu

    private var menuPoint: CGPoint?

    /// Shows the selection's menu above it, or (with `point`) a Paste menu there.
    private func presentMenu(at point: CGPoint? = nil) {
        let anchor: CGPoint
        if let point {
            anchor = point
        } else if let selection {
            anchor = CGPoint(x: selection.box.midX, y: selection.box.minY)
        } else {
            return
        }
        menuPoint = point
        let screen = contentView.convert(anchor, to: self)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: screen))
    }

    /// Keeps the menu clear of the selection: above it, or below if there's no room.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        if menuPoint == nil, let selection {
            return contentView.convert(selection.box, to: self)
        }
        return CGRect(origin: configuration.sourcePoint, size: .zero)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let canPaste = UIPasteboard.general.contains(pasteboardTypes: [Self.inkPasteboardType])
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() }
        guard selection != nil else {
            return canPaste ? UIMenu(children: [paste]) : nil
        }
        var items: [UIMenuElement] = [
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
        ]
        if canPaste { items.append(paste) }
        items += [
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelection() },
            colorMenu(),
            UIMenu(title: "Thickness", image: UIImage(systemName: "lineweight"), children: [
                UIAction(title: "Thinner") { [weak self] _ in self?.scaleSelectionWidth(by: 0.8) },
                UIAction(title: "Thicker") { [weak self] _ in self?.scaleSelectionWidth(by: 1.25) },
            ]),
            UIAction(title: "Copy as Image", image: UIImage(systemName: "photo")) { [weak self] _ in self?.copySelectionAsImage() },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ]
        return UIMenu(children: items)
    }

    private func colorMenu() -> UIMenu {
        let menu = UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: colorActions())
        menu.preferredElementSize = .small
        return menu
    }

    private func colorActions() -> [UIMenuElement] {
        var colors = settings.pen.colors + settings.highlighter.colors
        colors += [settings.pen.extraColor, settings.highlighter.extraColor].compactMap { $0 }
        var seen = Set<InkColor>()
        let unique = colors.filter { seen.insert($0).inserted }
        var actions: [UIMenuElement] = unique.map { color in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(UIColor(cgColor: color.cgColor), renderingMode: .alwaysOriginal)
            return UIAction(title: "", image: swatch) { [weak self] _ in self?.recolorSelection(color) }
        }
        actions.append(UIAction(title: "More Colors…", image: UIImage(systemName: "eyedropper")) { [weak self] _ in
            guard let self, let selection = self.selection else { return }
            let rect = self.contentView.convert(selection.box, to: nil)
            let start = selection.strokes.first?.stroke.color ?? .black
            ColorPickerPresenter.shared.present(color: start, from: rect) { [weak self] color in self?.recolorSelection(color) }
        })
        return actions
    }

    private func recolorSelection(_ color: InkColor) {
        replaceSelection { $0.replacement(color: color) }
    }

    private func scaleSelectionWidth(by factor: Float) {
        replaceSelection { stroke in
            stroke.replacement(points: stroke.points.map { InkPoint(x: $0.x, y: $0.y, width: $0.width * factor) })
        }
        presentMenu()
    }

    private func replaceSelection(_ change: (Stroke) -> Stroke) {
        guard let selection else { return }
        let replaced = selection.strokes.map { NoteDocument.PlacedStroke(stroke: change($0.stroke), pageID: $0.pageID) }
        replaced.forEach { renderedStrokes[$0.stroke.id] = RenderedStroke($0.stroke) }
        document.apply(NoteDocument.StrokeChange(removed: selection.strokes, added: replaced))
        setSelection(replaced)
    }

    private func duplicateSelection() {
        guard let selection else { return }
        let offset = CGAffineTransform(translationX: Self.duplicateOffset, y: Self.duplicateOffset)
        let copies = transformedCopies(of: selection.strokes, by: offset, widthScale: 1, keepDepth: false)
        document.apply(NoteDocument.StrokeChange(added: copies))
        setSelection(copies)
        presentMenu()
    }

    private func deleteSelection() {
        guard let selection else { return }
        document.apply(NoteDocument.StrokeChange(removed: selection.strokes))
        clearSelection()
    }

    private func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Copies the selection as ink (for pasting in this app), positioned relative to its box.
    private func copySelection() {
        guard let selection else { return }
        let offset = CGAffineTransform(translationX: -selection.box.minX, y: -selection.box.minY)
        let strokes = selection.strokes.map { placed in
            let origin = pageOrigin(placed.pageID)
            return placed.stroke.transformed(CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(offset))
        }
        if let data = try? InkCodec.encode(DeviceInk(strokes: strokes)) {
            UIPasteboard.general.setData(data, forPasteboardType: Self.inkPasteboardType)
        }
    }

    /// Pastes copied ink centered where the menu was opened (or next to the selection).
    private func paste() {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.inkPasteboardType),
              let ink = try? InkCodec.decode(data), !ink.strokes.isEmpty else { return }
        let box = ink.strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        let target: CGPoint
        if let menuPoint {
            target = menuPoint
        } else if let selection {
            target = CGPoint(x: selection.box.midX + Self.duplicateOffset, y: selection.box.midY + Self.duplicateOffset)
        } else {
            return
        }
        let move = CGAffineTransform(translationX: target.x - box.midX, y: target.y - box.midY)
        let now = Date()
        let pasted = ink.strokes.flatMap { stroke -> [NoteDocument.PlacedStroke] in
            let moved = stroke.transformed(move)
            return place(moved.points, tool: moved.tool, color: moved.color, createdAt: now)
        }
        document.apply(NoteDocument.StrokeChange(added: pasted))
        setSelection(pasted)
        presentMenu()
    }

    /// Copies the selection as a picture, for pasting into other apps.
    private func copySelectionAsImage() {
        guard let selection else { return }
        let box = selection.box.insetBy(dx: -4, dy: -4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -box.minX, y: -box.minY)
            let clip = CGRect(origin: .zero, size: .init(width: 10_000, height: 10_000))
            for pageID in Set(selection.strokes.map(\.pageID)) {
                let origin = pageOrigin(pageID)
                let strokes = selection.strokes.filter { $0.pageID == pageID }.map { rendered($0.stroke) }
                cg.saveGState()
                cg.translateBy(x: origin.x, y: origin.y)
                PageRenderer.drawHighlights(strokes, in: cg, clip: clip)
                PageRenderer.drawInk(strokes, paper: .whiteLined, in: cg, clip: clip)
                cg.restoreGState()
            }
        }
        UIPasteboard.general.image = image
    }

    // MARK: - Handing finished strokes from the live ink to the pages

    /// Keeps the live ink's copy of a finished stroke until the page tiles that show it have redrawn.
    private func waitForTiles(_ handoffID: UUID, toShow pieces: [NoteDocument.PlacedStroke]) {
        var waits: [PendingHandoff.Key: PendingHandoff.Wait] = [:]
        for piece in pieces {
            guard let view = pageViews[piece.pageID] else { continue }
            // Only visible tiles get drawn.
            let visible = scrollView.convert(scrollView.bounds, to: view).intersection(view.bounds)
            let area = piece.stroke.bounds.intersection(visible)
            guard !area.isNull, !area.isEmpty else { continue }
            let isInk = piece.stroke.tool == .pen
            let key = PendingHandoff.Key(pageID: piece.pageID, isInk: isInk)
            let combined = waits[key].map { $0.area.union(area) } ?? area
            waits[key] = PendingHandoff.Wait(version: view.tiles(isInk ? .ink : .background).contentVersion, area: combined)
        }
        if waits.isEmpty {
            liveInk.endHandOff(handoffID)
        } else {
            pendingHandoffs.append(PendingHandoff(id: handoffID, waits: waits))
        }
    }

    private func tileDidDraw(onPage pageID: UUID, isInk: Bool, rect: CGRect, version: Int) {
        // The live ink gives up on its own after a moment; forget those.
        pendingHandoffs.removeAll { Date().timeIntervalSince($0.startedAt) > 1 }
        let key = PendingHandoff.Key(pageID: pageID, isInk: isInk)
        var finished: [UUID] = []
        for index in pendingHandoffs.indices {
            guard var wait = pendingHandoffs[index].waits[key], version >= wait.version else { continue }
            wait.drawnTiles.append(rect)
            pendingHandoffs[index].waits[key] = wait
            if pendingHandoffs[index].waits.values.allSatisfy({ Self.isCovered($0.area, by: $0.drawnTiles) }) {
                finished.append(pendingHandoffs[index].id)
            }
        }
        guard !finished.isEmpty else { return }
        pendingHandoffs.removeAll { finished.contains($0.id) }
        // New tiles reach the screen a frame or so after they're drawn; remove the copy after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            finished.forEach { self?.liveInk.endHandOff($0) }
        }
    }

    private static func isCovered(_ area: CGRect, by tiles: [CGRect]) -> Bool {
        // Tiles end on whole pixels, so they can stop a fraction of a point short of a page edge
        // that isn't. Ignore a point-wide border (or, for a tiny dot, check its center).
        let area = area.width > 2 && area.height > 2
            ? area.insetBy(dx: 1, dy: 1)
            : CGRect(x: area.midX, y: area.midY, width: 0, height: 0)
        let steps = 6
        for i in 0...steps {
            for j in 0...steps {
                let point = CGPoint(
                    x: area.minX + area.width * CGFloat(i) / CGFloat(steps),
                    y: area.minY + area.height * CGFloat(j) / CGFloat(steps)
                )
                if !tiles.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }) {
                    return false
                }
            }
        }
        return true
    }

    // MARK: - Gestures

    private func configureTouchTypes() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        strokeRecognizer.allowedTouchTypes = drawsWithFinger ? [pencil, finger] : [pencil]
        scrollView.panGestureRecognizer.allowedTouchTypes = [finger]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = drawsWithFinger ? 2 : 1
        // With finger drawing on, one finger already works the select tool through the stroke recognizer.
        let fingerSelects = tool == .select && !drawsWithFinger
        selectionPan.isEnabled = fingerSelects
        selectionTap.isEnabled = fingerSelects
    }

    @objc private func handleUndoTap() {
        guard activeStroke == nil, manipulation == nil else { return }
        clearSelection()
        document.undo()
    }

    @objc private func handleRedoTap() {
        guard activeStroke == nil, manipulation == nil else { return }
        clearSelection()
        document.redo()
    }

    // Both UIView's method and the delegate method (this view is its recognizers' delegate).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === zoomPinch {
            // No zooming while the Pencil is writing (e.g. a palm plus a finger).
            return activeStroke == nil && manipulation == nil
        }
        if gestureRecognizer === selectionPan {
            return selectionGrab(at: gestureRecognizer.location(in: contentView)) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === undoTap || gestureRecognizer === redoTap {
            // Palm rejection for the undo/redo taps.
            return touch.majorRadius <= Self.maxFingerRadius
                && Date().timeIntervalSince(lastPencilActivity) > Self.tapQuietPeriod
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Writing, pinching, scrolling and taps all watch the same fingers: the stroke recognizer
        // cancels itself when a second finger shows it was a scroll or tap, a pinch takes over
        // scrolling while it runs, and a tap fails as soon as the fingers move.
        true
    }

    // MARK: - Apple Pencil double-tap

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            settings.tool = tool == .eraser ? (settings.previousTool == .eraser ? .pen : settings.previousTool) : .eraser
        case .switchPrevious:
            settings.tool = settings.previousTool
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            showColorPickerForCurrentTool()
        default:
            break
        }
    }

    private func showColorPickerForCurrentTool() {
        if tool != .pen && tool != .highlighter {
            settings.tool = .pen
        }
        let isHighlighter = settings.tool == .highlighter
        let presets = isHighlighter ? settings.highlighter : settings.pen
        let anchor = convert(CGRect(x: bounds.midX - 1, y: bounds.minY + 8, width: 2, height: 2), to: nil)
        ColorPickerPresenter.shared.present(color: presets.currentColor, from: anchor) { [weak self] color in
            guard let self else { return }
            if isHighlighter {
                self.settings.highlighter.setCurrentColor(color)
            } else {
                self.settings.pen.setCurrentColor(color)
            }
        }
    }

    // MARK: - Debugging in the Simulator

    #if DEBUG
    private var debugStep = 0
    private var debugStrokeOrigin = CGPoint.zero

    /// Launch arguments (with `-OpenFirstNote`) for checking things in the Simulator, which has no Pencil:
    /// - `-DebugLiveStroke`: replays a synthetic pen stroke through the live-drawing path. It
    ///   crosses from page 1 onto page 2, stays live for 3 seconds, then finishes.
    /// - `-DebugUndoAfterStroke`: undoes it 2 seconds later.
    /// - `-DebugTools`: replays a highlight, a snapped circle, then a whole-stroke erase and a lasso.
    /// - `-DebugZoom 2`: zooms in first.
    private func startDebugScenarioIfRequested() {
        let zoom = UserDefaults.standard.double(forKey: "DebugZoom")
        if zoom > 0 {
            scrollView.zoomScale = widthFitZoom * zoom
        }
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-DebugLiveStroke") || arguments.contains("-DebugTools"),
              let page = document.pages.first, let pageView = pageViews[page.id] else { return }
        if arguments.contains("-DebugLiveStroke") {
            // Show the edge between pages 1 and 2 in the middle of the screen.
            let edge = pageView.frame.maxY * scrollView.zoomScale
            scrollView.contentOffset.y = edge - bounds.height / 2
            debugStrokeOrigin = CGPoint(x: pageView.frame.minX + 60, y: pageView.frame.maxY - 80)
        } else {
            debugStrokeOrigin = CGPoint(x: pageView.frame.minX + 80, y: pageView.frame.minY + 560)
        }
        liveInk.rasterScale = tileRasterScale
        CADisplayLink(target: self, selector: #selector(stepDebugScenario(_:))).add(to: .main, forMode: .common)
    }

    private func debugStroke(tool: InkTool) -> ActiveStroke? {
        guard let page = document.pages.first, let pageView = pageViews[page.id] else { return nil }
        let presets = tool == .highlighter ? settings.highlighter : settings.pen
        return ActiveStroke(pageID: page.id, pageView: pageView, tool: tool,
                            builder: StrokeBuilder(baseWidth: presets.currentSize, curve: settings.pressureCurve,
                                                   smoothing: StrokeSmoothing.screenRadius / scrollView.zoomScale),
                            color: tool == .pen ? .red : presets.currentColor,
                            displayColor: tool == .pen ? .red : presets.currentColor)
    }

    @objc private func stepDebugScenario(_ link: CADisplayLink) {
        debugStep += 1
        let t = Double(debugStep) / 60
        let o = debugStrokeOrigin
        if ProcessInfo.processInfo.arguments.contains("-DebugLiveStroke") {
            if debugStep == 1 { activeStroke = debugStroke(tool: .pen) }
            if t <= 1 {
                let location = CGPoint(x: o.x + t * 300, y: o.y + t * 160 + 30 * sin(t * .pi * 4))
                add([.init(location: location, force: 0.15 + 0.4 * t, estimationIndex: nil)], forceUpdates: [], predicted: [])
            } else if t > 4 {
                link.invalidate()
                finishStroke()
                if ProcessInfo.processInfo.arguments.contains("-DebugUndoAfterStroke") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.document.undo() }
                }
            }
            return
        }
        // -DebugTools: a highlight across the demo writing (0–1 s), a circle that snaps (1.5–3.5 s),
        // a whole-stroke erase of the zigzag (4–5 s), then a lasso around the spiral (5.5–6.5 s).
        switch t {
        case ..<1:
            if debugStep == 1 { activeStroke = debugStroke(tool: .highlighter) }
            add([.init(location: CGPoint(x: o.x - 20 + t * 420, y: o.y - 350), force: nil, estimationIndex: nil)], forceUpdates: [], predicted: [])
        case 1..<1.02:
            finishStroke()
            activeStroke = debugStroke(tool: .pen)
        case 1.5..<2.5:
            let angle = (t - 1.5) * 2 * .pi
            add([.init(location: CGPoint(x: o.x + 380 + 50 * cos(angle), y: o.y + 50 * sin(angle)), force: 0.3, estimationIndex: nil)],
                forceUpdates: [], predicted: [])
        case 3.5..<3.52:
            finishStroke()
        case 4..<5:
            let point = CGPoint(x: o.x - 20 + (t - 4) * 280, y: o.y - 300)
            if eraserPosition == nil {
                settings.eraserMode = .wholeStroke
                document.beginGroup()
                eraserPosition = point
            }
            erase(along: [point])
        case 5..<5.02:
            eraserPosition = nil
            liveInk.hideEraser()
            document.endGroup()
        case 5.5..<6.5:
            let angle = (t - 5.5) * 2 * .pi
            let point = CGPoint(x: o.x + 340 + 80 * cos(angle), y: o.y - 270 + 80 * sin(angle))
            if lasso == nil { lassoStart = point; lasso = [point] } else { continueSelectGesture(point) }
        case 6.5..<6.52:
            settings.selectMode = .freeform
            if let outline = lassoOutline() { select(strokesInside: outline) }
            lasso = nil
            liveInk.hideLasso()
        case 7.5..<8.5:
            // Drag the selection down and to the left.
            guard let box = selection?.box else { break }
            let start = CGPoint(x: box.midX, y: box.midY)
            if manipulation == nil { beginSelectGesture(at: start); debugStrokeOrigin = start }
            continueSelectGesture(CGPoint(x: debugStrokeOrigin.x - (t - 7.5) * 150, y: debugStrokeOrigin.y + (t - 7.5) * 260))
        case 8.5...:
            link.invalidate()
            endSelectGesture()
            if ProcessInfo.processInfo.arguments.contains("-DebugDarkPaper") {
                document.setPaper(PaperStyle(template: .lined, color: .paperDark, lineSpacing: .wide))
            }
            if ProcessInfo.processInfo.arguments.contains("-DebugUndoAll") {
                // Undo the move, the erase, the circle and the highlight, one per half second.
                for step in 1...4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(step)) { [weak self] in self?.document.undo() }
                }
            }
        default:
            break
        }
    }
    #endif
}

extension ToolPresets {
    /// Sets the color of the selected slot (the extra slot if that's selected).
    mutating func setCurrentColor(_ color: InkColor) {
        if selectedColorSlot == extraColorSlot {
            extraColor = color
        } else {
            colors[min(selectedColorSlot, colors.count - 1)] = color
        }
    }
}

/// Scroll view that won't start scrolling while the Pencil is writing or a selection is grabbed.
private final class CanvasScrollView: UIScrollView {
    /// Given where a pan starts (in the scroll view), whether it should not scroll.
    var blocksPanning: (CGPoint) -> Bool = { _ in false }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, blocksPanning(gestureRecognizer.location(in: self)) {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func stopScrolling() {
        guard isDragging || isDecelerating else { return }
        cancelPanning()
    }

    /// Stops scrolling now; touches already down won't scroll again until they lift.
    func cancelPanning() {
        setContentOffset(contentOffset, animated: false)
        panGestureRecognizer.isEnabled = false
        panGestureRecognizer.isEnabled = true
    }
}
#endif
