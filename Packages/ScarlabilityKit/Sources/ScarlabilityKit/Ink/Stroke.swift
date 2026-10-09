import CoreGraphics
import Foundation

/// One point of a finished stroke, in page coordinates (points, origin at the page's top-left).
public struct InkPoint: Hashable, Sendable {
    public var x: Float
    public var y: Float
    /// Diameter of the ink at this point, after pressure has been applied.
    public var width: Float

    public init(x: Float, y: Float, width: Float) {
        self.x = x
        self.y = y
        self.width = width
    }

    public init(_ location: CGPoint, width: Double) {
        self.init(x: Float(location.x), y: Float(location.y), width: Float(width))
    }

    public var location: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
    public var radius: CGFloat { CGFloat(width) / 2 }
}

public enum InkTool: UInt8, Sendable, Codable {
    case pen = 0
}

/// A finished stroke. Strokes never change after they're created; editing one replaces it,
/// which is what lets two devices' edits merge cleanly.
public struct Stroke: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var tool: InkTool
    public var color: InkColor
    public var points: [InkPoint]
    /// Orders strokes from different devices: later strokes draw on top.
    public var createdAt: Date

    public init(id: UUID = UUID(), tool: InkTool = .pen, color: InkColor, points: [InkPoint], createdAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.color = color
        self.points = points
        self.createdAt = createdAt
    }

    /// The area the stroke covers, including its width.
    public var bounds: CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x - first.width / 2, maxX = first.x + first.width / 2
        var minY = first.y - first.width / 2, maxY = first.y + first.width / 2
        for point in points.dropFirst() {
            let r = point.width / 2
            minX = min(minX, point.x - r)
            maxX = max(maxX, point.x + r)
            minY = min(minY, point.y - r)
            maxY = max(maxY, point.y + r)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}
