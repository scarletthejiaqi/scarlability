import CoreGraphics

/// Builds the filled outline of a variable-width stroke.
///
/// The stroke is drawn as the union of "capsules": for each pair of neighboring points, the shape
/// that wraps a circle at each point (sized by that point's width). Every capsule winds the same
/// way, so filling them all with the nonzero rule paints each pixel once. That keeps sharp turns
/// and loops solid, where a single left/right outline would fold over itself.
public enum StrokeGeometry {
    /// Maximum distance between interpolated points, in page points.
    static let maxSegmentLength: CGFloat = 1
    static let maxSubdivisions = 32

    public static func path(for points: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        let dense = interpolate(points)
        guard let first = dense.first else { return path }
        guard dense.count > 1 else {
            appendCircle(to: path, center: first.location, radius: first.radius)
            return path
        }
        for index in 1..<dense.count {
            appendCapsule(
                to: path,
                from: dense[index - 1],
                to: dense[index],
                includeStartCap: index == 1
            )
        }
        return path
    }

    /// The highlighter's nib: thinner than it is tall, like a chisel-tip marker held to highlight a
    /// line of text. Moving sideways leaves a band as tall as the stroke width.
    static let chiselAspect: CGFloat = 0.3

    /// Highlighter outline: the area a flat chisel nib sweeps along the points. Built as a union of
    /// convex hulls of the nib at neighboring points, all wound the same way, like `path(for:)`.
    public static func chiselPath(for points: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        let dense = interpolate(points)
        func nib(_ point: InkPoint) -> [CGPoint] {
            let halfHeight = CGFloat(point.width) / 2, halfWidth = halfHeight * chiselAspect
            let x = CGFloat(point.x), y = CGFloat(point.y)
            return [CGPoint(x: x - halfWidth, y: y - halfHeight), CGPoint(x: x + halfWidth, y: y - halfHeight),
                    CGPoint(x: x + halfWidth, y: y + halfHeight), CGPoint(x: x - halfWidth, y: y + halfHeight)]
        }
        func addPolygon(_ corners: [CGPoint]) {
            guard let first = corners.first else { return }
            path.move(to: first)
            corners.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
        }
        guard let first = dense.first else { return path }
        guard dense.count > 1 else {
            addPolygon(convexHull(nib(first)))
            return path
        }
        for index in 1..<dense.count {
            addPolygon(convexHull(nib(dense[index - 1]) + nib(dense[index])))
        }
        return path
    }

    /// Andrew's monotone chain; the result always winds the same way.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Fills in points along a centripetal Catmull-Rom spline so fast strokes curve smoothly
    /// instead of showing straight segments. Widths are interpolated linearly.
    public static func interpolate(_ points: [InkPoint]) -> [InkPoint] {
        guard points.count > 2 else { return points }
        var result: [InkPoint] = [points[0]]
        result.reserveCapacity(points.count * 2)
        for i in 0..<(points.count - 1) {
            let p1 = points[i], p2 = points[i + 1]
            let segmentLength = p1.location.distance(to: p2.location)
            let steps = min(Self.maxSubdivisions, Int((segmentLength / Self.maxSegmentLength).rounded(.up)))
            if steps > 1 {
                // Extend the ends by reflection so the first and last segments curve too.
                let p0 = i > 0 ? points[i - 1].location : reflect(p2.location, across: p1.location)
                let p3 = i + 2 < points.count ? points[i + 2].location : reflect(p1.location, across: p2.location)
                for step in 1..<steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let location = catmullRom(p0, p1.location, p2.location, p3, t: t)
                    let width = p1.width + (p2.width - p1.width) * Float(t)
                    result.append(InkPoint(x: Float(location.x), y: Float(location.y), width: width))
                }
            }
            result.append(p2)
        }
        return result
    }

    // MARK: - Spline

    private static func reflect(_ point: CGPoint, across center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Barry–Goldman evaluation of a centripetal Catmull-Rom segment between p1 and p2.
    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(a.distance(to: b).squareRoot(), 1e-4) }
        let t0: CGFloat = 0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        let u = t1 + (t2 - t1) * t

        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
            let w = (u - ta) / (tb - ta)
            return CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        let a1 = lerp(p0, p1, t0, t1)
        let a2 = lerp(p1, p2, t1, t2)
        let a3 = lerp(p2, p3, t2, t3)
        let b1 = lerp(a1, a2, t0, t2)
        let b2 = lerp(a2, a3, t1, t3)
        return lerp(b1, b2, t1, t2)
    }

    // MARK: - Shapes

    /// Appends the convex hull of the circles at `a` and `b`, wound clockwise (decreasing angle).
    ///
    /// Consecutive capsules share a full circle at their common point, so only the first capsule
    /// needs its rounded back end; the rest close with a straight edge that the previous capsule
    /// already covers. That roughly halves the curve count.
    private static func appendCapsule(to path: CGMutablePath, from a: InkPoint, to b: InkPoint, includeStartCap: Bool) {
        let ca = a.location, cb = b.location
        let ra = a.radius, rb = b.radius
        let d = ca.distance(to: cb)
        guard d > abs(ra - rb), d > 1e-6 else {
            // One circle contains the other.
            if ra >= rb {
                if includeStartCap { appendCircle(to: path, center: ca, radius: ra) }
            } else {
                appendCircle(to: path, center: cb, radius: rb)
            }
            return
        }
        let theta = atan2(cb.y - ca.y, cb.x - ca.x)
        let phi = acos((ra - rb) / d)

        path.move(to: point(on: ca, radius: ra, angle: theta + phi))
        path.addLine(to: point(on: cb, radius: rb, angle: theta + phi))
        appendArc(to: path, center: cb, radius: rb, from: theta + phi, sweep: -2 * phi)
        path.addLine(to: point(on: ca, radius: ra, angle: theta - phi))
        if includeStartCap {
            appendArc(to: path, center: ca, radius: ra, from: theta - phi, sweep: -(2 * .pi - 2 * phi))
        }
        path.closeSubpath()
    }

    private static func appendCircle(to path: CGMutablePath, center: CGPoint, radius: CGFloat) {
        path.move(to: point(on: center, radius: radius, angle: 0))
        appendArc(to: path, center: center, radius: radius, from: 0, sweep: -2 * .pi)
        path.closeSubpath()
    }

    /// Appends an arc as cubic Béziers (at most 90° each), starting from the current point.
    /// Written out by hand so the winding direction is explicit and the same on every platform.
    private static func appendArc(to path: CGMutablePath, center: CGPoint, radius: CGFloat, from start: CGFloat, sweep: CGFloat) {
        let segments = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let delta = sweep / CGFloat(segments)
        let k = 4 / 3 * tan(delta / 4) * radius
        var angle = start
        for _ in 0..<segments {
            let next = angle + delta
            let p0 = point(on: center, radius: radius, angle: angle)
            let p3 = point(on: center, radius: radius, angle: next)
            let c1 = CGPoint(x: p0.x - k * sin(angle), y: p0.y + k * cos(angle))
            let c2 = CGPoint(x: p3.x + k * sin(next), y: p3.y - k * cos(next))
            path.addCurve(to: p3, control1: c1, control2: c2)
            angle = next
        }
    }

    private static func point(on center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}
