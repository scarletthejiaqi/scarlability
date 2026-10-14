import CoreGraphics

/// The loop drawn with the Select tool, closed from its last point back to its first.
///
/// Everything the loop goes around counts as inside, however it was drawn: going around twice
/// to be sure, or crossing itself, still selects all of it. (The even-odd rule left out whatever
/// was circled twice, which was usually the middle.)
public struct Lasso: Sendable {
    public let outline: [CGPoint]
    public let bounds: CGRect

    /// How far apart (page points) the parts of a stroke checked against the loop are.
    static let strokeStep: CGFloat = 1

    /// - Parameter spacing: Points closer than this to the previous one are dropped. The Pencil
    ///   reports hundreds of points per second, many more than the loop's shape needs.
    public init(_ outline: [CGPoint], spacing: CGFloat = 0) {
        var kept: [CGPoint] = []
        kept.reserveCapacity(outline.count)
        for point in outline {
            if let last = kept.last, last.distance(to: point) < spacing { continue }
            kept.append(point)
        }
        if let last = outline.last, kept.last != last {
            kept.append(last)
        }
        self.outline = kept
        bounds = kept.isEmpty ? .null : CGRect(
            x: kept.map(\.x).min()!, y: kept.map(\.y).min()!,
            width: kept.map(\.x).max()! - kept.map(\.x).min()!, height: kept.map(\.y).max()! - kept.map(\.y).min()!
        )
    }

    /// The same loop, moved (e.g. into a page's coordinates).
    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Lasso {
        Lasso(outline.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
    }

    /// The closed loop, for drawing.
    public var path: CGPath {
        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        return path
    }

    /// Whether the loop goes around a point (nonzero winding number).
    public func contains(_ point: CGPoint) -> Bool {
        guard outline.count >= 3, bounds.contains(point) else { return false }
        var winding = 0
        var a = outline[outline.count - 1]
        for b in outline {
            // Which side of the edge a→b the point is on.
            let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
            if a.y <= point.y {
                if b.y > point.y, side > 0 { winding += 1 }
            } else if b.y <= point.y, side < 0 {
                winding -= 1
            }
            a = b
        }
        return winding != 0
    }

    /// Which strokes a loop selects.
    public enum Rule: Sendable {
        /// At least half of the stroke's length is inside (Box select).
        case mostlyInside
        /// Any of the stroke is inside, or the loop's line runs over its ink (freeform select).
        case touches
    }

    /// Whether the loop selects a stroke.
    /// - Parameter tolerance: For `.touches`, how close (page points) the line has to come to the ink.
    public func selects(_ stroke: Stroke, rule: Rule = .mostlyInside, tolerance: CGFloat = 0) -> Bool {
        switch rule {
        case .mostlyInside: mostlyContains(stroke)
        case .touches: touches(stroke, tolerance: tolerance)
        }
    }

    private func touches(_ stroke: Stroke, tolerance: CGFloat) -> Bool {
        let points = stroke.points
        guard outline.count >= 3, let first = points.first else { return false }
        let reach = CGFloat(points.map(\.width).max() ?? 0) / 2 + tolerance
        let near = stroke.bounds.insetBy(dx: -tolerance, dy: -tolerance)
        guard bounds.insetBy(dx: -reach, dy: -reach).intersects(near) else { return false }
        // Any of it inside the loop, checked every so often along the stroke.
        if contains(first.location) { return true }
        var sinceChecked: CGFloat = 0
        for (index, point) in points.enumerated().dropFirst() {
            sinceChecked += points[index - 1].location.distance(to: point.location)
            guard sinceChecked >= Self.strokeStep || index == points.count - 1 else { continue }
            if contains(point.location) { return true }
            sinceChecked = 0
        }
        // Or the loop's line running over the ink (only its parts near the stroke), including
        // the closing piece from the end back to the start, which the outline shows too.
        for index in outline.indices {
            let c = outline[index == 0 ? outline.count - 1 : index - 1], d = outline[index]
            let segment = CGRect(x: min(c.x, d.x), y: min(c.y, d.y), width: abs(d.x - c.x), height: abs(d.y - c.y))
            guard segment.insetBy(dx: -reach, dy: -reach).intersects(near) else { continue }
            guard points.count > 1 else {
                if StrokeHitTesting.distance(from: first.location, toSegment: c, d) <= first.radius + tolerance { return true }
                continue
            }
            for j in points.indices.dropFirst() {
                let a = points[j - 1], b = points[j]
                if Self.distance(a.location, b.location, c, d) <= max(a.radius, b.radius) + tolerance { return true }
            }
        }
        return false
    }

    /// The distance between the segments a–b and c–d (0 if they cross).
    static func distance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
        func side(_ o: CGPoint, _ p: CGPoint, _ q: CGPoint) -> CGFloat { (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x) }
        if side(c, d, a) * side(c, d, b) < 0, side(a, b, c) * side(a, b, d) < 0 { return 0 }
        return min(StrokeHitTesting.distance(from: a, toSegment: c, d), StrokeHitTesting.distance(from: b, toSegment: c, d),
                   StrokeHitTesting.distance(from: c, toSegment: a, b), StrokeHitTesting.distance(from: d, toSegment: a, b))
    }

    /// At least half of the stroke's length is inside.
    private func mostlyContains(_ stroke: Stroke) -> Bool {
        guard outline.count >= 3, let first = stroke.points.first, bounds.intersects(stroke.bounds) else { return false }
        var inside: CGFloat = 0, total: CGFloat = 0
        // Walk along the stroke in short pieces and check the middle of each.
        var pieceStart = first.location, previous = first.location, pieceLength: CGFloat = 0
        for (index, point) in stroke.points.enumerated().dropFirst() {
            let location = point.location
            pieceLength += previous.distance(to: location)
            previous = location
            guard pieceLength >= Self.strokeStep || index == stroke.points.count - 1 else { continue }
            let middle = CGPoint(x: (pieceStart.x + location.x) / 2, y: (pieceStart.y + location.y) / 2)
            if contains(middle) { inside += pieceLength }
            total += pieceLength
            pieceStart = location
            pieceLength = 0
        }
        // A dot (or a stroke that never moved).
        guard total > 0.01 else { return contains(first.location) }
        return inside * 2 >= total
    }
}
