/// Undo/redo stacks. Recording a new action clears the redo stack, like every other app.
public struct UndoHistory<Action> {
    public private(set) var undoStack: [Action] = []
    public private(set) var redoStack: [Action] = []
    public let limit: Int

    public init(limit: Int = 500) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ action: Action) {
        undoStack.append(action)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    /// Returns the action to undo and moves it to the redo stack.
    public mutating func popUndo() -> Action? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    /// Returns the action to redo and moves it back to the undo stack.
    public mutating func popRedo() -> Action? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }
}

extension UndoHistory: Sendable where Action: Sendable {}
