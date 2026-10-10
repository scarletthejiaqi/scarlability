import Foundation

/// Access to the place the user picked for their notes. Apps can only reach folders outside their
/// own container (like iCloud Drive) through a security-scoped bookmark, which is saved so access
/// survives relaunches.
///
/// Notes always live in a folder named "Scarlability": the one the user picked if it has that
/// name, otherwise one created inside it. That keeps notes out of the rest of iCloud Drive.
final class FolderAccess {
    /// The folder the user picked.
    let pickedURL: URL
    /// The Scarlability folder the notes live in.
    let notesURL: URL
    private var isAccessing: Bool

    static let notesFolderName = "Scarlability"
    private static let bookmarkKey = "notesFolderBookmark"

    private init(pickedURL: URL, isAccessing: Bool) {
        self.pickedURL = pickedURL
        self.isAccessing = isAccessing
        notesURL = pickedURL.lastPathComponent == Self.notesFolderName
            ? pickedURL
            : pickedURL.appending(path: Self.notesFolderName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
    }

    /// Where the notes are, as the user would say it, e.g. "iCloud Drive › Scarlability".
    var displayName: String {
        guard notesURL != pickedURL else { return Self.notesFolderName }
        let picked = (try? pickedURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? pickedURL.lastPathComponent
        return "\(picked) › \(Self.notesFolderName)"
    }

    /// Saves access to a folder the user just picked.
    static func grant(_ url: URL) throws -> FolderAccess {
        let isAccessing = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        return FolderAccess(pickedURL: url, isAccessing: isAccessing)
    }

    /// Reopens the folder picked on an earlier launch, if there is one.
    static func restore() -> FolderAccess? {
        #if DEBUG
        // For testing without the folder picker (e.g. in the Simulator): use a folder inside the app.
        if ProcessInfo.processInfo.arguments.contains("-UseLocalNotesFolder"),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return FolderAccess(pickedURL: documents, isAccessing: false)
        }
        #endif
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        if isStale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return FolderAccess(pickedURL: url, isAccessing: isAccessing)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    func stop() {
        guard isAccessing else { return }
        pickedURL.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    // The Mac app is sandboxed: access to a picked folder only lasts across launches through a
    // security-scoped bookmark.
    #if targetEnvironment(macCatalyst)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = .minimalBookmark
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
