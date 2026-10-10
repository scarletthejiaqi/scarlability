#if os(iOS)
import ScarlabilityKit
import SwiftUI
import UIKit

struct NoteCanvas: UIViewRepresentable {
    let document: NoteDocument
    let settings: ToolSettings
    let session: EditorSession
    /// How much of the top the toolbar covers. The first page starts below it.
    var topInset: CGFloat = 0

    func makeUIView(context: Context) -> NoteCanvasView {
        NoteCanvasView(document: document, settings: settings, session: session)
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        canvas.drawsWithFinger = settings.drawsWithFinger
        canvas.tool = settings.tool
        canvas.topInset = topInset
    }
}

/// The writing surface: pages stacked edge to edge in a scroll view.
///
/// - Apple Pencil uses the current tool (pen, highlighter, eraser, select); fingers scroll and
///   pinch-zoom (unless "Draw with finger" is on: then one finger uses the tool and two scroll).
/// - Writing can run from one page onto the next.
/// - Draw a shape and hold still to snap it to a clean line, circle, rectangle or polygon. Keep the
///   pen down to drag it: a line's end follows the pen and locks flat or upright on the way.
/// - Pinch-zoom locks at "page width fills the screen" and "whole page fits".
/// - Two-finger tap undoes, three-finger tap redoes; Apple Pencil double-tap does what the iPad's
///   Apple Pencil setting says.
/// - Content is laid out in page points; zooming scales it, and the page tiles redraw sharply.
final class NoteCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    let document: NoteDocument
    let settings: ToolSettings
    let session: EditorSession

    let scrollView = CanvasScrollView()
    let contentView = UIView()
    lazy var liveInk = LiveInk(host: contentView.layer)
    let strokeRecognizer = StrokeGestureRecognizer()
    let zoomPinch = UIPinchGestureRecognizer()
    let undoTap = UITapGestureRecognizer()
    let redoTap = UITapGestureRecognizer()
    /// One finger moving or resizing a selection (when fingers don't draw).
    let selectionPan = UIPanGestureRecognizer()
    /// One finger tapping with the select tool: show the menu, deselect, or offer Paste.
    let selectionTap = UITapGestureRecognizer()
    /// Delete, Copy, Paste, Cut… above the selection.
    let actionBar = SelectionActionBar()

    var pageViews: [UUID: PageView] = [:]
    /// Which pages currently show the thin line along their bottom edge (all but the last).
    var pagesWithBottomEdge: Set<UUID> = []
    /// Stroke outlines are built once and reused for every redraw.
    var renderedStrokes: [UUID: RenderedStroke] = [:]
    /// Strokes left out of the page tiles while a selection of them is being dragged.
    var hiddenStrokeIDs: Set<UUID> = []
    var pendingHandoffs: [PendingHandoff] = []
    var pinchStart: (position: CGFloat, anchor: CGPoint)?
    var zoomDetents = ZoomDetents(zooms: [])
    var lastPencilActivity = Date.distantPast
    var laidOutSize: CGSize = .zero
    /// Zoom relative to "page width fills the screen", kept when the window resizes or rotates.
    var relativeZoom: CGFloat = 1

    // What the current touch is doing.
    var activeStroke: ActiveStroke?
    var eraserPosition: CGPoint?
    var lasso: [CGPoint]?
    var manipulation: Manipulation?
    var selection: Selection?
    var lassoStart: CGPoint?
    /// Where a Paste menu was opened (nil when the menu belongs to the selection).
    var menuPoint: CGPoint?

    // Text boxes and images.
    var renderedItems: [UUID: RenderedItem] = [:]
    /// Decoded image files, by file name.
    var images: [String: CGImage] = [:]
    var loadingImages: Set<String> = []
    /// Items left out of the page tiles while they're edited or dragged.
    var hiddenItemIDs: Set<UUID> = []
    let textView = UITextView()
    /// Drag to set the width of the text box being typed in.
    let textWidthHandle = UIView()
    var textEditing: TextEditing?
    /// How much of the canvas the on-screen keyboard covers.
    var keyboardOverlap: CGFloat = 0
    let importer = ImageImporter()
    var cropping: Cropping?
    let cropDim = CALayer()
    let cropBright = CALayer()
    let cropMask = CAShapeLayer()
    let cropOutline = CAShapeLayer()
    let cropBar = UIStackView()

    /// The text box being typed in.
    struct TextEditing {
        var pageID: UUID
        /// The saved version (nil for a new box).
        var original: PageItem?
        var item: PageItem
    }

    /// An image being cropped. Rects are in page coordinates, before rotation (about `pivot`).
    struct Cropping {
        var placed: NoteDocument.PlacedItem
        /// The whole uncropped image.
        var full: CGRect
        /// The part kept, as fractions of the whole image.
        var crop: CGRect
        /// The center the image turns around (its frame's center when cropping started).
        var pivot: CGPoint
        /// Which edges the current drag moves.
        var dragging: (left: Bool, right: Bool, top: Bool, bottom: Bool)?
    }

    struct ActiveStroke {
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
        /// Set once the stroke has snapped to a clean shape: the shape now (after any dragging).
        var shape: ShapeRecognizer.Shape?
        /// The shape as it snapped, where the pen was then, and the width it's drawn at. Moving
        /// the pen from there reshapes it (see `ShapeAdjusting`).
        var snapped: (shape: ShapeRecognizer.Shape, pen: CGPoint, width: Float)?
    }

    /// Selected strokes, text boxes and images, and the box around them in content coordinates.
    struct Selection {
        var strokes: [NoteDocument.PlacedStroke]
        var items: [NoteDocument.PlacedItem] = []
        var box: CGRect
    }

    /// A selection being moved, resized or rotated. The transform is in content coordinates.
    struct Manipulation {
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
    struct PendingHandoff {
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

    /// Gray space below the last page, in page points. There's none at the sides, so at the
    /// normal zoom the page fills the screen edge to edge.
    static let bottomMargin: CGFloat = 80
    /// Maximum zoom, relative to "page width fills the screen".
    static let maxZoom: CGFloat = 5
    static let pageEdgeColor = InkColor(hex: 0xD1D1D6)
    /// Touches bigger than this (in points) are a palm, not a finger. iPads report touch size in
    /// steps of about 10.4 points, and a fingertip is often 31.
    static let maxFingerRadius: CGFloat = 45
    /// Finger taps right after writing are usually the palm lifting, not an undo.
    static let tapQuietPeriod: TimeInterval = 0.35
    /// Hold the pen this still (screen points) for this long to snap a shape.
    static let holdTolerance: CGFloat = 3
    static let holdDuration: TimeInterval = 0.5
    /// How far the select tool can move (screen points) and still count as a tap.
    static let tapSlop: CGFloat = 6
    /// How close (screen points) a touch must be to a selection handle to grab it.
    static let handleReach: CGFloat = 22
    static let duplicateOffset: CGFloat = 24
    static let inkPasteboardType = "scarlability.ink"

    var drawsWithFinger = false {
        didSet {
            if drawsWithFinger != oldValue { configureTouchTypes() }
        }
    }

    var tool: Tool = .pen {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .select { clearSelection() }
            if oldValue == .text { endTextEditing() }
            finishCropping(apply: true)
            configureTouchTypes()
        }
    }

    init(document: NoteDocument, settings: ToolSettings, session: EditorSession) {
        self.document = document
        self.settings = settings
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.delaysContentTouches = false
        // The toolbar floats over the pages; `topInset` makes room for it instead.
        scrollView.contentInsetAdjustmentBehavior = .never
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

        let pencil = UIPencilInteraction(delegate: self)
        addInteraction(pencil)
        setUpTextEditing()
        setUpImages()
        addSubview(actionBar)
        session.handler = { [weak self] command in self?.perform(command) }

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

    var contentWidth: CGFloat {
        document.pages.map(\.record.size.width).max() ?? PageSize.a4.width
    }

    /// Room at the top for the floating toolbar. When it changes while the first page is at
    /// the top, the page stays just below the toolbar.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            let wasAtTop = scrollView.contentOffset.y <= -oldValue + 0.5
            centerContent()
            if wasAtTop {
                scrollView.contentOffset.y = -topInset
            }
        }
    }

    /// Zoom at which the page width fills the screen.
    var widthFitZoom: CGFloat { bounds.width / contentWidth }

    /// Resolution for the page tiles, chosen so they match the screen pixel for pixel at the
    /// normal writing zoom (page width fills the screen) and at 2×, 4×… that zoom.
    ///
    /// Tiles draw at the layer's scale times a power of two, the smallest one that's at least as
    /// sharp as the screen needs. With the screen's own scale, the normal zoom would get tiles at
    /// 4 px/pt shrunk to 2.6, so finished ink looked softer than the live stroke the moment the
    /// pen lifted. The 0.1% extra keeps rounding from picking the next level up.
    var tileScale: CGFloat {
        let zoom = widthFitZoom
        guard zoom > 0 else { return traitCollection.displayScale }
        let level = pow(2, ceil(log2(zoom)))
        return traitCollection.displayScale * zoom / level * 1.001
    }

    /// Pixels per content point that the page tiles use at the current zoom.
    var tileRasterScale: CGFloat {
        let base = tileScale
        let needed = scrollView.zoomScale * traitCollection.displayScale / base
        // PageTileLayer has levels from 1/8× to 8×.
        let level = min(max(ceil(log2(needed) - 1e-6), -3), 3)
        return base * pow(2, level)
    }

    /// Zoom at which a whole page fills the screen (the toolbar floats over its top).
    var pageFitZoom: CGFloat {
        guard let size = document.pages.first?.record.size else { return widthFitZoom }
        let height = bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
        return min(bounds.width / size.width, height / size.height)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        centerContent()
        if laidOutSize != .zero {
            updateZoomLocks()
        }
    }

    /// The zoom locks, and how far out you can zoom.
    func updateZoomLocks() {
        // In portrait an A4 page that fills the width also nearly fills the height: one lock, not two.
        let pageFit = pageFitZoom
        zoomDetents = ZoomDetents(zooms: abs(pageFit / widthFitZoom - 1) < 0.02 ? [widthFitZoom] : [widthFitZoom, pageFit])
        scrollView.minimumZoomScale = min(widthFitZoom, pageFit) * 0.6
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0, bounds.size != laidOutSize else { return }
        let isFirstLayout = laidOutSize == .zero
        let widthChanged = bounds.width != laidOutSize.width
        laidOutSize = bounds.size

        updateZoomLocks()
        for view in pageViews.values {
            view.tileScale = tileScale
        }
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

    func layoutPages() {
        let width = contentWidth
        var y: CGFloat = 0
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
    func centerContent() {
        let inset = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        // Room at the bottom for the keyboard, so you can scroll the last lines above it.
        scrollView.contentInset = UIEdgeInsets(top: topInset, left: inset, bottom: max(keyboardOverlap, safeAreaInsets.bottom), right: inset)
    }

    /// Remembers which page is in the middle of the screen, for "this page" paper changes and
    /// the page number.
    func updateVisiblePage() {
        let middle = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
        let page = document.pages.first { pageViews[$0.id].map { $0.frame.minY <= middle.y && middle.y < $0.frame.maxY } ?? false }
            ?? (middle.y < 0 ? document.pages.first : document.pages.last)
        document.visiblePageID = page?.id
        if session.visiblePageID != page?.id {
            session.visiblePageID = page?.id
        }
    }

    /// Scrolls so a page's top is just below the toolbar.
    func scrollToPage(_ pageID: UUID) {
        guard let view = pageViews[pageID] else { return }
        let inset = scrollView.adjustedContentInset
        let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let y = min(max(view.frame.minY * scrollView.zoomScale - inset.top, -inset.top), maxY)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
        updateVisiblePage()
    }

    /// The page before or after the one in the middle of the screen.
    func scrollPage(by step: Int) {
        let current = session.visiblePageID.flatMap { document.pageIndex($0) } ?? 0
        let index = min(max(current + step, 0), document.pages.count - 1)
        guard document.pages.indices.contains(index) else { return }
        scrollToPage(document.pages[index].id)
    }

    /// All the pages, in content coordinates.
    func pagesColumn() -> CGRect {
        let frames = document.pages.compactMap { pageViews[$0.id]?.frame }
        guard let first = frames.first else { return .null }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    func highlighterHosts(overlapping bounds: CGRect) -> [LiveInk.HighlighterHost] {
        document.pages.compactMap { page in
            guard let view = pageViews[page.id], view.frame.intersects(bounds) else { return nil }
            return LiveInk.HighlighterHost(layer: view.highlighterHost, frame: view.frame, paper: page.record.paper)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if widthFitZoom > 0 {
            relativeZoom = scrollView.zoomScale / widthFitZoom
        }
        showSelectionOverlay()
        layoutCropControls()
        repositionActionBar()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutTextEditor()
        layoutCropControls()
        repositionActionBar()
        updateVisiblePage()
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            // Text is laid out for one zoom; finish typing before zooming.
            endTextEditing()
            // The pinch moves the page itself from here on, including two-finger panning.
            scrollView.cancelPanning()
            actionBar.hide()
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

    func documentDidChange(_ change: NoteDocument.Change) {
        // Drop a selection whose strokes are gone, or whose page was deleted.
        if let selection, manipulation == nil, selection.strokes.contains(where: { placed in
            !(document.pages.first { $0.id == placed.pageID }?.visibleStrokes.contains { $0.id == placed.stroke.id } ?? false)
        }) || selection.items.contains(where: { document.pageIndex($0.pageID) == nil }) {
            clearSelection()
        }
        switch change {
        case .pagesChanged:
            syncPageViews()
            updateVisiblePage()
        case .inkChanged(let pageID, let area):
            updateInk(onPage: pageID, changedRect: area)
        case .pageRedraw(let pageID):
            updateInk(onPage: pageID, changedRect: nil)
        }
    }

    func syncPageViews() {
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

    func updateInk(onPage pageID: UUID, changedRect: CGRect?) {
        guard let page = document.pages.first(where: { $0.id == pageID }), let view = pageViews[pageID] else { return }
        let strokes = page.visibleStrokes.filter { !hiddenStrokeIDs.contains($0.id) }.map(rendered)
        let items = page.visibleItems.filter { !hiddenItemIDs.contains($0.id) }.map(renderedItem)
        var background: CGImage?
        if case .image(let fileName)? = page.record.background {
            background = images[fileName]
            if background == nil { loadImage(fileName) }
        }
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
                items: items,
                backgroundImage: background,
                bottomEdgeColor: hasBottomEdge ? Self.pageEdgeColor : nil
            ),
            changedRect: changedRect
        )
    }

    func rendered(_ stroke: Stroke) -> RenderedStroke {
        if let cached = renderedStrokes[stroke.id] { return cached }
        let rendered = RenderedStroke(stroke)
        renderedStrokes[stroke.id] = rendered
        return rendered
    }

    func pageOrigin(_ pageID: UUID) -> CGPoint {
        pageViews[pageID]?.frame.origin ?? .zero
    }

    // MARK: - Touches

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        if recognizer.touchType == .pencil {
            lastPencilActivity = Date()
        }
        if recognizer.state == .began, textEditing != nil, tool != .text {
            // Writing elsewhere finishes the text box being typed in.
            endTextEditing()
        }
        if cropping != nil {
            handleCropDrag(recognizer.state, at: recognizer.takeSamples().last?.location)
            return
        }
        switch tool {
        case .pen, .highlighter:
            handleDrawing(recognizer)
        case .eraser:
            handleEraser(recognizer)
        case .select:
            handleSelect(recognizer)
        case .text:
            handleTextTool(recognizer)
        }
    }

    // MARK: - Pen and highlighter

    func handleDrawing(_ recognizer: StrokeGestureRecognizer) {
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

    func beginStroke(_ recognizer: StrokeGestureRecognizer) {
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
                smoothing: CGFloat(settings.smoothing) / scrollView.zoomScale,
                pressureSmoothing: settings.pressureSmoothing / scrollView.zoomScale
            ),
            color: presets.currentColor,
            displayColor: isHighlighter ? presets.currentColor : presets.currentColor.displayed(on: page.record.paper)
        )
        add(samples, forceUpdates: [], predicted: recognizer.predictedLocations)
        document.beginWriting(onPage: page.id)
    }

    func consumeSamples(_ recognizer: StrokeGestureRecognizer) {
        add(recognizer.takeSamples(), forceUpdates: recognizer.takeForceUpdates(), predicted: recognizer.predictedLocations)
    }

    func add(_ samples: [StrokeGestureRecognizer.Sample], forceUpdates: [StrokeGestureRecognizer.ForceUpdate], predicted: [CGPoint]) {
        guard var active = activeStroke else { return }
        let origin = active.pageView.frame.origin
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        // Once snapped, moving the pen reshapes the shape until it lifts: a line's end follows
        // the pen, locking flat or upright on the way.
        if let snapped = active.snapped {
            guard let pen = samples.last.map({ local($0.location) }) else { return }
            let shape = ShapeAdjusting.adjust(snapped.shape, from: snapped.pen, to: pen)
            active.shape = shape
            activeStroke = active
            liveInk.showLiveStroke(ShapeRecognizer.points(for: shape, width: snapped.width), color: active.displayColor,
                                   tool: active.tool, pageOrigin: origin)
            return
        }

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
        let points = active.builder.livePoints(predicted: predicted.map(local), predictionScale: CGFloat(settings.tipLead))
        activeStroke = active
        liveInk.showLiveStroke(points, color: active.displayColor, tool: active.tool, pageOrigin: origin)
    }

    /// The pen has held still: if the stroke looks like a shape, replace it with a clean one.
    func snapToShape() {
        guard var active = activeStroke, active.shape == nil else { return }
        let points = active.builder.finishedPoints()
        guard let pen = points.last?.location,
              let shape = ShapeRecognizer.recognize(points.map(\.location), linesOnly: active.tool == .highlighter) else { return }
        // A snapped shape is drawn at the stroke's average width.
        let width = points.map(\.width).reduce(0, +) / Float(max(points.count, 1))
        active.shape = shape
        active.snapped = (shape, pen, width)
        activeStroke = active
        liveInk.showLiveStroke(ShapeRecognizer.points(for: shape, width: width), color: active.displayColor, tool: active.tool,
                               pageOrigin: active.pageView.frame.origin)
    }

    func finishStroke() {
        guard var active = activeStroke else { return }
        activeStroke = nil
        active.holdTimer?.cancel()
        var points = active.builder.finishedPoints()
        if let shape = active.shape, let snapped = active.snapped {
            points = ShapeRecognizer.points(for: shape, width: snapped.width)
        }
        guard !points.isEmpty else {
            liveInk.clearLiveStroke()
            document.cancelWriting()
            return
        }

        let origin = active.pageView.frame.origin
        let pieces = place(toContent(points, from: origin), tool: active.tool, color: active.color, createdAt: Date())
        let handoffID = UUID()
        liveInk.handOff(id: handoffID, points: points, color: active.displayColor, tool: active.tool, pageOrigin: origin)
        document.addStroke(pieces)
        waitForTiles(handoffID, toShow: pieces)
    }

    func cancelStroke() {
        guard let active = activeStroke else { return }
        active.holdTimer?.cancel()
        activeStroke = nil
        liveInk.clearLiveStroke()
        document.cancelWriting()
    }

    func toContent(_ points: [InkPoint], from origin: CGPoint) -> [InkPoint] {
        points.map { InkPoint(x: $0.x + Float(origin.x), y: $0.y + Float(origin.y), width: $0.width) }
    }

    /// Turns points in content coordinates into strokes, one piece per page they touch.
    func place(_ contentPoints: [InkPoint], tool: InkTool, color: InkColor, createdAt: Date) -> [NoteDocument.PlacedStroke] {
        let pages = document.pages
        let frames = pages.map { pageViews[$0.id]?.frame ?? .null }
        return PageSplitter.split(contentPoints, pageFrames: frames).map { piece in
            let stroke = Stroke(tool: tool, color: color, points: piece.points, createdAt: createdAt)
            renderedStrokes[stroke.id] = RenderedStroke(stroke)
            return NoteDocument.PlacedStroke(stroke: stroke, pageID: pages[piece.pageIndex].id)
        }
    }

    // MARK: - Eraser

    func handleEraser(_ recognizer: StrokeGestureRecognizer) {
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
    func erase(along locations: [CGPoint]) {
        guard var from = eraserPosition, let last = locations.last else { return }
        let radius = CGFloat(settings.eraserRadius)
        var change = NoteDocument.Edit()
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

    // MARK: - Handing finished strokes from the live ink to the pages

    /// Keeps the live ink's copy of a finished stroke until the page tiles that show it have redrawn.
    func waitForTiles(_ handoffID: UUID, toShow pieces: [NoteDocument.PlacedStroke]) {
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

    func tileDidDraw(onPage pageID: UUID, isInk: Bool, rect: CGRect, version: Int) {
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

    static func isCovered(_ area: CGRect, by tiles: [CGRect]) -> Bool {
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

    func configureTouchTypes() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        strokeRecognizer.allowedTouchTypes = drawsWithFinger ? [pencil, finger] : [pencil]
        scrollView.panGestureRecognizer.allowedTouchTypes = [finger]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = drawsWithFinger ? 2 : 1
        // With finger drawing on, one finger already works the select tool through the stroke recognizer.
        let fingerSelects = (tool == .select || cropping != nil) && !drawsWithFinger
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
            if cropping != nil { return true }
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

    func showColorPickerForCurrentTool() {
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
    var debugStep = 0
    var debugStrokeOrigin = CGPoint.zero

    /// Launch arguments (with `-OpenFirstNote`) for checking things in the Simulator, which has no Pencil:
    /// - `-DebugLiveStroke`: replays a synthetic pen stroke through the live-drawing path. It
    ///   crosses from page 1 onto page 2, stays live for 3 seconds, then finishes.
    /// - `-DebugUndoAfterStroke`: undoes it 2 seconds later.
    /// - `-DebugTools`: replays a highlight, a snapped circle, then a whole-stroke erase and a lasso.
    /// - `-DebugSelectAll`: selects everything on page 1 and shows the action bar.
    /// - `-DebugPages`: adds two pages, then deletes the first.
    /// - `-DebugShapes`: snaps two lines and drags them (one locks flat), then crosses two highlights.
    /// - `-DebugZoom 2`: zooms in first.
    func startDebugScenarioIfRequested() {
        let zoom = UserDefaults.standard.double(forKey: "DebugZoom")
        if zoom > 0 {
            scrollView.zoomScale = widthFitZoom * zoom
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-DebugPages") {
            // Add two pages, then delete the first one; the note should keep the rest.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                document.addPage()
                let added = document.addPage()
                scrollToPage(added)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                if let first = document.pages.first { document.deletePage(first.id) }
            }
            return
        }
        if arguments.contains("-DebugSelectAll"), let page = document.pages.first {
            settings.tool = .select
            setSelection(strokes: page.visibleStrokes.map { .init(stroke: $0, pageID: page.id) },
                         items: page.visibleItems.map { .init(item: $0, pageID: page.id) })
            presentMenu()
            return
        }
        if arguments.contains("-DebugItems") {
            runDebugItemsScenario()
            return
        }
        if arguments.contains("-DebugLongStroke") {
            startDebugLongStroke()
            return
        }
        if arguments.contains("-DebugShapes"), let page = document.pages.first, let pageView = pageViews[page.id] {
            debugStrokeOrigin = CGPoint(x: pageView.frame.minX + 80, y: pageView.frame.minY + 300)
            liveInk.rasterScale = tileRasterScale
            CADisplayLink(target: self, selector: #selector(stepDebugShapes(_:))).add(to: .main, forMode: .common)
            return
        }
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

    /// `-DebugShapes`: two lines that snap, then get dragged: the first to 2° (it locks flat),
    /// the second to 11° (it stays free). Then a highlight, and a second one crossing it that
    /// stays live from 5 to 8 seconds (the crossing must not look darker).
    @objc private func stepDebugShapes(_ link: CADisplayLink) {
        debugStep += 1
        let t = Double(debugStep) / 60
        let o = debugStrokeOrigin
        func pen(_ x: CGFloat, _ y: CGFloat) {
            add([.init(location: CGPoint(x: o.x + x, y: o.y + y), force: 0.3, estimationIndex: nil)], forceUpdates: [], predicted: [])
        }
        func line(from start: Double, dy: CGFloat, dragTo end: CGFloat, tool: InkTool = .pen) {
            switch t - start {
            case 0..<0.02: activeStroke = debugStroke(tool: tool)
            case 0.02..<0.5: let f = (t - start) / 0.5; pen(300 * f, dy + 25 * f)
            // Holding still from 0.5 s snaps it; then the end is dragged.
            case 1.1..<1.5: let f = (t - start - 1.1) / 0.4; pen(300, dy + 25 + (end - 25) * f)
            case 1.5..<1.52: finishStroke()
            default: break
            }
        }
        line(from: 0, dy: 0, dragTo: 12)
        line(from: 2, dy: 80, dragTo: 60)
        switch t {
        case 4..<4.02: activeStroke = debugStroke(tool: .highlighter)
        case 4.02..<4.5: pen(300 * (t - 4) / 0.5, 200)
        case 4.6..<4.62: finishStroke()
        case 5..<5.02: activeStroke = debugStroke(tool: .highlighter)
        case 5.02..<5.5: pen(150 + 10 * sin(t * 9), 150 + 100 * (t - 5) / 0.5)
        case 8..<8.02: finishStroke()
        case 8.5...: link.invalidate()
        default: break
        }
    }

    func debugStroke(tool: InkTool) -> ActiveStroke? {
        guard let page = document.pages.first, let pageView = pageViews[page.id] else { return nil }
        let presets = tool == .highlighter ? settings.highlighter : settings.pen
        return ActiveStroke(pageID: page.id, pageView: pageView, tool: tool,
                            builder: StrokeBuilder(baseWidth: presets.currentSize, curve: settings.pressureCurve,
                                                   smoothing: CGFloat(settings.smoothing) / scrollView.zoomScale,
                                                   pressureSmoothing: settings.pressureSmoothing / scrollView.zoomScale),
                            color: tool == .pen ? .red : presets.currentColor,
                            displayColor: tool == .pen ? .red : presets.currentColor)
    }

    /// `-DebugLongStroke`: three seconds of cursive at the Pencil's 240 samples per second,
    /// delivered 4 per frame with a (slightly wrong) prediction, like real fast writing.
    private func startDebugLongStroke() {
        guard let page = document.pages.first, let pageView = pageViews[page.id] else { return }
        liveInk.rasterScale = tileRasterScale
        activeStroke = debugStroke(tool: .pen)
        debugStrokeOrigin = CGPoint(x: pageView.frame.minX + 50, y: pageView.frame.minY + 600)
        CADisplayLink(target: self, selector: #selector(stepDebugLongStroke(_:))).add(to: .main, forMode: .common)
    }

    @objc private func stepDebugLongStroke(_ link: CADisplayLink) {
        debugStep += 1
        let samplesPerFrame = 4, total = 720
        func location(_ i: Int) -> CGPoint {
            let t = Double(i) / Double(total)
            return CGPoint(x: debugStrokeOrigin.x + t * 480 + 14 * sin(t * .pi * 40),
                           y: debugStrokeOrigin.y - 18 * cos(t * .pi * 40) + 30 * sin(t * .pi * 3))
        }
        let first = (debugStep - 1) * samplesPerFrame
        guard first < total else {
            link.invalidate()
            finishStroke()
            return
        }
        let samples = (first..<min(first + samplesPerFrame, total)).map {
            StrokeGestureRecognizer.Sample(location: location($0), force: 0.3, estimationIndex: nil)
        }
        // The guess runs straight on from the last two samples, overshooting curves.
        let a = location(first + samplesPerFrame - 2), b = location(first + samplesPerFrame - 1)
        let predicted = (1...3).map { CGPoint(x: b.x + (b.x - a.x) * CGFloat($0) * 2, y: b.y + (b.y - a.y) * CGFloat($0) * 2) }
        add(samples, forceUpdates: [], predicted: predicted)
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
                document.setPaper(PaperStyle(template: .lined, color: .paperDark, lineSpacingMillimeters: 10))
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
final class CanvasScrollView: UIScrollView {
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
