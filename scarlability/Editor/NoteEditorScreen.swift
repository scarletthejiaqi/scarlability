#if os(iOS)
import ScarlabilityKit
import SwiftUI

/// An open note, Notability-style: the pages fill the screen, with the toolbar floating over
/// the top, the page number at the bottom right, and the page panel on the right when it's on.
struct NoteEditorScreen: View {
    let document: NoteDocument
    let model: AppModel
    @State private var session = EditorSession()
    @State private var showsPages = false
    @State private var thumbnails = PageThumbnails()
    @State private var pageBrowser = PageBrowser()
    /// Where the toolbar ends, from the top of the screen.
    @State private var toolbarBottom: CGFloat = 0

    var body: some View {
        // The panel slides in over the canvas; the canvas keeps its size and zooms the page to fit
        // beside the panel, smoothly, staying right against it.
        ZStack(alignment: .trailing) {
            NoteCanvas(document: document, settings: model.toolSettings, session: session, topInset: toolbarBottom + 10,
                       rightInset: showsPages ? PagePanel.width : 0)
                .id(ObjectIdentifier(document))
                .overlay(alignment: .bottomTrailing) {
                    PageIndicator(document: document, session: session)
                        .padding(.trailing, 14 + (showsPages ? PagePanel.width : 0))
                        .padding(.bottom, 24)
                }
            if showsPages {
                // Below the buttons at the top right, which stay over the panel.
                PagePanel(document: document, session: session, thumbnails: thumbnails, browser: pageBrowser, topInset: 12 + 52 + 4)
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
        // The panel's ⤢: every page as a big grid, over the note.
        .overlay {
            if pageBrowser.showsGrid {
                PageGrid(document: document, session: session, thumbnails: thumbnails, browser: pageBrowser)
                    .transition(.opacity)
            }
        }
        .background(Color(.secondarySystemBackground))
        .statusBarHidden()
        .onChange(of: document.wasDeletedElsewhere) { _, deleted in
            guard deleted else { return }
            model.closeDocument()
            if case .ready(let library) = model.state {
                library.errorTitle = "Deleted on Another Device"
                library.errorMessage = "“\(document.note.title)” is in Recently Deleted. Restore it there to keep writing in it."
            }
        }
        #if DEBUG
        // `-DebugShowPages` opens the page panel; `-DebugTool pen` picks a tool.
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-DebugShowPages") { showsPages = true }
            // `-DebugPageSelect` starts Select in the panel with the first page picked;
            // `-DebugPageGrid` opens the grid.
            if ProcessInfo.processInfo.arguments.contains("-DebugPageSelect") {
                pageBrowser.isSelecting = true
                if let first = document.pages.first { pageBrowser.selected = [first.id] }
            }
            if ProcessInfo.processInfo.arguments.contains("-DebugPageGrid") { pageBrowser.showsGrid = true }
            // `-DebugPageOps`: duplicate page 1, bookmark page 2, copy page 1 and paste it at the
            // end, clear the duplicate; then the panel shows Bookmarks only.
            if ProcessInfo.processInfo.arguments.contains("-DebugPageOps") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    let commands = PageCommands(document: document, session: session)
                    guard document.pages.count >= 2 else { return }
                    let first = document.pages[0].id, second = document.pages[1].id
                    let duplicate = await document.duplicatePages([first]).first
                    document.setBookmarked(true, pages: [second])
                    await commands.copy([first])
                    if let last = document.pages.last?.id { commands.paste(after: last) }
                    if let duplicate { document.clearPage(duplicate) }
                    NSLog("DebugPageOps pages=%d bookmarked=%d", document.pages.count, document.pages.filter(\.record.isBookmarked).count)
                    try? await Task.sleep(for: .seconds(1.5))
                    pageBrowser.showsBookmarksOnly = ProcessInfo.processInfo.arguments.contains("-DebugBookmarksOnly")
                }
            }
            // `-DebugTogglePages`: open and close the page panel a few times, like tapping its button.
            if ProcessInfo.processInfo.arguments.contains("-DebugTogglePages") {
                for step in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(step)) {
                        withAnimation(.easeInOut(duration: 0.28)) { showsPages.toggle() }
                    }
                }
            }
            if let tool = UserDefaults.standard.string(forKey: "DebugTool").flatMap(Tool.init(rawValue:)) { model.toolSettings.tool = tool }
        }
        #endif
    }
}
#endif
