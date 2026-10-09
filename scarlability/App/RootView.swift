import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(iOS)
        content
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    // Write pending changes before the app might be suspended.
                    model.openDocument?.saveNow()
                } else if case .ready(let library) = model.state, model.openDocument == nil {
                    // Pick up notes changed on other devices while away.
                    Task { await library.reload() }
                }
            }
        #else
        ContentUnavailableView(
            "Scarlability for Mac is coming",
            systemImage: "macbook",
            description: Text("The Mac version arrives in milestone 6. For now, write on your iPad.")
        )
        .frame(minWidth: 480, minHeight: 320)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var content: some View {
        @Bindable var model = model
        switch model.state {
        case .needsFolder:
            FolderSetupView()
        case .loading:
            ProgressView("Opening your notes…")
        case .ready(let library):
            LibraryView(library: library)
                .fullScreenCover(item: $model.openDocument) { document in
                    NoteEditorScreen(document: document)
                }
        case .failed(let message):
            FolderSetupView(errorMessage: message)
        }
    }
    #endif
}
