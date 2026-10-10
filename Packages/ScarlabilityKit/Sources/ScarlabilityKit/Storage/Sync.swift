import Foundation

/// What two-device sync needs from the notes folder, on top of each device writing only its own
/// ink and item files (see `InkMerge`, `ItemMerge`):
///
/// - Cheap "stamps" of a note or the whole library, ignoring this device's own files, so the app
///   can check every few seconds whether another device changed something and only then reload.
/// - iCloud Drive placeholders: an item not downloaded yet shows up as a hidden
///   `.<name>.icloud` file; the app asks iCloud to download it and shows it once it's there.
/// - Finding a note again after another device renamed or moved it.
/// - Conflict copies iCloud keeps when two devices change a shared file (Note.json, Page.json)
///   at once: the newest wins, and a deleted page stays deleted.
extension NotebookFolder {
    static let placeholderSuffix = ".icloud"

    // MARK: - Stamps

    /// Changes whenever another device's files in the note change, or pages are added or
    /// removed. This device's own ink and item files are left out, so saving doesn't change it.
    public func changeStamp(inNoteAt noteURL: URL) -> String {
        var parts: [String] = [stamp(of: noteURL.appending(path: "Note.json"))]
        for page in listing(of: pagesDirectory(noteURL)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            parts.append(page.lastPathComponent)
            for file in listing(of: page).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where !file.lastPathComponent.hasPrefix(deviceID.uuidString) {
                parts.append(file.lastPathComponent + "@" + stamp(of: file))
            }
        }
        return parts.joined(separator: "|")
    }

    /// Changes whenever a folder or note is added, removed, renamed or changed anywhere in the
    /// library (each note's Note.json changes when it's edited).
    public func libraryStamp() -> String {
        var parts: [String] = []
        func walk(_ directory: URL, depth: Int) {
            for item in listing(of: directory).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if item.pathExtension == Self.noteExtension {
                    parts.append(item.path(percentEncoded: false) + "@" + stamp(of: item.appending(path: "Note.json")))
                } else if name.hasSuffix(Self.placeholderSuffix) || name.hasPrefix(".") {
                    parts.append(item.path(percentEncoded: false) + "@" + stamp(of: item))
                } else if depth < 3, isDirectory(item) {
                    parts.append(item.path(percentEncoded: false))
                    walk(item, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return parts.joined(separator: "|")
    }

    /// Everything in a folder, including hidden files (iCloud placeholders and markers).
    private func listing(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]))
            ?? []
    }

    private func stamp(of url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return "-" }
        return "\(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0):\(values.fileSize ?? 0)"
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Not downloaded yet

    /// Asks iCloud to download the items in a folder that are only placeholders so far, and
    /// returns how many notes (`.scarnote` packages) are among them.
    @discardableResult
    public func requestDownloads(in directory: URL) -> Int {
        var notes = 0
        for item in listing(of: directory) {
            let name = item.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(Self.placeholderSuffix) else { continue }
            let realName = String(name.dropFirst().dropLast(Self.placeholderSuffix.count))
            let real = directory.appending(path: realName)
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            if real.pathExtension == Self.noteExtension {
                notes += 1
            }
        }
        return notes
    }

    // MARK: - Finding a moved note

    /// Where the note with this ID is now (another device may have renamed it or moved it to
    /// another folder or to Recently Deleted).
    public func findNote(id: UUID) -> URL? {
        func search(_ directory: URL, depth: Int) -> URL? {
            for item in listing(of: directory) where !item.lastPathComponent.hasPrefix(".") {
                if item.pathExtension == Self.noteExtension {
                    if (try? decodeJSON(NoteRecord.self, from: item.appending(path: "Note.json")))?.id == id { return item }
                } else if depth < 3, isDirectory(item), let found = search(item, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }
        return search(root, depth: 0)
    }

    // MARK: - Conflicts

    /// If iCloud kept conflicting versions of a note's Note.json (both devices saved it at
    /// once), keeps the one changed most recently and drops the rest.
    func resolveNoteConflicts(at url: URL) {
        resolveConflicts(at: url) { versions in
            versions.max { a, b in
                let first = (try? Self.decoder.decode(NoteRecord.self, from: Data(contentsOf: a)))?.modifiedAt ?? .distantPast
                let second = (try? Self.decoder.decode(NoteRecord.self, from: Data(contentsOf: b)))?.modifiedAt ?? .distantPast
                return first < second
            }
        }
    }

    /// The same for a Page.json: a version where the page was deleted wins (so a deleted page
    /// doesn't come back), otherwise the current one stays.
    func resolvePageConflicts(at url: URL) {
        resolveConflicts(at: url) { versions in
            versions.first { (try? Self.decoder.decode(PageRecord.self, from: Data(contentsOf: $0)))?.deletedAt != nil }
        }
    }

    /// - Parameter pick: Given the current file followed by the conflicting versions' files,
    ///   returns the one to keep (nil keeps the current one).
    private func resolveConflicts(at url: URL, pick: ([URL]) -> URL?) {
        guard (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey]))?.ubiquitousItemHasUnresolvedConflicts == true,
              let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        let chosen = pick([url] + conflicts.map(\.url))
        if let chosen, chosen != url, let version = conflicts.first(where: { $0.url == chosen }) {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
                _ = try? version.replaceItem(at: url, options: [])
            }
        }
        for version in conflicts {
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}
