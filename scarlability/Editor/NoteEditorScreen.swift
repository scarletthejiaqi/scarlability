#if os(iOS)
import SwiftUI

struct NoteEditorScreen: View {
    let document: NoteDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, settings: model.penSettings)
            Divider()
            NoteCanvas(document: document, settings: model.penSettings)
                .id(ObjectIdentifier(document))
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
#endif
