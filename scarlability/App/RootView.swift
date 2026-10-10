import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(iOS)
        content
            .onAppear(perform: configureMacWindow)
            .onOpenURL { url in
                if url.pathExtension.lowercased() == "pdf" {
                    model.importPDF(from: url)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    // Write pending changes before the app might be suspended.
                    model.openDocument?.saveNow()
                } else if let document = model.openDocument {
                    // Pick up what other devices wrote while away.
                    document.checkForChangesNow()
                } else if case .ready(let library) = model.state {
                    // Pick up notes changed on other devices while away.
                    Task { await library.reload() }
                }
            }
        #endif
    }

    #if os(iOS)
    /// On the Mac: a sensible smallest window, and no title text over the app's own toolbar.
    private func configureMacWindow() {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 640)
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        switch model.state {
        case .needsFolder:
            FolderSetupView(model: model)
        case .loading:
            ProgressView("Opening your notes…")
        case .ready(let library):
            LibraryView(library: library, model: model)
                .fullScreenCover(item: $model.openDocument) { document in
                    NoteEditorScreen(document: document, model: model)
                }
        case .failed(let message):
            FolderSetupView(model: model, errorMessage: message)
        }
    }
    #endif
}
