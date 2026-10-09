import CoreGraphics
import Foundation

/// Draw a shape and hold the pen still: if it's close to a line, ellipse/circle, rectangle,
/// triangle or other polygon, it's replaced with a clean one.
public enum ShapeRecognizer {
    public enum Shape: Equatable, Sendable {
        case line(CGPoint, CGPoint)
        /// `angle` is the rotation of the first radius, in radians.
        case ellipse(center: CGPoint, radii: CGSize, angle: CGFloat)
        /// Corners in drawing order; the outline is closed.
        case polygon([CGPoint])
    }

    /// - Parameter linesOnly: Only straight lines (the highlighter snaps to lines).
    public static func recognize(_ points: [CGPoint], linesOnly: Bool = false) -> Shape? {
        guard points.count >= 5, let first = points.first, let last = points.last else { return nil }
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        guard length > 12 else { return nil }

        // A line: every point stays close to the line from start to end.
        let chord = first.distance(to: last)
        if chord > 10, length < chord * 1.2 {
            let deviation = points.map { StrokeHitTesting.distance(from: $0, toSegment: first, last) }.max() ?? 0
            if deviation < max(2, chord * 0.06) {
                return .line(first, last)
            }
        }
        guard !linesOnly else { return nil }

        // Everything else is a closed shape: the end comes back near the start.
        let bounds = boundingBox(points)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 12, chord < diagonal * 0.3, length > diagonal * 1.8 else { return nil }

        let ellipse = fitEllipse(points)
        let polygon = fitPolygon(points, diagonal: diagonal)
        let meanRadius = (ellipse.radii.width + ellipse.radii.height) / 2

        if let polygon, polygon.error / meanRadius < ellipse.error {
            return .polygon(cleanUp(polygon.corners))
        }
        if ellipse.error < 0.12 {
            var radii = ellipse.radii, angle = ellipse.angle
            if abs(radii.width - radii.height) / max(radii.width, radii.height) < 0.12 {
                let r = meanRadius
                radii = CGSize(width: r, height: r)
                angle = 0
            } else {
                angle = snappedAngle(angle)
            }
            return .ellipse(center: ellipse.center, radii: radii, angle: angle)
        }
        return nil
    }

    /// Points along the shape (about one per point of length), all with the same width.
    public static func points(for shape: Shape, width: Float) -> [InkPoint] {
        func along(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            let steps = max(1, Int(a.distance(to: b).rounded(.up)))
            return (0..<steps).map { i in
                let t = CGFloat(i) / CGFloat(steps)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        let locations: [CGPoint]
        switch shape {
        case .line(let a, let b):
            locations = along(a, b) + [b]
        case .ellipse(let center, let radii, let angle):
            let count = max(48, Int(2 * .pi * max(radii.width, radii.height)))
            locations = (0...count).map { i in
                let t = CGFloat(i) / CGFloat(count) * 2 * .pi
                let x = radii.width * cos(t), y = radii.height * sin(t)
                return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
            }
        case .polygon(let corners):
            locations = zip(corners, corners.dropFirst() + corners.prefix(1)).flatMap { along($0, $1) } + corners.prefix(1)
        }
        return locations.map { InkPoint(x: Float($0.x), y: Float($0.y), width: width) }
    }

    // MARK: - Fitting

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Fits an ellipse along the points' main axes. `error` is the average distance from the
    /// ellipse relative to its size.
    private static func fitEllipse(_ points: [CGPoint]) -> (center: CGPoint, radii: CGSize, angle: CGFloat, error: CGFloat) {
        let n = CGFloat(points.count)
        let center = CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - center.x, dy = p.y - center.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        var su: CGFloat = 0, sv: CGFloat = 0
        let projected = points.map { p -> (CGFloat, CGFloat) in
            let dx = p.x - center.x, dy = p.y - center.y
            return (dx * cos(angle) + dy * sin(angle), -dx * sin(angle) + dy * cos(angle))
        }
        for (u, v) in projected {
            su += u * u
            sv += v * v
        }
        // For points spread evenly around an ellipse, the mean of cos² is 1/2.
        let a = max((2 * su / n).squareRoot(), 0.1), b = max((2 * sv / n).squareRoot(), 0.1)
        let error = projected.map { u, v in abs(((u / a) * (u / a) + (v / b) * (v / b)).squareRoot() - 1) }.reduce(0, +) / n
        return (center, CGSize(width: a, height: b), angle, error)
    }

    /// Simplifies the outline to its corners. `error` is the average distance of the points from
    /// the polygon, in points. Nil unless it has 3 to 8 corners.
    private static func fitPolygon(_ points: [CGPoint], diagonal: CGFloat) -> (corners: [CGPoint], error: CGFloat)? {
        // Start from the point farthest from the first one, so the start isn't treated as a corner
        // just because the outline begins there.
        let start = points.indices.max { points[$0].distance(to: points[0]) < points[$1].distance(to: points[0]) } ?? 0
        let rotated = Array(points[start...] + points[..<start]) + [points[start]]
        var corners = simplify(rotated, tolerance: diagonal * 0.06)
        corners.removeLast()
        // Drop corners that are barely corners (nearly straight through) or too close together.
        var changed = true
        while changed, corners.count > 3 {
            changed = false
            for i in corners.indices {
                let previous = corners[(i + corners.count - 1) % corners.count], next = corners[(i + 1) % corners.count]
                let turn = angleBetween(previous, corners[i], next)
                if turn > 155 * .pi / 180 || corners[i].distance(to: previous) < diagonal * 0.12 {
                    corners.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        guard (3...8).contains(corners.count) else { return nil }
        let edges = zip(corners, corners.dropFirst() + corners.prefix(1))
        let error = points.map { p in edges.map { StrokeHitTesting.distance(from: p, toSegment: $0.0, $0.1) }.min()! }
            .reduce(0, +) / CGFloat(points.count)
        guard error < diagonal * 0.04 else { return nil }
        return (corners, error)
    }

    /// Ramer–Douglas–Peucker.
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var farthest = 0
        var farthestDistance: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = StrokeHitTesting.distance(from: points[i], toSegment: first, last)
            if d > farthestDistance {
                farthest = i
                farthestDistance = d
            }
        }
        guard farthestDistance > tolerance else { return [first, last] }
        let left = simplify(Array(points[...farthest]), tolerance: tolerance)
        let right = simplify(Array(points[farthest...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    /// The angle at `b` between the directions to `a` and to `c`, from 0 to π.
    private static func angleBetween(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - b.x, y: a.y - b.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let cosine = (v1.x * v2.x + v1.y * v2.y) / max(hypot(v1.x, v1.y) * hypot(v2.x, v2.y), 1e-9)
        return acos(min(max(cosine, -1), 1))
    }

    /// Four roughly square corners become an exact rectangle (aligned to the page if it's close).
    private static func cleanUp(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        let rightAngles = corners.indices.allSatisfy { i in
            let angle = angleBetween(corners[(i + 3) % 4], corners[i], corners[(i + 1) % 4])
            return abs(angle - .pi / 2) < 18 * .pi / 180
        }
        guard rightAngles else { return corners }
        let edge = CGPoint(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y)
        let angle = snappedAngle(atan2(edge.y, edge.x))
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let local = corners.map { p -> CGPoint in
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: dx * cos(angle) + dy * sin(angle), y: -dx * sin(angle) + dy * cos(angle))
        }
        let halfWidth = local.map { abs($0.x) }.reduce(0, +) / 4, halfHeight = local.map { abs($0.y) }.reduce(0, +) / 4
        return local.map { p -> CGPoint in
            let x = p.x < 0 ? -halfWidth : halfWidth, y = p.y < 0 ? -halfHeight : halfHeight
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
    }

    /// Angles within 8° of horizontal or vertical snap to it.
    private static func snappedAngle(_ angle: CGFloat) -> CGFloat {
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return abs(angle - nearest) < 8 * .pi / 180 ? nearest : angle
    }
}
