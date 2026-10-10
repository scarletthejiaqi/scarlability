#if os(iOS)
import ScarlabilityKit
import UIKit

/// Pictures: inserting them, loading their files, scanned pages, and cropping.
extension NoteCanvasView {
    func setUpImages() {
        importer.onImages = { [weak self] images in self?.insertImages(images, at: nil) }
        importer.onScans = { [weak self] scans in self?.insertScans(scans) }

        cropDim.opacity = 0.35
        cropBright.mask = cropMask
        cropOutline.fillColor = nil
        cropOutline.strokeColor = UIColor.white.cgColor
        cropOutline.shadowColor = UIColor.black.cgColor
        cropOutline.shadowOpacity = 0.4
        cropOutline.shadowRadius = 1
        cropOutline.shadowOffset = .zero
        for (index, layer) in [cropDim, cropBright, cropOutline].enumerated() {
            layer.zPosition = 30 + CGFloat(index)
            layer.isHidden = true
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull(), "path": NSNull(), "hidden": NSNull()]
            contentView.layer.addSublayer(layer)
        }
        cropMask.actions = ["path": NSNull()]

        var cancel = UIButton.Configuration.gray()
        cancel.title = "Cancel"
        var done = UIButton.Configuration.filled()
        done.title = "Done"
        cropBar.addArrangedSubview(UIButton(configuration: cancel, primaryAction: UIAction { [weak self] _ in self?.finishCropping(apply: false) }))
        cropBar.addArrangedSubview(UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in self?.finishCropping(apply: true) }))
        cropBar.spacing = 10
        cropBar.isHidden = true
        addSubview(cropBar)
    }

    /// Commands from the toolbar.
    func perform(_ command: EditorSession.Command) {
        switch command {
        case .goToPage(let pageID):
            scrollToPage(pageID)
            return
        case .scrollPage(let step):
            scrollPage(by: step)
            return
        default:
            break
        }
        guard case .insertImage(let source) = command else {
            applyTextCommand(command)
            return
        }
        endTextEditing()
        if source == .paste {
            menuPoint = viewportCenter
            clearSelection()
            paste()
        } else if let presenter = presentingController {
            importer.present(source, from: presenter)
        }
    }

    /// The view controller to present pickers from.
    var presentingController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if var controller = next as? UIViewController {
                while let presented = controller.presentedViewController { controller = presented }
                return controller
            }
            responder = next
        }
        return nil
    }

    /// The middle of the screen, in content coordinates.
    var viewportCenter: CGPoint {
        scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
    }

    // MARK: - Drawing items

    func renderedItem(_ item: PageItem) -> RenderedItem {
        if let cached = renderedItems[item.id], cached.item == item, item.image == nil || cached.image != nil {
            return cached
        }
        var image: CGImage?
        if let fileName = item.image?.fileName {
            image = images[fileName]
            if image == nil { loadImage(fileName) }
        }
        let rendered = RenderedItem(item, image: image)
        renderedItems[item.id] = rendered
        return rendered
    }

    /// Loads an image file in the background, then redraws the pages that use it.
    func loadImage(_ fileName: String) {
        guard images[fileName] == nil, !loadingImages.contains(fileName) else { return }
        loadingImages.insert(fileName)
        Task {
            let image = await document.loadImage(named: fileName)
            loadingImages.remove(fileName)
            guard let image else { return }
            images[fileName] = image
            for page in document.pages where page.record.background == .image(fileName: fileName)
                || page.visibleItems.contains(where: { $0.image?.fileName == fileName }) {
                updateInk(onPage: page.id, changedRect: nil)
            }
        }
    }

    // MARK: - Inserting

    /// Places pictures in the middle of the screen (or at `point`), about half a page wide,
    /// and selects them so they can be moved or resized right away.
    func insertImages(_ datas: [Data], at point: CGPoint?) {
        let base = point ?? viewportCenter
        var edits: [NoteDocument.ItemEdit] = []
        var placed: [NoteDocument.PlacedItem] = []
        for (index, data) in datas.enumerated() {
            guard let (fileName, image) = storeImage(data) else { continue }
            let center = CGPoint(x: base.x + CGFloat(index) * Self.duplicateOffset, y: base.y + CGFloat(index) * Self.duplicateOffset)
            guard let pageID = page(containing: center) ?? nearestPage(to: center), let view = pageViews[pageID] else { continue }
            var width = view.frame.width * 0.5
            var height = width * CGFloat(image.height) / CGFloat(max(image.width, 1))
            let maxHeight = view.frame.height * 0.6
            if height > maxHeight {
                width *= maxHeight / height
                height = maxHeight
            }
            let local = CGPoint(x: center.x - view.frame.minX, y: center.y - view.frame.minY)
            let frame = CGRect(x: min(max(local.x - width / 2, 0), view.frame.width - width),
                               y: min(max(local.y - height / 2, 0), view.frame.height - height),
                               width: width, height: height)
            let item = PageItem(kind: .image(ImageContent(fileName: fileName)), frame: frame)
            edits.append(.init(pageID: pageID, before: nil, after: item))
            placed.append(.init(item: item, pageID: pageID))
        }
        guard !edits.isEmpty else { return }
        document.apply(NoteDocument.Edit(items: edits))
        settings.tool = .select
        tool = .select
        setSelection(strokes: [], items: placed)
        presentMenu()
    }

    /// Scanned pages become new pages (with the scan as the background) after the page on screen.
    func insertScans(_ datas: [Data]) {
        let fileNames = datas.compactMap { storeImage($0)?.fileName }
        document.insertScannedPages(fileNames, after: document.visiblePageID)
    }

    /// Saves a picture into the note (at most 2400 pixels, as JPEG, or PNG if it was one) and
    /// keeps the decoded image ready to draw.
    func storeImage(_ data: Data) -> (fileName: String, image: CGImage)? {
        guard let image = ImageLoading.cgImage(from: data) else { return nil }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let stored = isPNG ? UIImage(cgImage: image).pngData() : UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
        let fileName = "\(UUID().uuidString).\(isPNG ? "png" : "jpg")"
        document.saveImageFile(stored ?? data, named: fileName)
        images[fileName] = image
        return (fileName, image)
    }

    private func nearestPage(to point: CGPoint) -> UUID? {
        document.pages.min { a, b in
            let fa = pageViews[a.id]?.frame ?? .null, fb = pageViews[b.id]?.frame ?? .null
            return abs(fa.midY - point.y) < abs(fb.midY - point.y)
        }?.id
    }

    // MARK: - Cropping

    /// Shows the whole picture (the cut-off parts dimmed) with draggable edges, and Cancel/Done.
    func startCropping(_ placed: NoteDocument.PlacedItem) {
        guard let content = placed.item.image, let image = images[content.fileName] else { return }
        clearSelection()
        let crop = content.crop, frame = placed.item.frame
        let fullWidth = frame.width / crop.width, fullHeight = frame.height / crop.height
        let full = CGRect(x: frame.minX - crop.minX * fullWidth, y: frame.minY - crop.minY * fullHeight, width: fullWidth, height: fullHeight)
        cropping = Cropping(placed: placed, full: full, crop: crop, pivot: CGPoint(x: frame.midX, y: frame.midY), dragging: nil)
        hiddenItemIDs.insert(placed.item.id)
        updateInk(onPage: placed.pageID, changedRect: nil)
        cropDim.contents = image
        cropBright.contents = image
        configureTouchTypes()
        layoutCropControls()
    }

    /// Where the kept part is, in page coordinates before rotation.
    private func keptRect(_ cropping: Cropping) -> CGRect {
        CGRect(x: cropping.full.minX + cropping.crop.minX * cropping.full.width, y: cropping.full.minY + cropping.crop.minY * cropping.full.height,
               width: cropping.crop.width * cropping.full.width, height: cropping.crop.height * cropping.full.height)
    }

    func layoutCropControls() {
        guard let cropping, let view = pageViews[cropping.placed.pageID] else {
            [cropDim, cropBright, cropOutline].forEach { $0.isHidden = true }
            cropBar.isHidden = true
            return
        }
        let zoom = scrollView.zoomScale
        let full = cropping.full.offsetBy(dx: view.frame.minX, dy: view.frame.minY)
        let pivot = CGPoint(x: cropping.pivot.x + view.frame.minX, y: cropping.pivot.y + view.frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [cropDim, cropBright, cropOutline] {
            layer.isHidden = false
            layer.anchorPoint = CGPoint(x: (pivot.x - full.minX) / full.width, y: (pivot.y - full.minY) / full.height)
            layer.bounds = CGRect(origin: .zero, size: full.size)
            layer.position = pivot
            layer.setAffineTransform(CGAffineTransform(rotationAngle: cropping.placed.item.rotation))
        }
        let kept = CGRect(x: cropping.crop.minX * full.width, y: cropping.crop.minY * full.height,
                          width: cropping.crop.width * full.width, height: cropping.crop.height * full.height)
        cropMask.path = CGPath(rect: kept, transform: nil)
        let outline = CGMutablePath()
        outline.addRect(kept)
        let radius = 6 / zoom
        for corner in [CGPoint(x: kept.minX, y: kept.minY), CGPoint(x: kept.maxX, y: kept.minY),
                       CGPoint(x: kept.maxX, y: kept.maxY), CGPoint(x: kept.minX, y: kept.maxY)] {
            outline.addEllipse(in: CGRect(x: corner.x - radius, y: corner.y - radius, width: 2 * radius, height: 2 * radius))
        }
        cropOutline.path = outline
        cropOutline.lineWidth = 2 / zoom
        CATransaction.commit()

        let top = contentView.convert(contentView.layer.convert(CGPoint(x: kept.midX, y: kept.minY), from: cropOutline), to: self)
        let size = cropBar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        cropBar.bounds = CGRect(origin: .zero, size: size)
        cropBar.center = CGPoint(x: top.x, y: max(top.y - size.height, safeAreaInsets.top + size.height / 2 + 8))
        cropBar.isHidden = false
    }

    /// Drags an edge or corner of the crop (content coordinates).
    func handleCropDrag(_ state: UIGestureRecognizer.State, at contentPoint: CGPoint?) {
        guard var cropping, let view = pageViews[cropping.placed.pageID] else { return }
        let rotation = cropping.placed.item.rotation
        let unrotate = CGAffineTransform(translationX: cropping.pivot.x, y: cropping.pivot.y).rotated(by: -rotation)
            .translatedBy(x: -cropping.pivot.x, y: -cropping.pivot.y)
        let point = contentPoint.map { CGPoint(x: $0.x - view.frame.minX, y: $0.y - view.frame.minY).applying(unrotate) }
        let kept = keptRect(cropping)
        switch state {
        case .began:
            guard let point else { return }
            let reach = Self.handleReach / scrollView.zoomScale
            let withinY = point.y > kept.minY - reach && point.y < kept.maxY + reach
            let withinX = point.x > kept.minX - reach && point.x < kept.maxX + reach
            let left = abs(point.x - kept.minX) < reach && withinY
            let right = !left && abs(point.x - kept.maxX) < reach && withinY
            let top = abs(point.y - kept.minY) < reach && withinX
            let bottom = !top && abs(point.y - kept.maxY) < reach && withinX
            cropping.dragging = left || right || top || bottom ? (left, right, top, bottom) : nil
        case .changed:
            guard let edges = cropping.dragging, let point else { return }
            let minimum: CGFloat = 20
            var minX = kept.minX, maxX = kept.maxX, minY = kept.minY, maxY = kept.maxY
            if edges.left { minX = min(max(point.x, cropping.full.minX), maxX - minimum) }
            if edges.right { maxX = max(min(point.x, cropping.full.maxX), minX + minimum) }
            if edges.top { minY = min(max(point.y, cropping.full.minY), maxY - minimum) }
            if edges.bottom { maxY = max(min(point.y, cropping.full.maxY), minY + minimum) }
            cropping.crop = CGRect(x: (minX - cropping.full.minX) / cropping.full.width, y: (minY - cropping.full.minY) / cropping.full.height,
                                   width: (maxX - minX) / cropping.full.width, height: (maxY - minY) / cropping.full.height)
        default:
            cropping.dragging = nil
        }
        self.cropping = cropping
        layoutCropControls()
    }

    /// Leaves crop mode, keeping the new crop if `apply`.
    func finishCropping(apply: Bool) {
        guard let cropping else { return }
        self.cropping = nil
        layoutCropControls()
        hiddenItemIDs.remove(cropping.placed.item.id)
        configureTouchTypes()
        guard apply, var content = cropping.placed.item.image, content.crop != cropping.crop else {
            updateInk(onPage: cropping.placed.pageID, changedRect: nil)
            return
        }
        var item = cropping.placed.item
        let kept = keptRect(cropping)
        // The kept part turns around the old center; store it turning around its own center instead.
        let turn = CGAffineTransform(translationX: cropping.pivot.x, y: cropping.pivot.y).rotated(by: item.rotation)
            .translatedBy(x: -cropping.pivot.x, y: -cropping.pivot.y)
        let center = CGPoint(x: kept.midX, y: kept.midY).applying(turn)
        item.frame = CGRect(x: center.x - kept.width / 2, y: center.y - kept.height / 2, width: kept.width, height: kept.height)
        content.crop = cropping.crop
        item.kind = .image(content)
        document.apply(NoteDocument.Edit(items: [.init(pageID: cropping.placed.pageID, before: cropping.placed.item, after: item)]))
        setSelection(strokes: [], items: [.init(item: item, pageID: cropping.placed.pageID)])
        presentMenu()
    }

    #if DEBUG
    /// `-DebugItems`: types a text box (with bold and a bulleted list), inserts and crops a
    /// picture, then adds a scanned page. For checking in the Simulator.
    func runDebugItemsScenario() {
        guard let page = document.pages.first, let view = pageViews[page.id] else { return }
        let origin = view.frame.origin
        func after(_ seconds: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        // A test picture: a blue-to-orange gradient with a white circle.
        let size = CGSize(width: 400, height: 300)
        let picture = UIGraphicsImageRenderer(size: size).pngData { context in
            let colors = [UIColor.systemBlue.cgColor, UIColor.systemOrange.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 150, y: 100, width: 100, height: 100))
        }
        after(0.5) { [self] in
            settings.tool = .text
            tool = .text
            textToolTapped(at: CGPoint(x: origin.x + 60, y: origin.y + 560))
            textView.insertText("Typed notes ")
            applyTextCommand(.bold)
            textView.insertText("in bold")
            applyTextCommand(.bold)
            textView.insertText("\nShopping:")
            textView.insertText("\n")
            applyTextCommand(.bullets)
            textView.insertText("milk")
            if textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n") { textView.insertText("\n") }
            textView.insertText("eggs")
        }
        after(2.5) { [self] in
            endTextEditing()
            insertImages([picture], at: CGPoint(x: origin.x + 420, y: origin.y + 640))
        }
        after(4) { [self] in
            guard let placed = selection?.items.first else { return }
            startCropping(placed)
            // Drag the left edge a third of the way in.
            let frame = placed.item.frame
            handleCropDrag(.began, at: CGPoint(x: origin.x + frame.minX, y: origin.y + frame.midY))
            handleCropDrag(.changed, at: CGPoint(x: origin.x + frame.minX + frame.width / 3, y: origin.y + frame.midY))
            handleCropDrag(.ended, at: nil)
        }
        after(6) { [self] in
            finishCropping(apply: true)
        }
        if ProcessInfo.processInfo.arguments.contains("-DebugUndoAll") {
            // Undo the crop, the picture and the text box; the page should be as it started.
            after(7) { [self] in
                clearSelection()
                document.undo()
                document.undo()
                document.undo()
                let inset = scrollView.adjustedContentInset
                scrollView.contentOffset = CGPoint(x: -inset.left, y: -inset.top)
            }
            return
        }
        after(7.5) { [self] in
            clearSelection()
            insertScans([picture])
        }
        after(8.5) { [self] in
            // Show the scanned page (page 2).
            if let second = document.pages.dropFirst().first, let view = pageViews[second.id] {
                scrollView.contentOffset.y = view.frame.minY * scrollView.zoomScale - 40
            }
        }
    }
    #endif
}
#endif
