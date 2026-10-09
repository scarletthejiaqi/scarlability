import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(iOS)
        content
            .onChange(of: scenePhase) { _, phase in
                // Write pending changes before the app might be suspended.
                if phase != .active, case .ready(let document) = model.state {
                    document.saveNow()
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
        switch model.state {
        case .needsFolder:
            FolderSetupView()
        case .loading:
            ProgressView("Opening your notes…")
        case .ready(let document):
            NoteEditorScreen(document: document)
        case .failed(let message):
            FolderSetupView(errorMessage: message)
        }
    }
    #endif
}
