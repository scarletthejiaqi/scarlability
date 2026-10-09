import CoreGraphics
import Foundation

/// A text box or image on a page. Unlike strokes, items are edited in place: each edit saves a
/// new version with a later `modifiedAt`, and across devices the newest version wins.
public struct PageItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case text(TextContent)
        case image(ImageContent)
    }

    public var id: UUID
    public var kind: Kind
    /// Position and size in page coordinates, before `rotation` (which turns it about its center).
    public var frame: CGRect
    /// Radians.
    public var rotation: Double
    /// Orders items: later ones draw on top.
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), kind: Kind, frame: CGRect, rotation: Double = 0, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var text: TextContent? {
        if case .text(let content) = kind { return content }
        return nil
    }

    public var image: ImageContent? {
        if case .image(let content) = kind { return content }
        return nil
    }

    /// Turns points of the unrotated frame to where they are on the page.
    public var rotationTransform: CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY).rotated(by: rotation).translatedBy(x: -frame.midX, y: -frame.midY)
    }

    /// The area the item covers on the page, including rotation.
    public var bounds: CGRect {
        rotation == 0 ? frame : frame.applying(rotationTransform)
    }

    /// Whether a page point is on the item.
    public func contains(_ point: CGPoint) -> Bool {
        frame.contains(point.applying(rotationTransform.inverted()))
    }
}

/// The fonts offered for typed text.
public enum TextFont: String, Codable, CaseIterable, Sendable {
    case system
    case serif
    case rounded
    case monospaced
    case handwritten
    case marker

    public var displayName: String {
        switch self {
        case .system: "System"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .monospaced: "Monospaced"
        case .handwritten: "Handwritten"
        case .marker: "Marker"
        }
    }
}

/// A stretch of text with one style.
public struct TextRun: Codable, Hashable, Sendable {
    public var text: String
    public var font: TextFont
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var color: InkColor

    public init(text: String, font: TextFont = .system, size: Double = 17, bold: Bool = false, italic: Bool = false,
                underline: Bool = false, color: InkColor = .black) {
        self.text = text
        self.font = font
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.color = color
    }
}

public struct TextContent: Codable, Hashable, Sendable {
    public var runs: [TextRun]
    /// Set by dragging the box's width handle; nil means the box grows with the text.
    public var fixedWidth: Double?

    public init(runs: [TextRun], fixedWidth: Double? = nil) {
        self.runs = runs
        self.fixedWidth = fixedWidth
    }

    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct ImageContent: Codable, Hashable, Sendable {
    /// The file in the note package's Images folder.
    public var fileName: String
    /// The visible part after cropping, as fractions of the whole image (0–1).
    public var crop: CGRect

    public init(fileName: String, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.fileName = fileName
        self.crop = crop
    }
}

/// Everything one device has written about a page's items: its latest versions of the items it
/// changed, and when it deleted any. Like `DeviceInk`, each device only writes its own file.
public struct DeviceItems: Codable, Equatable, Sendable {
    public var items: [PageItem]
    /// Item ID → when it was deleted.
    public var deleted: [UUID: Date]

    public init(items: [PageItem] = [], deleted: [UUID: Date] = [:]) {
        self.items = items
        self.deleted = deleted
    }
}

/// A page background that fills the page under everything, such as a scanned document.
public enum PageBackground: Codable, Hashable, Sendable {
    /// An image in the note package's Images folder, fitted to the page.
    case image(fileName: String)
}

public enum ItemMerge {
    /// What a page shows: for each item, the newest version from any device, unless a device
    /// deleted it after that version; oldest first, so newer items draw on top.
    public static func visibleItems(from all: some Sequence<DeviceItems>) -> [PageItem] {
        var newest: [UUID: PageItem] = [:]
        var deletedAt: [UUID: Date] = [:]
        for device in all {
            for item in device.items where (newest[item.id]?.modifiedAt ?? .distantPast) < item.modifiedAt {
                newest[item.id] = item
            }
            for (id, date) in device.deleted where (deletedAt[id] ?? .distantPast) < date {
                deletedAt[id] = date
            }
        }
        return newest.values
            .filter { item in deletedAt[item.id].map { $0 < item.modifiedAt } ?? true }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }
}
