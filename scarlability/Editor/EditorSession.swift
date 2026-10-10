import Foundation
import Observation
import ScarlabilityKit

/// Connects the toolbar to the canvas for one open note: text styling while typing, and
/// inserting images.
@Observable
final class EditorSession {
    enum ImageSource {
        case photos
        case camera
        case scanner
        case files
        case paste
    }

    enum Command {
        case bold
        case italic
        case underline
        case bullets
        case numbers
        case font(TextFont)
        case size(Double)
        case color(InkColor)
        case insertImage(ImageSource)
        case goToPage(UUID)
        /// To the previous (-1) or next (+1) page.
        case scrollPage(Int)
    }

    /// The page in the middle of the screen, set by the canvas.
    var visiblePageID: UUID?

    /// A text box is being typed in.
    var isEditingText = false
    /// The style where the cursor is, so the toolbar can show B / I / U as on or off.
    var currentStyle = TextRun(text: "")

    @ObservationIgnored var handler: ((Command) -> Void)?

    func send(_ command: Command) {
        handler?(command)
    }
}
