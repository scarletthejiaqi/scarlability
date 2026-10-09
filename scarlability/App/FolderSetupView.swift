import SwiftUI
import UniformTypeIdentifiers

/// First-run screen: pick the folder (normally in iCloud Drive) where notes are stored.
struct FolderSetupView: View {
    @Environment(AppModel.self) private var model
    var errorMessage: String?
    @State private var isPicking = false
    @State private var pickerError: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Where should your notes live?")
                .font(.title2.bold())
            Text("Choose iCloud Drive (or any folder in it). The app keeps your notes in a folder named “Scarlability” there, one item per note, and iCloud Drive keeps them in sync with your Mac. Choose the same place on every device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if let message = pickerError ?? errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("Choose Folder…") { isPicking = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                pickerError = nil
                model.chooseFolder(url)
            case .failure(let error):
                pickerError = error.localizedDescription
            }
        }
    }
}
