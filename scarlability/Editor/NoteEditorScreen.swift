#if os(iOS)
import SwiftUI

struct NoteEditorScreen: View {
    let document: NoteDocument
    @Environment(AppModel.self) private var model
    @State private var session = EditorSession()

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, settings: model.toolSettings, session: session)
            Divider()
            NoteCanvas(document: document, settings: model.toolSettings, session: session)
                .id(ObjectIdentifier(document))
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
#endif
