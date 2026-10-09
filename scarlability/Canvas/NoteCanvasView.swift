#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

struct NoteCanvas: UIViewRepresentable {
    let document: NoteDocument
    let settings: PenSettings

    func makeUIView(context: Context) -> NoteCanvasView {
        NoteCanvasView(document: document, settings: settings)
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        canvas.drawsWithFinger = settings.drawsWithFinger
    }
}

/// The writing surface: pages stacked edge to edge in a scroll view.
///
/// - Apple Pencil writes; fingers scroll and pinch-zoom (unless "Draw with finger" is on, in
///   which case one finger writes and two fingers scroll).
/// - Writing can run from one page onto the next.
/// - Pinch-zoom locks at "page width fills the screen" and "whole page fits".
/// - Two-finger tap undoes, three-finger tap redoes.
/// - Content is laid out in page points; zooming scales it, and the page tiles redraw sharply.
final class NoteCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let document: NoteDocument
    private let settings: PenSettings

    private let scrollView = CanvasScrollView()
    private let contentView = UIView()
    private lazy var liveInk = LiveInk(host: contentView.layer)
    private let strokeRecognizer = StrokeGestureRecognizer()
    private let zoomPinch = UIPinchGestureRecognizer()
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()

    private var pageViews: [UUID: PageView] = [:]
    /// Which pages currently show the thin line along their bottom edge (all but the last).
    private var pagesWithBottomEdge: Set<UUID> = []
    /// Stroke outlines are built once and reused for every redraw.
    private var renderedStrokes: [UUID: RenderedStroke] = [:]
    private var activeStroke: ActiveStroke?
    private var pendingHandoffs: [PendingHandoff] = []
    private var pinchStart: (position: CGFloat, anchor: CGPoint)?
    private var zoomDetents = ZoomDetents(zooms: [])
    private var lastPencilActivity = Date.distantPast
    private var laidOutSize: CGSize = .zero
    /// Zoom relative to "page width fills the screen", kept when the window resizes or rotates.
    private var relativeZoom: CGFloat = 1

    private struct ActiveStroke {
        var pageID: UUID
        var pageView: PageView
        var builder: StrokeBuilder
        var color: InkColor
        var sampleIndexByEstimationIndex: [Int: Int] = [:]
    }

    /// A finished stroke that the live ink keeps showing until the page tiles have drawn it.
    private struct PendingHandoff {
        struct Wait {
            /// The tile content version that includes the stroke.
            var version: Int
            /// The visible part of the stroke on this page, in page coordinates.
            var area: CGRect
            var drawnTiles: [CGRect] = []
        }

        var id: UUID
        var waits: [UUID: Wait]
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

    var drawsWithFinger = false {
        didSet {
            if drawsWithFinger != oldValue { configureTouchTypes() }
        }
    }

    init(document: NoteDocument, settings: PenSettings) {
        self.document = document
        self.settings = settings
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isWritingActive = { [weak self] in self?.activeStroke != nil }
        // Real limits are set at layout. Zooming must be enabled for setZoomScale to work, but
        // pinching is handled by `zoomPinch` (for the zoom locks), so the built-in pinch is off.
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5
        scrollView.pinchGestureRecognizer?.isEnabled = false
        addSubview(scrollView)
        scrollView.addSubview(contentView)

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

        drawsWithFinger = settings.drawsWithFinger
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
            view.contentScaleFactor = tileScale
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
            startDebugStrokeIfRequested()
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

    /// Pixels per content point that the page tiles use at the current zoom. Tiles draw at the
    /// layer's scale times the smallest power of two that's at least as sharp as the screen.
    private var tileRasterScale: CGFloat {
        let base = tileScale
        let needed = scrollView.zoomScale * traitCollection.displayScale / base
        // PageTileLayer has levels from 1/8× to 8×.
        let level = min(max(ceil(log2(needed) - 1e-6), -3), 3)
        return base * pow(2, level)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if widthFitZoom > 0 {
            relativeZoom = scrollView.zoomScale / widthFitZoom
        }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            // The pinch moves the page itself from here on, including two-finger panning.
            scrollView.cancelPanning()
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
        switch change {
        case .pagesChanged:
            syncPageViews()
        case .inkChanged(let pageID, let area):
            updateInk(onPage: pageID, changedRect: area)
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
            view.contentScaleFactor = tileScale
            let id = page.id
            view.tileLayer.setTileDrawnHandler { [weak self] rect, version in
                Task { @MainActor [self] in self?.tileDidDraw(onPage: id, rect: rect, version: version) }
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
        let strokes = page.visibleStrokes.map { stroke in
            if let cached = renderedStrokes[stroke.id] { return cached }
            let rendered = RenderedStroke(stroke)
            renderedStrokes[stroke.id] = rendered
            return rendered
        }
        let hasBottomEdge = pageID != document.pages.last?.id
        if hasBottomEdge {
            pagesWithBottomEdge.insert(pageID)
        } else {
            pagesWithBottomEdge.remove(pageID)
        }
        view.tileLayer.setContent(
            PageTileLayer.Content(
                paper: page.record.paper,
                size: page.record.size,
                strokes: strokes,
                bottomEdgeColor: hasBottomEdge ? Self.pageEdgeColor : nil
            ),
            changedRect: changedRect
        )
    }

    // MARK: - Writing

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        if recognizer.touchType == .pencil {
            lastPencilActivity = Date()
        }
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

        activeStroke = ActiveStroke(
            pageID: page.id,
            pageView: pageView,
            builder: StrokeBuilder(
                baseWidth: settings.currentWidth,
                curve: settings.pressureCurve,
                // Smoothing is set in screen points, so it feels the same at any zoom.
                smoothing: StrokeSmoothing.screenRadius / scrollView.zoomScale
            ),
            color: settings.currentColor
        )
        add(samples, forceUpdates: [], predicted: recognizer.predictedLocations)
        document.beginWriting(onPage: page.id)
    }

    private func consumeSamples(_ recognizer: StrokeGestureRecognizer) {
        add(recognizer.takeSamples(), forceUpdates: recognizer.takeForceUpdates(), predicted: recognizer.predictedLocations)
    }

    private func add(_ samples: [StrokeGestureRecognizer.Sample], forceUpdates: [StrokeGestureRecognizer.ForceUpdate], predicted: [CGPoint]) {
        guard var active = activeStroke else { return }
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
        activeStroke = active
        liveInk.showLiveStroke(active.builder.livePoints(predicted: predicted.map(local)), color: active.color, pageOrigin: origin)
    }

    private func finishStroke() {
        guard let active = activeStroke else { return }
        activeStroke = nil
        let points = active.builder.finishedPoints()
        guard !points.isEmpty else {
            liveInk.clearLiveStroke()
            document.cancelWriting()
            return
        }

        // Split the stroke into one piece per page it touched.
        let origin = active.pageView.frame.origin
        let contentPoints = points.map { InkPoint(x: $0.x + Float(origin.x), y: $0.y + Float(origin.y), width: $0.width) }
        let pages = document.pages
        let frames = pages.map { pageViews[$0.id]?.frame ?? .null }
        let createdAt = Date()
        let pieces = PageSplitter.split(contentPoints, pageFrames: frames).map { piece in
            NoteDocument.PlacedStroke(
                stroke: Stroke(color: active.color, points: piece.points, createdAt: createdAt),
                pageID: pages[piece.pageIndex].id
            )
        }
        for piece in pieces {
            renderedStrokes[piece.stroke.id] = RenderedStroke(piece.stroke)
        }

        let handoffID = UUID()
        liveInk.handOff(id: handoffID, path: StrokeGeometry.path(for: points), color: active.color, pageOrigin: origin)
        document.addStroke(pieces)
        waitForTiles(handoffID, toShow: pieces)
    }

    private func cancelStroke() {
        guard activeStroke != nil else { return }
        activeStroke = nil
        liveInk.clearLiveStroke()
        document.cancelWriting()
    }

    // MARK: - Handing finished strokes from the live ink to the pages

    /// Keeps the live ink's copy of a finished stroke until the page tiles that show it have redrawn.
    private func waitForTiles(_ handoffID: UUID, toShow pieces: [NoteDocument.PlacedStroke]) {
        var waits: [UUID: PendingHandoff.Wait] = [:]
        for piece in pieces {
            guard let view = pageViews[piece.pageID] else { continue }
            // Only visible tiles get drawn.
            let visible = scrollView.convert(scrollView.bounds, to: view).intersection(view.bounds)
            let area = piece.stroke.bounds.intersection(visible)
            guard !area.isNull, !area.isEmpty else { continue }
            let combined = waits[piece.pageID].map { $0.area.union(area) } ?? area
            waits[piece.pageID] = PendingHandoff.Wait(version: view.tileLayer.contentVersion, area: combined)
        }
        if waits.isEmpty {
            liveInk.endHandOff(handoffID)
        } else {
            pendingHandoffs.append(PendingHandoff(id: handoffID, waits: waits))
        }
    }

    private func tileDidDraw(onPage pageID: UUID, rect: CGRect, version: Int) {
        // The live ink gives up on its own after a moment; forget those.
        pendingHandoffs.removeAll { Date().timeIntervalSince($0.startedAt) > 1 }
        var finished: [UUID] = []
        for index in pendingHandoffs.indices {
            guard var wait = pendingHandoffs[index].waits[pageID], version >= wait.version else { continue }
            wait.drawnTiles.append(rect)
            pendingHandoffs[index].waits[pageID] = wait
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
    }

    @objc private func handleUndoTap() {
        guard activeStroke == nil else { return }
        document.undo()
    }

    @objc private func handleRedoTap() {
        guard activeStroke == nil else { return }
        document.redo()
    }

    // Both UIView's method and the delegate method (this view is its recognizers' delegate).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // No zooming while the Pencil is writing (e.g. a palm plus a finger).
        if gestureRecognizer === zoomPinch {
            return activeStroke == nil
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

    // MARK: - Debugging in the Simulator

    #if DEBUG
    private var debugStrokeStep = 0
    private var debugStrokeOrigin = CGPoint.zero

    /// Launch with `-DebugLiveStroke` to replay a synthetic stroke through the live-drawing path
    /// (the Simulator has no Pencil). It crosses from page 1 onto page 2, stays live for 3 seconds,
    /// then finishes. `-DebugZoom 2` zooms in first; `-DebugUndoAfterStroke` undoes it 2 seconds later.
    private func startDebugStrokeIfRequested() {
        let zoom = UserDefaults.standard.double(forKey: "DebugZoom")
        if zoom > 0 {
            scrollView.zoomScale = widthFitZoom * zoom
        }
        guard ProcessInfo.processInfo.arguments.contains("-DebugLiveStroke"),
              let page = document.pages.first, let pageView = pageViews[page.id] else { return }
        // Show the edge between pages 1 and 2 in the middle of the screen.
        let edge = pageView.frame.maxY * scrollView.zoomScale
        scrollView.contentOffset.y = edge - bounds.height / 2
        liveInk.rasterScale = tileRasterScale
        activeStroke = ActiveStroke(
            pageID: page.id,
            pageView: pageView,
            builder: StrokeBuilder(baseWidth: settings.currentWidth, curve: settings.pressureCurve,
                                   smoothing: StrokeSmoothing.screenRadius / scrollView.zoomScale),
            color: .red
        )
        debugStrokeOrigin = CGPoint(x: pageView.frame.minX + 60, y: pageView.frame.maxY - 80)
        CADisplayLink(target: self, selector: #selector(stepDebugStroke(_:))).add(to: .main, forMode: .common)
    }

    @objc private func stepDebugStroke(_ link: CADisplayLink) {
        debugStrokeStep += 1
        let t = Double(debugStrokeStep) / 60
        if t <= 1 {
            let location = CGPoint(x: debugStrokeOrigin.x + t * 300, y: debugStrokeOrigin.y + t * 160 + 30 * sin(t * .pi * 4))
            add([.init(location: location, force: 0.15 + 0.4 * t, estimationIndex: nil)], forceUpdates: [], predicted: [])
        } else if t > 4 {
            link.invalidate()
            finishStroke()
            if ProcessInfo.processInfo.arguments.contains("-DebugUndoAfterStroke") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.document.undo() }
            }
        }
    }
    #endif
}

/// Scroll view that won't start scrolling while the Pencil is writing.
private final class CanvasScrollView: UIScrollView {
    var isWritingActive: () -> Bool = { false }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, isWritingActive() {
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
