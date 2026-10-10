#if os(iOS)
import SwiftUI

/// An open note, Notability-style: the pages fill the screen, with the toolbar floating over
/// the top, the page number at the bottom right, and the page panel on the right when it's on.
struct NoteEditorScreen: View {
    let document: NoteDocument
    @Environment(AppModel.self) private var model
    @State private var session = EditorSession()
    @State private var showsPages = false
    /// Where the toolbar ends, from the top of the screen.
    @State private var toolbarBottom: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            NoteCanvas(document: document, settings: model.toolSettings, session: session, topInset: toolbarBottom + 10)
                .id(ObjectIdentifier(document))
                .overlay(alignment: .bottomTrailing) {
                    PageIndicator(document: document, session: session)
                        .padding(.trailing, 14)
                        .padding(.bottom, 24)
                }
            if showsPages {
                // Below the buttons at the top right, which stay over the panel.
                PagePanel(document: document, session: session, topInset: 12 + 52 + 4)
                    .frame(width: PagePanel.width)
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            EditorToolbar(document: document, settings: model.toolSettings, session: session, showsPages: $showsPages,
                          bottom: $toolbarBottom)
                .padding(.top, 12)
                .ignoresSafeArea(edges: .top)
        }
        .background(Color(.secondarySystemBackground))
        .statusBarHidden()
        #if DEBUG
        // `-DebugShowPages` opens the page panel; `-DebugTool pen` picks a tool.
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-DebugShowPages") { showsPages = true }
            if let tool = UserDefaults.standard.string(forKey: "DebugTool").flatMap(Tool.init(rawValue:)) { model.toolSettings.tool = tool }
        }
        #endif
    }
}
#endif
