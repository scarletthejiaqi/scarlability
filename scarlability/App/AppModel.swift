import Foundation
import Observation
import ScarlabilityKit

/// App-wide state: where notes are stored and which note is open.
@Observable
final class AppModel {
    enum State {
        case needsFolder
        case loading
        case ready(NoteDocument)
        case failed(String)
    }

    private(set) var state: State = .needsFolder
    let penSettings = PenSettings()
    var folderName: String? { folderAccess?.url.lastPathComponent }

    private var folderAccess: FolderAccess?

    init() {
        if let access = FolderAccess.restore() {
            open(access)
        }
    }

    /// Called with the folder the user picked in the folder picker.
    func chooseFolder(_ url: URL) {
        do {
            open(try FolderAccess.grant(url))
        } catch {
            state = .failed("Couldn't use that folder: \(error.localizedDescription)")
        }
    }

    func forgetFolder() {
        if case .ready(let document) = state {
            document.saveNow()
        }
        folderAccess?.stop()
        folderAccess = nil
        FolderAccess.forget()
        state = .needsFolder
    }

    private func open(_ access: FolderAccess) {
        folderAccess?.stop()
        folderAccess = access
        state = .loading
        let folder = NotebookFolder(root: access.url, deviceID: DeviceIdentity.id)
        Task {
            do {
                let document = try await NoteDocument.openTestNote(in: folder)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-SeedDemoInk") {
                    document.seedDemoInkIfEmpty()
                }
                #endif
                state = .ready(document)
            } catch {
                state = .failed("Couldn't open your notes: \(error.localizedDescription)")
            }
        }
    }
}

enum DeviceIdentity {
    private static let key = "deviceID"

    /// A random ID for this install. Each device's ink files are named after it, so devices
    /// never write to the same file.
    static var id: UUID {
        if let stored = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            return stored
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
