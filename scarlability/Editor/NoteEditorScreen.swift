#if os(iOS)
import SwiftUI

/// An open note, Notability-style: the pages fill the screen, with the toolbar floating over
/// the top, the page number at the bottom right, and the page panel on the right when it's on.
struct NoteEditorScreen: View {
    let document: NoteDocument
    let model: AppModel
    @State private var session = EditorSession()
    @State private var showsPages = false
    @State private var thumbnails = PageThumbnails()
    /// Where the toolbar ends, from the top of the screen.
    @State private var toolbarBottom: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            NoteCanvas(document: document, settings: model.toolSettings, session: session, topInset: toolbarBottom + 10)
                .id(ObjectIdentifier(document))
                // The page takes its new width in one step while only the panel slides in;
                // resizing it through every frame of the animation made the page flash.
                .transaction { $0.animation = nil }
                .overlay(alignment: .bottomTrailing) {
                    PageIndicator(document: document, session: session)
                        .padding(.trailing, 14)
                        .padding(.bottom, 24)
                }
            if showsPages {
                // Below the buttons at the top right, which stay over the panel.
                PagePanel(document: document, session: session, thumbnails: thumbnails, topInset: 12 + 52 + 4)
                    .frame(width: PagePanel.width)
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            EditorToolbar(document: document, settings: model.toolSettings, session: session, model: model, showsPages: $showsPages,
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
            // `-DebugTogglePages`: open and close the page panel a few times, like tapping its button.
            if ProcessInfo.processInfo.arguments.contains("-DebugTogglePages") {
                for step in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(step)) {
                        withAnimation(.snappy(duration: 0.25)) { showsPages.toggle() }
                    }
                }
            }
            if let tool = UserDefaults.standard.string(forKey: "DebugTool").flatMap(Tool.init(rawValue:)) { model.toolSettings.tool = tool }
        }
        #endif
    }
}
#endif
