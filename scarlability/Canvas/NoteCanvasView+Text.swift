#if os(iOS)
import ScarlabilityKit
import UIKit

/// The Text tool: tap the page to type in a text box there (or tap an existing box to edit it).
///
/// While typing, a `UITextView` sits over the box in screen space, showing the text at the current
/// zoom so it stays sharp; the box itself is hidden from the page tiles until typing ends.
extension NoteCanvasView: UITextViewDelegate {
    func setUpTextEditing() {
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
        textView.layer.borderWidth = 1
        textView.isHidden = true
        textView.delegate = self
        addSubview(textView)

        textWidthHandle.backgroundColor = .systemBlue
        textWidthHandle.layer.cornerRadius = 3
        textWidthHandle.frame = CGRect(x: 0, y: 0, width: 6, height: 26)
        textWidthHandle.isHidden = true
        textWidthHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleTextWidthDrag(_:))))
        addSubview(textWidthHandle)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// Keeps the text box being typed in above the keyboard.
    @objc func keyboardWillChangeFrame(_ notification: Notification) {
        var overlap: CGFloat = 0
        if notification.name != UIResponder.keyboardWillHideNotification,
           let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let screen = window?.windowScene?.screen {
            overlap = max(0, bounds.maxY - convert(frame, from: screen.coordinateSpace).minY)
        }
        keyboardOverlap = overlap
        centerContent()
        scrollTextEditorIntoView()
    }

    /// Scrolls so the text box being typed in is fully visible above the keyboard.
    func scrollTextEditorIntoView() {
        guard textEditing != nil else { return }
        let visibleBottom = bounds.maxY - keyboardOverlap - 24
        let visibleTop = bounds.minY + 24
        var offset = scrollView.contentOffset
        if textView.frame.maxY > visibleBottom {
            offset.y += min(textView.frame.maxY - visibleBottom, textView.frame.minY - visibleTop)
        } else if textView.frame.minY < visibleTop {
            offset.y -= visibleTop - textView.frame.minY
        }
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        offset.y = min(max(offset.y, -scrollView.adjustedContentInset.top), max(maxY, -scrollView.adjustedContentInset.top))
        if offset != scrollView.contentOffset {
            scrollView.setContentOffset(offset, animated: true)
        }
    }

    func handleTextTool(_ recognizer: StrokeGestureRecognizer) {
        let locations = recognizer.takeSamples().map(\.location)
        switch recognizer.state {
        case .began:
            lassoStart = locations.first
        case .ended:
            defer { lassoStart = nil }
            guard let start = lassoStart else { return }
            let end = locations.last ?? start
            // A tap, not a drag.
            if end.distance(to: start) < Self.tapSlop / scrollView.zoomScale {
                textToolTapped(at: start)
            }
        default:
            break
        }
    }

    /// Taps with the Text tool: edit the box under the tap, or start a new one there.
    func textToolTapped(at point: CGPoint) {
        if let editing = textEditing, let view = pageViews[editing.pageID] {
            let local = CGPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY)
            if editing.item.contains(local) { return }
            endTextEditing()
        }
        if let hit = item(at: point), hit.item.text != nil {
            beginTextEditing(hit, isNew: false)
            return
        }
        guard let pageID = page(containing: point), let view = pageViews[pageID] else { return }
        let style = settings.textStyle
        let content = TextContent(runs: [style])
        let size = TextLayout.size(of: content, maxWidth: view.frame.width)
        // Put the first line's middle at the tap.
        let local = CGPoint(x: point.x - view.frame.minX - TextLayout.padding, y: point.y - view.frame.minY - size.height / 2)
        let item = PageItem(kind: .text(content), frame: CGRect(origin: local, size: size))
        beginTextEditing(NoteDocument.PlacedItem(item: item, pageID: pageID), isNew: true)
    }

    func beginTextEditing(_ placed: NoteDocument.PlacedItem, isNew: Bool) {
        guard let text = placed.item.text, let page = document.pages.first(where: { $0.id == placed.pageID }) else { return }
        textEditing = TextEditing(pageID: placed.pageID, original: isNew ? nil : placed.item, item: placed.item)
        hiddenItemIDs.insert(placed.item.id)
        updateInk(onPage: placed.pageID, changedRect: placed.item.bounds)
        let zoom = scrollView.zoomScale
        textView.attributedText = TextBridge.attributedString(text, zoom: zoom, paper: page.record.paper)
        textView.typingAttributes = TextBridge.attributes(for: text.runs.last ?? settings.textStyle, zoom: zoom, paper: page.record.paper)
        textView.isHidden = false
        layoutTextEditor()
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: textView.attributedText.length, length: 0)
        session.isEditingText = true
        updateSessionStyle()
    }

    /// Saves the text box being typed in (or deletes it, if it ended up empty).
    func endTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        textView.resignFirstResponder()
        textView.isHidden = true
        textWidthHandle.isHidden = true
        session.isEditingText = false
        hiddenItemIDs.remove(editing.item.id)
        if editing.item.text?.isEmpty ?? true {
            if let original = editing.original {
                document.apply(NoteDocument.Edit(items: [.init(pageID: editing.pageID, before: original, after: nil)]))
            } else {
                updateInk(onPage: editing.pageID, changedRect: editing.item.bounds)
            }
        } else if editing.original != editing.item {
            document.apply(NoteDocument.Edit(items: [.init(pageID: editing.pageID, before: editing.original, after: editing.item)]))
        } else {
            updateInk(onPage: editing.pageID, changedRect: editing.item.bounds)
        }
    }

    /// Places the text view over its box (call after scrolling or when the box changes size).
    func layoutTextEditor() {
        guard let editing = textEditing, let view = pageViews[editing.pageID] else { return }
        let zoom = scrollView.zoomScale
        let frame = editing.item.frame
        textView.textContainerInset = UIEdgeInsets(top: TextLayout.padding * zoom, left: TextLayout.padding * zoom,
                                                   bottom: TextLayout.padding * zoom, right: TextLayout.padding * zoom)
        textView.transform = .identity
        textView.bounds = CGRect(origin: .zero, size: CGSize(width: frame.width * zoom, height: frame.height * zoom))
        textView.center = contentView.convert(CGPoint(x: frame.midX + view.frame.minX, y: frame.midY + view.frame.minY), to: self)
        textView.transform = CGAffineTransform(rotationAngle: editing.item.rotation)
        // The width handle sits on the right edge (shown for unrotated boxes).
        textWidthHandle.isHidden = editing.item.rotation != 0
        textWidthHandle.center = CGPoint(x: textView.frame.maxX + 1, y: textView.frame.midY)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard var editing = textEditing, let view = pageViews[editing.pageID],
              let page = document.pages.first(where: { $0.id == editing.pageID }) else { return }
        let zoom = scrollView.zoomScale
        TextBridge.applyListIndents(textView.textStorage, zoom: zoom)
        let content = TextBridge.content(from: textView.attributedText, fallback: settings.textStyle, fixedWidth: editing.item.text?.fixedWidth,
                                         zoom: zoom, paper: page.record.paper)
        let size = TextLayout.size(of: content, maxWidth: view.frame.width - editing.item.frame.minX - TextLayout.pageMargin)
        editing.item.kind = .text(content)
        editing.item.frame.size = size
        textEditing = editing
        layoutTextEditor()
        scrollTextEditorIntoView()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateSessionStyle()
    }

    /// Return in a list continues the list; Return on an empty list item ends it.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        let string = textView.textStorage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
        let line = string.substring(with: paragraph).trimmingCharacters(in: .newlines)
        guard let marker = TextLayout.listMarker(in: line) else { return true }
        if line == marker || line == marker.trimmingCharacters(in: .whitespaces) {
            textView.textStorage.replaceCharacters(in: NSRange(location: paragraph.location, length: min((marker as NSString).length, paragraph.length)), with: "")
            textView.selectedRange = NSRange(location: paragraph.location, length: 0)
        } else {
            let next = marker == "• " ? "• " : "\((Int(marker.dropLast(2)) ?? 0) + 1). "
            let insertion = NSAttributedString(string: "\n" + next, attributes: textView.typingAttributes)
            textView.textStorage.replaceCharacters(in: range, with: insertion)
            textView.selectedRange = NSRange(location: range.location + insertion.length, length: 0)
        }
        textViewDidChange(textView)
        return false
    }

    @objc func handleTextWidthDrag(_ pan: UIPanGestureRecognizer) {
        guard var editing = textEditing, var content = editing.item.text else { return }
        let zoom = scrollView.zoomScale
        let x = pan.location(in: textView).x
        content.fixedWidth = Double(max(40, x / zoom))
        editing.item.kind = .text(content)
        textEditing = editing
        textViewDidChange(textView)
    }

    // MARK: - Styling from the toolbar

    func applyTextCommand(_ command: EditorSession.Command) {
        // Read the style where the cursor is now (not a remembered one), so toggles always flip it.
        let style = currentTextStyle()
        switch command {
        case .bold: applyStyle { $0.bold = !style.bold }
        case .italic: applyStyle { $0.italic = !style.italic }
        case .underline: applyStyle { $0.underline = !style.underline }
        case .font(let font): applyStyle { $0.font = font }
        case .size(let size): applyStyle { $0.size = size }
        case .color(let color): applyStyle { $0.color = color }
        case .bullets: toggleList(numbered: false)
        case .numbers: toggleList(numbered: true)
        case .insertImage: break
        }
    }

    /// Changes the selected text, or what's typed next if nothing is selected.
    private func applyStyle(_ change: (inout TextRun) -> Void) {
        guard let editing = textEditing, let page = document.pages.first(where: { $0.id == editing.pageID }) else { return }
        let zoom = scrollView.zoomScale
        let range = textView.selectedRange
        if range.length == 0 {
            var run = TextBridge.run(text: "", attributes: textView.typingAttributes, fallback: settings.textStyle, zoom: zoom, paper: page.record.paper)
            change(&run)
            textView.typingAttributes = TextBridge.attributes(for: run, zoom: zoom, paper: page.record.paper)
        } else {
            let storage = textView.textStorage
            storage.beginEditing()
            storage.enumerateAttributes(in: range) { attributes, subrange, _ in
                var run = TextBridge.run(text: "", attributes: attributes, fallback: settings.textStyle, zoom: zoom, paper: page.record.paper)
                change(&run)
                storage.setAttributes(TextBridge.attributes(for: run, zoom: zoom, paper: page.record.paper), range: subrange)
            }
            storage.endEditing()
            textView.selectedRange = range
            textViewDidChange(textView)
        }
        updateSessionStyle()
    }

    /// Turns the selected paragraphs into a bulleted or numbered list, or back into plain text.
    private func toggleList(numbered: Bool) {
        let storage = textView.textStorage
        let string = storage.string as NSString
        let selected = textView.selectedRange
        var paragraphs: [NSRange] = []
        var location = string.paragraphRange(for: NSRange(location: selected.location, length: 0)).location
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(selected) && location < string.length
        func isWanted(_ marker: String?) -> Bool {
            guard let marker else { return false }
            return numbered ? marker != "• " : marker == "• "
        }
        let removing = paragraphs.allSatisfy { isWanted(TextLayout.listMarker(in: string.substring(with: $0))) }
        var cursorShift = 0
        for (index, paragraph) in paragraphs.enumerated().reversed() {
            let line = (storage.string as NSString).substring(with: paragraph)
            if let marker = TextLayout.listMarker(in: line) {
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: (marker as NSString).length), with: "")
                cursorShift -= (marker as NSString).length
            }
            if !removing {
                let marker = numbered ? "\(index + 1). " : "• "
                let attributes = paragraph.location < storage.length && paragraph.length > 0
                    ? storage.attributes(at: paragraph.location, effectiveRange: nil) : textView.typingAttributes
                storage.insert(NSAttributedString(string: marker, attributes: attributes), at: paragraph.location)
                cursorShift += (marker as NSString).length
            }
        }
        textView.selectedRange = NSRange(location: max(0, selected.location + (paragraphs.count == 1 ? cursorShift : 0)), length: 0)
        textViewDidChange(textView)
    }

    func updateSessionStyle() {
        guard textEditing != nil else { return }
        session.currentStyle = currentTextStyle()
    }

    /// The style of the selected text, or of what will be typed next.
    func currentTextStyle() -> TextRun {
        let range = textView.selectedRange
        let attributes = range.length > 0 && range.location < textView.textStorage.length
            ? textView.textStorage.attributes(at: range.location, effectiveRange: nil)
            : textView.typingAttributes
        let paper = textEditing.flatMap { editing in document.pages.first { $0.id == editing.pageID }?.record.paper } ?? .whiteLined
        return TextBridge.run(text: "", attributes: attributes, fallback: settings.textStyle, zoom: scrollView.zoomScale, paper: paper)
    }

    /// Pasted text from another app becomes a new text box.
    func insertText(_ string: String, at point: CGPoint) {
        guard let pageID = page(containing: point), let view = pageViews[pageID] else { return }
        var style = settings.textStyle
        style.text = string
        let content = TextContent(runs: [style])
        let local = CGPoint(x: point.x - view.frame.minX, y: point.y - view.frame.minY)
        let size = TextLayout.size(of: content, maxWidth: view.frame.width - local.x - TextLayout.pageMargin)
        let item = PageItem(kind: .text(content), frame: CGRect(origin: local, size: size))
        document.apply(NoteDocument.Edit(items: [.init(pageID: pageID, before: nil, after: item)]))
        setSelection(strokes: [], items: [.init(item: item, pageID: pageID)])
    }
}
#endif
