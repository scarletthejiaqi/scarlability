import CoreGraphics

/// A stroke together with its prebuilt outline, ready to draw from any thread.
public struct RenderedStroke: @unchecked Sendable {
    // CGPath is immutable once built, so sharing it between threads is safe.
    public let stroke: Stroke
    public let path: CGPath
    public let bounds: CGRect

    public init(_ stroke: Stroke) {
        self.stroke = stroke
        self.path = StrokeGeometry.path(for: stroke.points)
        self.bounds = stroke.bounds
    }
}

public enum InkRenderer {
    /// Draws strokes in order, skipping any that fall outside `clip`. The context must use page
    /// coordinates with the origin at the top-left.
    public static func draw(_ strokes: [RenderedStroke], in context: CGContext, clip: CGRect) {
        for rendered in strokes where rendered.bounds.intersects(clip) {
            context.setFillColor(rendered.stroke.color.cgColor)
            context.addPath(rendered.path)
            context.fillPath(using: .winding)
        }
    }
}
