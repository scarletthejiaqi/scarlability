#if os(iOS)
import ScarlabilityKit
import UIKit

/// Keyboard and menu commands (a hardware keyboard on iPad; the menu bar on Mac): undo and redo
/// through the system's Undo, Copy/Cut/Paste/Select All/Delete for the selection, Escape, and
/// zooming.
extension NoteCanvasView {
    override var canBecomeFirstResponder: Bool { true }

    /// The system's Undo and Redo (⌘Z, ⇧⌘Z, Edit menu) act on whatever has focus. While typing
    /// in a text box that's the text box; otherwise it's this, which undoes the note.
    override var undoManager: UndoManager? { documentUndo }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(title: "Zoom In", action: #selector(zoomInCommand), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(zoomOutCommand), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Fit Page Width", action: #selector(zoomToWidthCommand), input: "0", modifierFlags: .command),
        ]
        if selection != nil {
            commands.append(UIKeyCommand(title: "Delete Selection", action: #selector(deleteSelectionCommand), input: UIKeyCommand.inputDelete))
            commands.append(UIKeyCommand(title: "Duplicate", action: #selector(duplicateCommand), input: "d", modifierFlags: .command))
        }
        if selection != nil || textEditing != nil {
            commands.append(UIKeyCommand(title: "Done", action: #selector(escapeCommand), input: UIKeyCommand.inputEscape))
        }
        for command in commands {
            command.wantsPriorityOverSystemBehavior = true
        }
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): selection != nil
        case #selector(paste(_:)): canPaste
        case #selector(selectAll(_:)): true
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) {
        copySelection()
    }

    override func cut(_ sender: Any?) {
        cutSelection()
    }

    override func paste(_ sender: Any?) {
        // Next to the selection, or in the middle of the screen.
        if selection == nil {
            menuPoint = viewportCenter
        }
        paste()
    }

    override func delete(_ sender: Any?) {
        deleteSelection()
    }

    /// Selects everything on the page in the middle of the screen.
    override func selectAll(_ sender: Any?) {
        guard let pageID = document.visiblePageID ?? document.pages.first?.id, let page = document.pages.first(where: { $0.id == pageID }) else { return }
        endTextEditing()
        settings.tool = .select
        tool = .select
        setSelection(strokes: page.visibleStrokes.map { .init(stroke: $0, pageID: pageID) },
                     items: page.visibleItems.map { .init(item: $0, pageID: pageID) })
        if selection != nil { presentMenu() }
    }

    @objc func deleteSelectionCommand() { deleteSelection() }
    @objc func duplicateCommand() { duplicateSelection() }

    @objc func escapeCommand() {
        if textEditing != nil {
            endTextEditing()
        } else {
            clearSelection()
        }
    }

    @objc func zoomInCommand() { zoom(by: 1.25) }
    @objc func zoomOutCommand() { zoom(by: 0.8) }

    @objc func zoomToWidthCommand() {
        scrollView.setZoomScale(widthFitZoom, animated: true)
    }

    private func zoom(by factor: CGFloat) {
        let zoom = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        scrollView.setZoomScale(zoom, animated: true)
    }
}

/// The note's undo history, as the system's Undo and Redo see it.
final class DocumentUndoManager: UndoManager {
    weak var document: NoteDocument?
    /// Before undoing, finish anything in progress (like a selection being shown).
    var willUndo: () -> Void = {}

    override var canUndo: Bool { document?.canUndo ?? false }
    override var canRedo: Bool { document?.canRedo ?? false }

    override func undo() {
        willUndo()
        document?.undo()
    }

    override func redo() {
        willUndo()
        document?.redo()
    }
}
#endif
