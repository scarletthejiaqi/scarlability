import CoreGraphics

/// Which strokes the eraser and the select tool touch.
public enum StrokeHitTesting {
    /// Whether an eraser of `radius` moving from `a` to `b` touches the stroke's ink.
    public static func eraser(from a: CGPoint, to b: CGPoint, radius: CGFloat, touches stroke: Stroke) -> Bool {
        guard eraserBounds(from: a, to: b, radius: radius).intersects(stroke.bounds) else { return false }
        let points = StrokeGeometry.interpolate(stroke.points)
        return points.contains { distance(from: $0.location, toSegment: a, b) <= radius + $0.radius }
    }

    /// What's left of a stroke after an eraser of `radius` moves from `a` to `b`: nil if the
    /// eraser missed it, otherwise the remaining pieces (empty if it's all gone).
    public static func erase(_ stroke: Stroke, from a: CGPoint, to b: CGPoint, radius: CGFloat) -> [[InkPoint]]? {
        guard eraserBounds(from: a, to: b, radius: radius).intersects(stroke.bounds) else { return nil }
        // Dense points, so the cut lands close to the eraser's edge.
        let points = StrokeGeometry.interpolate(stroke.points)
        // A point goes if the eraser covers any of its ink, so no sliver is left inside the eraser.
        let erased = points.map { distance(from: $0.location, toSegment: a, b) <= radius + $0.radius }
        guard erased.contains(true) else { return nil }

        var pieces: [[InkPoint]] = []
        var current: [InkPoint] = []
        for (point, gone) in zip(points, erased) {
            if gone {
                if !current.isEmpty { pieces.append(current) }
                current = []
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        // A single leftover point would show as a stray dot.
        return pieces.filter { $0.count > 1 }
    }

    /// Whether a lasso (a closed outline) selects the stroke: at least half its points are inside.
    public static func lasso(_ outline: [CGPoint], selects stroke: Stroke) -> Bool {
        guard outline.count >= 3, !stroke.points.isEmpty else { return false }
        let inside = stroke.points.filter { contains(outline, $0.location) }.count
        return inside * 2 >= stroke.points.count
    }

    /// Even-odd point-in-polygon test.
    public static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func eraserBounds(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius, dy: -radius)
    }
}
