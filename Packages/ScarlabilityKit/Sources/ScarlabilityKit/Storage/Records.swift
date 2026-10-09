import CoreGraphics
import Foundation

/// A note's library entry, stored at `library/notes/<id>.json`.
public struct NoteRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// nil means Unfiled.
    public var subjectID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date
    /// Set when the note is moved to Recently Deleted.
    public var deletedAt: Date?
    /// Paper and size for pages added to this note.
    public var defaultPaper: PaperStyle
    public var defaultPageSize: CGSize

    public init(
        id: UUID = UUID(),
        title: String,
        subjectID: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        deletedAt: Date? = nil,
        defaultPaper: PaperStyle = .whiteLined,
        defaultPageSize: CGSize = PageSize.a4
    ) {
        self.id = id
        self.title = title
        self.subjectID = subjectID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
        self.defaultPaper = defaultPaper
        self.defaultPageSize = defaultPageSize
    }
}

/// One page of a note, stored at `notes/<noteID>/pages/<pageID>/page.json`.
public struct PageRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Pages are shown in increasing order. Each page keeps its own key, so two devices adding
    /// pages at the same time never overwrite each other's page list.
    public var sortKey: Double
    public var size: CGSize
    public var paper: PaperStyle
    public var createdAt: Date

    public init(id: UUID = UUID(), sortKey: Double, size: CGSize, paper: PaperStyle, createdAt: Date = Date()) {
        self.id = id
        self.sortKey = sortKey
        self.size = size
        self.paper = paper
        self.createdAt = createdAt
    }
}
