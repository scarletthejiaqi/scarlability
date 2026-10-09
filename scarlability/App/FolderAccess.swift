import Foundation

/// Access to the notes folder the user picked. Apps can only reach folders outside their own
/// container (like one in iCloud Drive) through a security-scoped bookmark, which is saved so
/// access survives relaunches.
final class FolderAccess {
    let url: URL
    private var isAccessing: Bool

    private static let bookmarkKey = "notesFolderBookmark"

    private init(url: URL, isAccessing: Bool) {
        self.url = url
        self.isAccessing = isAccessing
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
        return FolderAccess(url: url, isAccessing: isAccessing)
    }

    /// Reopens the folder picked on an earlier launch, if there is one.
    static func restore() -> FolderAccess? {
        #if DEBUG
        // For testing without the folder picker (e.g. in the Simulator): use a folder inside the app.
        if ProcessInfo.processInfo.arguments.contains("-UseLocalNotesFolder"),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return FolderAccess(url: documents.appending(path: "Scarlability", directoryHint: .isDirectory), isAccessing: false)
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
        return FolderAccess(url: url, isAccessing: isAccessing)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    func stop() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = .minimalBookmark
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
