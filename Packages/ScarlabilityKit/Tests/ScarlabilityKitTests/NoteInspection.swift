import Foundation
import Testing
@testable import ScarlabilityKit

/// A debugging aid, not a check: prints every stroke saved in a note package. Run with
/// `NOTE_PATH=/path/to/Note.scarnote swift test --filter inspectNote`; without it, does nothing.
struct NoteInspection {
    @Test func inspectNote() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTE_PATH"] else { return }
        let folder = NotebookFolder(root: URL(filePath: path).deletingLastPathComponent(), deviceID: UUID())
        for (i, page) in try folder.loadPages(inNoteAt: URL(filePath: path)).enumerated() {
            for (device, ink) in page.inks {
                for stroke in ink.strokes {
                    let ys = stroke.points.map(\.y), ws = stroke.points.map(\.width)
                    print("page \(i) device \(device.uuidString.prefix(4)) \(stroke.tool) points \(stroke.points.count) y \(ys.min()!)…\(ys.max()!) width \(ws.min()!)…\(ws.max()!)")
                }
            }
        }
    }
}
