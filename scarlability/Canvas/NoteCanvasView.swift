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

/// The writing surface: pages stacked vertically in a scroll view.
///
/// - Apple Pencil writes; fingers scroll and pinch-zoom (unless "Draw with finger" is on, in
///   which case one finger writes and two fingers scroll).
/// - Two-finger tap undoes, three-finger tap redoes.
/// - Content is laid out in page points; zooming scales it, and the page tiles redraw sharply.
final class NoteCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let document: NoteDocument
    private let settings: PenSettings

    private let scrollView = CanvasScrollView()
    private let contentView = UIView()
    private let overlay = LiveStrokeOverlay()
    private let strokeRecognizer = StrokeGestureRecognizer()
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()

    private var pageViews: [UUID: PageView] = [:]
    /// Stroke outlines are built once and reused for every redraw.
    private var renderedStrokes: [UUID: RenderedStroke] = [:]
    private var activeStroke: ActiveStroke?
    private var lastPencilActivity = Date.distantPast
    private var laidOutWidth: CGFloat = 0
    /// Zoom relative to "page fills the width", kept when the window resizes or rotates.
    private var relativeZoom: CGFloat = 1

    private struct ActiveStroke {
        var pageID: UUID
        var pageView: PageView
        var builder: StrokeBuilder
        var color: InkColor
        var sampleIndexByEstimationIndex: [Int: Int] = [:]
    }

    private static let pageGap: CGFloat = 14
    private static let sideMargin: CGFloat = 14
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...5
    /// Touches bigger than this (in points) are a palm, not a finger tap.
    private static let maxFingerRadius: CGFloat = 25
    /// Finger taps right after writing are usually the palm lifting, not an undo.
    private static let tapQuietPeriod: TimeInterval = 0.6

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
        // Real limits are set at layout; any range enables the pinch recognizer so it can be
        // restricted to fingers right away.
        scrollView.minimumZoomScale = Self.zoomRange.lowerBound
        scrollView.maximumZoomScale = Self.zoomRange.upperBound
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        addSubview(overlay)

        strokeRecognizer.coordinateView = contentView
        strokeRecognizer.addTarget(self, action: #selector(handleStroke(_:)))
        strokeRecognizer.delegate = self
        scrollView.addGestureRecognizer(strokeRecognizer)

        for (tap, touches, action) in [(undoTap, 2, #selector(handleUndoTap)), (redoTap, 3, #selector(handleRedoTap))] {
            tap.numberOfTouchesRequired = touches
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
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

    // MARK: - Layout

    private var contentWidth: CGFloat {
        (document.pages.map(\.record.size.width).max() ?? PageSize.a4.width) + 2 * Self.sideMargin
    }

    private var fitScale: CGFloat { bounds.width / contentWidth }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        overlay.frame = bounds
        guard bounds.width > 0, bounds.width != laidOutWidth else { return }
        let isFirstLayout = laidOutWidth == 0
        laidOutWidth = bounds.width
        scrollView.minimumZoomScale = fitScale * Self.zoomRange.lowerBound
        scrollView.maximumZoomScale = fitScale * Self.zoomRange.upperBound
        scrollView.zoomScale = fitScale * relativeZoom
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
        var y = Self.pageGap
        for page in document.pages {
            guard let view = pageViews[page.id] else { continue }
            let size = page.record.size
            view.frame = CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height)
            y += size.height + Self.pageGap
        }
        let zoom = scrollView.zoomScale
        let size = CGSize(width: width, height: y)
        contentView.bounds = CGRect(origin: .zero, size: size)
        contentView.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scrollView.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
        centerContent()
    }

    /// Centers the pages horizontally when zoomed out narrower than the screen.
    private func centerContent() {
        let inset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if fitScale > 0 {
            relativeZoom = scrollView.zoomScale / fitScale
        }
        overlay.viewportDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        overlay.viewportDidChange()
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
        }
        for page in document.pages where pageViews[page.id] == nil {
            let view = PageView()
            contentView.addSubview(view)
            pageViews[page.id] = view
            updateInk(onPage: page.id, changedRect: nil)
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
        view.tileLayer.setContent(
            PageTileLayer.Content(paper: page.record.paper, size: page.record.size, strokes: strokes),
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
            // Started between pages: ignore this stroke.
            return
        }
        // Writing stops any scrolling in progress (e.g. a palm that landed first).
        scrollView.stopScrolling()

        activeStroke = ActiveStroke(
            pageID: page.id,
            pageView: pageView,
            builder: StrokeBuilder(baseWidth: settings.currentWidth, curve: settings.pressureCurve),
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
        overlay.showLiveStroke(active.builder.livePoints(predicted: predicted.map(local)), color: active.color, on: active.pageView)
    }

    private func finishStroke() {
        guard let active = activeStroke else { return }
        activeStroke = nil
        let points = active.builder.finishedPoints()
        guard !points.isEmpty else {
            overlay.clearLiveStroke()
            document.cancelWriting()
            return
        }
        let stroke = Stroke(color: active.color, points: points)
        let rendered = RenderedStroke(stroke)
        renderedStrokes[stroke.id] = rendered
        overlay.handOff(rendered, on: active.pageView)
        document.addStroke(stroke, toPage: active.pageID)
    }

    #if DEBUG
    private var debugStrokeStep = 0
    private var debugStrokePageOrigin = CGPoint.zero

    /// Launch with `-DebugLiveStroke` to replay a synthetic stroke through the live-drawing path,
    /// to check the overlay in the Simulator (which has no Pencil). It stays live for 3 seconds
    /// before finishing. `-DebugZoom 2` zooms in first.
    private func startDebugStrokeIfRequested() {
        let zoom = UserDefaults.standard.double(forKey: "DebugZoom")
        if zoom > 0 {
            scrollView.setZoomScale(fitScale * zoom, animated: false)
            let inset = scrollView.adjustedContentInset
            scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
        }
        guard ProcessInfo.processInfo.arguments.contains("-DebugLiveStroke"),
              let page = document.pages.first, let pageView = pageViews[page.id] else { return }
        activeStroke = ActiveStroke(
            pageID: page.id,
            pageView: pageView,
            builder: StrokeBuilder(baseWidth: settings.currentWidth, curve: settings.pressureCurve),
            color: .red
        )
        debugStrokePageOrigin = pageView.frame.origin
        CADisplayLink(target: self, selector: #selector(stepDebugStroke(_:))).add(to: .main, forMode: .common)
    }

    @objc private func stepDebugStroke(_ link: CADisplayLink) {
        debugStrokeStep += 1
        let samplesPerSecond = 60.0
        let t = Double(debugStrokeStep) / samplesPerSecond
        if t <= 1 {
            let origin = debugStrokePageOrigin
            let location = CGPoint(x: origin.x + 60 + t * 240, y: origin.y + 160 + 30 * sin(t * .pi * 4))
            add([.init(location: location, force: 0.15 + 0.4 * t, estimationIndex: nil)], forceUpdates: [], predicted: [])
        } else if t > 4 {
            link.invalidate()
            finishStroke()
        }
    }
    #endif

    private func cancelStroke() {
        guard activeStroke != nil else { return }
        activeStroke = nil
        overlay.clearLiveStroke()
        document.cancelWriting()
    }

    // MARK: - Gestures

    private func configureTouchTypes() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        strokeRecognizer.allowedTouchTypes = drawsWithFinger ? [pencil, finger] : [pencil]
        scrollView.panGestureRecognizer.allowedTouchTypes = [finger]
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [finger]
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === undoTap || gestureRecognizer === redoTap {
            // Palm rejection for the undo/redo taps.
            return touch.majorRadius <= Self.maxFingerRadius
                && Date().timeIntervalSince(lastPencilActivity) > Self.tapQuietPeriod
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Writing coexists with scrolling and taps; the stroke recognizer cancels itself when a
        // second finger shows the touch was a scroll or tap all along.
        gestureRecognizer === strokeRecognizer || other === strokeRecognizer
    }
}

/// Scroll view that won't start scrolling or zooming while the Pencil is writing.
private final class CanvasScrollView: UIScrollView {
    var isWritingActive: () -> Bool = { false }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if (gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer), isWritingActive() {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func stopScrolling() {
        guard isDragging || isDecelerating else { return }
        setContentOffset(contentOffset, animated: false)
        // Toggling the pan cancels a drag in progress.
        panGestureRecognizer.isEnabled = false
        panGestureRecognizer.isEnabled = true
    }
}
#endif
