#if os(iOS)
import ScarlabilityKit
import UIKit

/// The Select tool: lasso or box around ink, text boxes and images (or tap a text box or
/// image), then move, resize or rotate it, or use the menu above it.
extension NoteCanvasView {
    /// What Copy puts on the pasteboard: positions are relative to the selection's top-left.
    struct ClipboardSelection: Codable {
        /// Strokes, encoded with `InkCodec`.
        var ink: Data
        var items: [PageItem]
        /// Image files used by the items, by file name.
        var images: [String: Data]
    }

    static let selectionPasteboardType = "scarlability.selection"

    // MARK: - Gestures

    func handleSelect(_ recognizer: StrokeGestureRecognizer) {
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

    @objc func handleSelectionPan(_ pan: UIPanGestureRecognizer) {
        let location = pan.location(in: contentView)
        if cropping != nil {
            handleCropDrag(pan.state, at: location)
            return
        }
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

    @objc func handleSelectionTap(_ tap: UITapGestureRecognizer) {
        guard cropping == nil else { return }
        selectToolTapped(at: tap.location(in: contentView))
    }

    /// Which part of the selection a touch at `point` (content coordinates) grabs.
    func selectionGrab(at point: CGPoint) -> Manipulation.Kind? {
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

    func beginSelectGesture(at point: CGPoint) {
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

    func continueSelectGesture(_ point: CGPoint) {
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
            if hiddenStrokeIDs.isEmpty, hiddenItemIDs.isEmpty, !current.transform.isIdentity {
                hide(selection)
            }
            showPreview(of: selection, transform: current.transform)
            showSelectionOverlay()
            return
        }
        guard lasso != nil else { return }
        lasso?.append(point)
        if let path = lassoPath() {
            liveInk.showLasso(path, zoom: scrollView.zoomScale)
        }
    }

    func endSelectGesture() {
        defer {
            lassoStart = nil
            lasso = nil
            liveInk.hideLasso()
        }
        if let current = manipulation {
            manipulation = nil
            if current.transform.isIdentity {
                unhideAll()
                showSelectionOverlay()
            } else {
                commitManipulation(current)
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

    func cancelSelectGesture() {
        if manipulation != nil {
            manipulation = nil
            unhideAll()
            showSelectionOverlay()
        }
        lassoStart = nil
        lasso = nil
        liveInk.hideLasso()
    }

    func selectToolTapped(at point: CGPoint) {
        if let selection, selection.box.insetBy(dx: -8, dy: -8).contains(point) {
            presentMenu()
            return
        }
        if let hit = item(at: point) {
            setSelection(strokes: [], items: [hit])
            presentMenu()
            return
        }
        if selection != nil {
            clearSelection()
        } else if canPaste {
            presentMenu(at: point)
        }
    }

    /// The topmost text box or image at a point (content coordinates).
    func item(at point: CGPoint) -> NoteDocument.PlacedItem? {
        for page in document.pages {
            guard let view = pageViews[page.id], view.frame.contains(point) else { continue }
            let local = CGPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY)
            if let item = page.visibleItems.last(where: { $0.contains(local) }) {
                return NoteDocument.PlacedItem(item: item, pageID: page.id)
            }
        }
        return nil
    }

    /// The lasso outline: freeform as drawn, or the rectangle from start to current point.
    func lassoOutline() -> [CGPoint]? {
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

    func lassoPath() -> CGPath? {
        guard let outline = lassoOutline() else { return nil }
        let path = CGMutablePath()
        path.addLines(between: outline)
        if settings.selectMode == .box { path.closeSubpath() }
        return path
    }

    /// Selects the strokes mostly inside the outline, and the text boxes and images whose
    /// centers are inside it.
    func select(strokesInside outline: [CGPoint]) {
        let xs = outline.map(\.x), ys = outline.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        var strokes: [NoteDocument.PlacedStroke] = []
        var items: [NoteDocument.PlacedItem] = []
        for page in document.pages {
            guard let view = pageViews[page.id], view.frame.intersects(bounds) else { continue }
            let local = outline.map { CGPoint(x: $0.x - view.frame.minX, y: $0.y - view.frame.minY) }
            for stroke in page.visibleStrokes where StrokeHitTesting.lasso(local, selects: stroke) {
                strokes.append(.init(stroke: stroke, pageID: page.id))
            }
            for item in page.visibleItems where StrokeHitTesting.contains(local, CGPoint(x: item.bounds.midX, y: item.bounds.midY)) {
                items.append(.init(item: item, pageID: page.id))
            }
        }
        setSelection(strokes: strokes, items: items)
        if selection != nil {
            presentMenu()
        }
    }

    func setSelection(strokes: [NoteDocument.PlacedStroke], items: [NoteDocument.PlacedItem] = []) {
        guard !strokes.isEmpty || !items.isEmpty else {
            clearSelection()
            return
        }
        var box = strokes.reduce(CGRect.null) { box, placed in
            let origin = pageOrigin(placed.pageID)
            return box.union(placed.stroke.bounds.offsetBy(dx: origin.x, dy: origin.y))
        }
        for placed in items {
            let origin = pageOrigin(placed.pageID)
            box = box.union(placed.item.bounds.offsetBy(dx: origin.x, dy: origin.y))
        }
        selection = Selection(strokes: strokes, items: items, box: box)
        showSelectionOverlay()
    }

    func clearSelection() {
        selection = nil
        unhideAll()
        liveInk.hideSelection()
        editMenu?.dismissMenu()
    }

    func showSelectionOverlay() {
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

    /// Leaves the selection out of the page tiles while its moving preview is shown.
    func hide(_ selection: Selection) {
        hiddenStrokeIDs = Set(selection.strokes.map(\.stroke.id))
        hiddenItemIDs = Set(selection.items.map(\.item.id))
        for pageID in Set(selection.strokes.map(\.pageID) + selection.items.map(\.pageID)) {
            updateInk(onPage: pageID, changedRect: nil)
        }
    }

    func unhideAll() {
        guard !hiddenStrokeIDs.isEmpty || !hiddenItemIDs.isEmpty else { return }
        let editingID = textEditing?.item.id
        let pageIDs = Set(document.pages.filter { page in
            page.visibleStrokes.contains { hiddenStrokeIDs.contains($0.id) } || page.visibleItems.contains { hiddenItemIDs.contains($0.id) }
        }.map(\.id))
        hiddenStrokeIDs = []
        // The text box being typed in stays hidden: the editor shows it.
        hiddenItemIDs = editingID.map { [$0] } ?? []
        liveInk.clearPreview()
        pageIDs.forEach { updateInk(onPage: $0, changedRect: nil) }
    }

    private func showPreview(of selection: Selection, transform: CGAffineTransform) {
        let strokes = selection.strokes.map { placed in
            let rendered = rendered(placed.stroke)
            let origin = pageOrigin(placed.pageID)
            var toContent = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(transform)
            let page = document.pages.first { $0.id == placed.pageID }
            let color = placed.stroke.tool == .pen ? placed.stroke.color.displayed(on: page?.record.paper ?? .whiteLined) : placed.stroke.color
            return LiveInk.Item(path: rendered.path.copy(using: &toContent) ?? rendered.path, color: color.cgColor,
                                tool: placed.stroke.tool, pageOrigin: .zero)
        }
        let objects = selection.items.map { placed in
            let origin = pageOrigin(placed.pageID)
            return (renderedItem(placed.item), CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(transform))
        }
        liveInk.showPreview(strokes, objects: objects)
    }

    func commitManipulation(_ current: Manipulation) {
        guard let selection else { return }
        let strokes = transformedCopies(of: selection.strokes, by: current.transform, widthScale: current.widthScale, keepDepth: true)
        let (edits, items) = transformed(selection.items, by: current)
        hiddenStrokeIDs = []
        hiddenItemIDs = []
        liveInk.clearPreview()
        document.apply(NoteDocument.Edit(removed: selection.strokes, added: strokes, items: edits))
        setSelection(strokes: strokes, items: items)
    }

    /// Copies of strokes moved by a transform in content coordinates, re-split across pages.
    func transformedCopies(of strokes: [NoteDocument.PlacedStroke], by transform: CGAffineTransform, widthScale: CGFloat,
                           keepDepth: Bool) -> [NoteDocument.PlacedStroke] {
        let now = Date()
        return strokes.flatMap { placed -> [NoteDocument.PlacedStroke] in
            let origin = pageOrigin(placed.pageID)
            let toContent = CGAffineTransform(translationX: origin.x, y: origin.y).concatenating(transform)
            let moved = placed.stroke.transformed(toContent, widthScale: widthScale)
            return place(moved.points, tool: moved.tool, color: moved.color, createdAt: keepDepth ? moved.createdAt : now)
        }
    }

    /// Items moved, resized or rotated. An item whose center ends up on another page moves to
    /// that page (as a new item there).
    func transformed(_ items: [NoteDocument.PlacedItem], by manipulation: Manipulation)
        -> (edits: [NoteDocument.ItemEdit], items: [NoteDocument.PlacedItem]) {
        var scale: CGFloat = 1
        if case .resize = manipulation.kind { scale = manipulation.widthScale }
        var edits: [NoteDocument.ItemEdit] = []
        var result: [NoteDocument.PlacedItem] = []
        for placed in items {
            let origin = pageOrigin(placed.pageID)
            var item = placed.item
            let center = CGPoint(x: item.frame.midX + origin.x, y: item.frame.midY + origin.y).applying(manipulation.transform)
            let size = CGSize(width: item.frame.width * scale, height: item.frame.height * scale)
            item.rotation += manipulation.rotation
            if var text = item.text, scale != 1 {
                text.runs = text.runs.map { var run = $0; run.size *= scale; return run }
                text.fixedWidth = text.fixedWidth.map { $0 * scale }
                item.kind = .text(text)
            }
            let pageID = page(containing: center) ?? placed.pageID
            let target = pageOrigin(pageID)
            item.frame = CGRect(x: center.x - target.x - size.width / 2, y: center.y - target.y - size.height / 2,
                                width: size.width, height: size.height)
            if pageID == placed.pageID {
                edits.append(.init(pageID: pageID, before: placed.item, after: item))
            } else {
                item.id = UUID()
                edits.append(.init(pageID: placed.pageID, before: placed.item, after: nil))
                edits.append(.init(pageID: pageID, before: nil, after: item))
            }
            result.append(.init(item: item, pageID: pageID))
        }
        return (edits, result)
    }

    /// The page under a point in content coordinates.
    func page(containing point: CGPoint) -> UUID? {
        document.pages.first { pageViews[$0.id]?.frame.contains(point) == true }?.id
    }

    // MARK: - Menu

    var canPaste: Bool {
        let board = UIPasteboard.general
        return board.contains(pasteboardTypes: [Self.selectionPasteboardType]) || board.hasImages || board.hasStrings
    }

    /// Shows the selection's menu above it, or (with `point`) a Paste menu there.
    func presentMenu(at point: CGPoint? = nil) {
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
        let paste = UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste() }
        guard let selection else {
            return canPaste ? UIMenu(children: [paste]) : nil
        }
        var items: [UIMenuElement] = [
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
        ]
        if canPaste { items.append(paste) }
        items.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelection() })
        if selection.strokes.isEmpty, selection.items.count == 1, let only = selection.items.first {
            if only.item.text != nil {
                items.append(UIAction(title: "Edit Text", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                    self?.clearSelection()
                    self?.settings.tool = .text
                    self?.beginTextEditing(only, isNew: false)
                })
            } else if only.item.image != nil {
                items.append(UIAction(title: "Crop", image: UIImage(systemName: "crop")) { [weak self] _ in self?.startCropping(only) }
                )
            }
        }
        if !selection.strokes.isEmpty || selection.items.contains(where: { $0.item.text != nil }) {
            items.append(colorMenu())
        }
        if !selection.strokes.isEmpty {
            items.append(UIMenu(title: "Thickness", image: UIImage(systemName: "lineweight"), children: [
                UIAction(title: "Thinner") { [weak self] _ in self?.scaleSelectionWidth(by: 0.8) },
                UIAction(title: "Thicker") { [weak self] _ in self?.scaleSelectionWidth(by: 1.25) },
            ]))
        }
        items += [
            UIAction(title: "Copy as Image", image: UIImage(systemName: "photo")) { [weak self] _ in self?.copySelectionAsImage() },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ]
        return UIMenu(children: items)
    }

    func colorMenu() -> UIMenu {
        let menu = UIMenu(title: "Color", image: UIImage(systemName: "paintpalette"), children: colorActions())
        menu.preferredElementSize = .small
        return menu
    }

    func colorActions() -> [UIMenuElement] {
        var colors = settings.pen.colors + settings.highlighter.colors + settings.text.colors
        colors += [settings.pen.extraColor, settings.highlighter.extraColor, settings.text.extraColor].compactMap { $0 }
        var seen = Set<InkColor>()
        let unique = colors.filter { seen.insert($0).inserted }
        var actions: [UIMenuElement] = unique.map { color in
            let swatch = UIImage(systemName: "circle.fill")?.withTintColor(UIColor(cgColor: color.cgColor), renderingMode: .alwaysOriginal)
            return UIAction(title: "", image: swatch) { [weak self] _ in self?.recolorSelection(color) }
        }
        actions.append(UIAction(title: "More Colors…", image: UIImage(systemName: "eyedropper")) { [weak self] _ in
            guard let self, let selection = self.selection else { return }
            let rect = self.contentView.convert(selection.box, to: nil)
            let start = selection.strokes.first?.stroke.color ?? selection.items.first?.item.text?.runs.first?.color ?? .black
            ColorPickerPresenter.shared.present(color: start, from: rect) { [weak self] color in self?.recolorSelection(color) }
        })
        return actions
    }

    func recolorSelection(_ color: InkColor) {
        replaceSelection(strokes: { $0.replacement(color: color) }, items: { item in
            guard var text = item.text else { return item }
            text.runs = text.runs.map { var run = $0; run.color = color; return run }
            var item = item
            item.kind = .text(text)
            return item
        })
    }

    func scaleSelectionWidth(by factor: Float) {
        replaceSelection(strokes: { stroke in
            stroke.replacement(points: stroke.points.map { InkPoint(x: $0.x, y: $0.y, width: $0.width * factor) })
        }, items: { $0 })
        presentMenu()
    }

    func replaceSelection(strokes changeStroke: (Stroke) -> Stroke, items changeItem: (PageItem) -> PageItem) {
        guard let selection else { return }
        let strokes = selection.strokes.map { NoteDocument.PlacedStroke(stroke: changeStroke($0.stroke), pageID: $0.pageID) }
        strokes.forEach { renderedStrokes[$0.stroke.id] = RenderedStroke($0.stroke) }
        let items = selection.items.map { NoteDocument.PlacedItem(item: changeItem($0.item), pageID: $0.pageID) }
        let edits = zip(selection.items, items).filter { $0.0.item != $0.1.item }
            .map { NoteDocument.ItemEdit(pageID: $0.0.pageID, before: $0.0.item, after: $0.1.item) }
        document.apply(NoteDocument.Edit(removed: selection.strokes, added: strokes, items: edits))
        setSelection(strokes: strokes, items: items)
    }

    func duplicateSelection() {
        guard let selection else { return }
        let offset = CGAffineTransform(translationX: Self.duplicateOffset, y: Self.duplicateOffset)
        let strokes = transformedCopies(of: selection.strokes, by: offset, widthScale: 1, keepDepth: false)
        let items = selection.items.compactMap { placed -> NoteDocument.PlacedItem? in
            var item = placed.item
            item.id = UUID()
            item.createdAt = Date()
            item.frame = item.frame.offsetBy(dx: Self.duplicateOffset, dy: Self.duplicateOffset)
            return NoteDocument.PlacedItem(item: item, pageID: placed.pageID)
        }
        document.apply(NoteDocument.Edit(added: strokes, items: items.map { .init(pageID: $0.pageID, before: nil, after: $0.item) }))
        setSelection(strokes: strokes, items: items)
        presentMenu()
    }

    func deleteSelection() {
        guard let selection else { return }
        document.apply(NoteDocument.Edit(removed: selection.strokes, items: selection.items.map { .init(pageID: $0.pageID, before: $0.item, after: nil) }))
        clearSelection()
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Copies the selection (ink, text boxes and pictures) for pasting in this app.
    func copySelection() {
        guard let selection else { return }
        let box = selection.box
        let strokes = selection.strokes.map { placed in
            let origin = pageOrigin(placed.pageID)
            return placed.stroke.transformed(CGAffineTransform(translationX: origin.x - box.minX, y: origin.y - box.minY))
        }
        let items = selection.items.map { placed in
            var item = placed.item
            let origin = pageOrigin(placed.pageID)
            item.frame = item.frame.offsetBy(dx: origin.x - box.minX, dy: origin.y - box.minY)
            return item
        }
        let fileNames = Set(items.compactMap(\.image?.fileName))
        Task {
            var images: [String: Data] = [:]
            for name in fileNames {
                images[name] = await document.imageData(named: name)
            }
            guard let ink = try? InkCodec.encode(DeviceInk(strokes: strokes)),
                  let data = try? JSONEncoder().encode(ClipboardSelection(ink: ink, items: items, images: images)) else { return }
            UIPasteboard.general.setData(data, forPasteboardType: Self.selectionPasteboardType)
        }
    }

    /// Pastes copied ink and items, or a picture or text copied in another app, centered where
    /// the menu was opened (or next to the selection).
    func paste() {
        let target: CGPoint
        if let menuPoint {
            target = menuPoint
        } else if let selection {
            target = CGPoint(x: selection.box.midX + Self.duplicateOffset, y: selection.box.midY + Self.duplicateOffset)
        } else {
            return
        }
        let board = UIPasteboard.general
        if let data = board.data(forPasteboardType: Self.selectionPasteboardType),
           let copied = try? JSONDecoder().decode(ClipboardSelection.self, from: data) {
            pasteSelection(copied, centeredAt: target)
        } else if let image = board.image, let data = image.pngData() {
            insertImages([data], at: target)
        } else if let string = board.string, !string.isEmpty {
            insertText(string, at: target)
        }
    }

    private func pasteSelection(_ copied: ClipboardSelection, centeredAt target: CGPoint) {
        let strokesIn = (try? InkCodec.decode(copied.ink).strokes) ?? []
        var box = strokesIn.reduce(CGRect.null) { $0.union($1.bounds) }
        copied.items.forEach { box = box.union($0.bounds) }
        guard !box.isNull else { return }
        let dx = target.x - box.midX, dy = target.y - box.midY
        let now = Date()
        let strokes = strokesIn.flatMap { stroke -> [NoteDocument.PlacedStroke] in
            let moved = stroke.transformed(CGAffineTransform(translationX: dx, y: dy))
            return place(moved.points, tool: moved.tool, color: moved.color, createdAt: now)
        }
        // Pictures get their own files in this note.
        var renamed: [String: String] = [:]
        for (name, data) in copied.images {
            let newName = "\(UUID().uuidString).\((name as NSString).pathExtension)"
            renamed[name] = newName
            document.saveImageFile(data, named: newName)
            images[newName] = ImageLoading.cgImage(from: data)
        }
        var items: [NoteDocument.PlacedItem] = []
        for var item in copied.items {
            item.id = UUID()
            item.createdAt = now
            if var image = item.image {
                image.fileName = renamed[image.fileName] ?? image.fileName
                item.kind = .image(image)
            }
            let center = CGPoint(x: item.frame.midX + dx, y: item.frame.midY + dy)
            guard let pageID = page(containing: center) ?? page(containing: target) else { continue }
            let origin = pageOrigin(pageID)
            item.frame.origin = CGPoint(x: center.x - origin.x - item.frame.width / 2, y: center.y - origin.y - item.frame.height / 2)
            items.append(.init(item: item, pageID: pageID))
        }
        document.apply(NoteDocument.Edit(added: strokes, items: items.map { .init(pageID: $0.pageID, before: nil, after: $0.item) }))
        setSelection(strokes: strokes, items: items)
        presentMenu()
    }

    /// Copies the selection as a picture, for pasting into other apps.
    func copySelectionAsImage() {
        guard let selection else { return }
        let box = selection.box.insetBy(dx: -4, dy: -4)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: box.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -box.minX, y: -box.minY)
            let clip = CGRect(origin: .zero, size: .init(width: 10_000, height: 10_000))
            for pageID in Set(selection.strokes.map(\.pageID) + selection.items.map(\.pageID)) {
                let origin = pageOrigin(pageID)
                let strokes = selection.strokes.filter { $0.pageID == pageID }.map { rendered($0.stroke) }
                let items = selection.items.filter { $0.pageID == pageID }.map { renderedItem($0.item) }
                cg.saveGState()
                cg.translateBy(x: origin.x, y: origin.y)
                ItemRenderer.draw(items, paper: nil, in: cg, clip: clip)
                PageRenderer.drawHighlights(strokes, in: cg, clip: clip)
                PageRenderer.drawInk(strokes, paper: .whiteLined, in: cg, clip: clip)
                cg.restoreGState()
            }
        }
        UIPasteboard.general.image = image
    }
}
#endif
