import CoreGraphics
import Foundation

/// A note's details, stored as `Note.json` inside the note's `.scarnote` package.
public struct NoteRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// Paper and size for pages added to this note.
    public var defaultPaper: PaperStyle
    public var defaultPageSize: CGSize
    /// When the note was moved to Recently Deleted.
    public var deletedAt: Date?
    /// The subject folder it was deleted from (relative to the notes folder; nil for Unfiled),
    /// so Restore can put it back.
    public var deletedFrom: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        defaultPaper: PaperStyle = .whiteLined,
        defaultPageSize: CGSize = PageSize.a4
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.defaultPaper = defaultPaper
        self.defaultPageSize = defaultPageSize
    }
}

/// One page of a note, stored as `Pages/<pageID>/Page.json` inside the note's package.
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
