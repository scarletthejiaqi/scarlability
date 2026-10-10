import CoreGraphics

/// Smooths a stroke's path along its length, so slow and fast writing get the same amount of
/// smoothing.
///
/// Each point becomes a Gaussian-weighted average of its neighbors within a few points of arc
/// length. That irons out the tiny wobbles in raw Pencil samples while keeping the shape of the
/// handwriting. Near the ends the window shrinks, so a stroke still starts and ends exactly where
/// the pen touched down and lifted. Widths are left alone: `StrokeBuilder` evens them out as
/// samples arrive, so the thickness behind the pen never changes after it's drawn.
public enum StrokeSmoothing {
    /// Default position smoothing (Gaussian σ) in *screen* points; divide by the zoom to get page
    /// points, so smoothing feels the same at any zoom. Kept light: the window near the pen tip
    /// is still filling up, and the more smoothing, the more the line there shifts as you write.
    public static let screenRadius: CGFloat = 0.8
    /// The window reaches this many σ either side.
    static let reach: CGFloat = 2.5

    /// How far behind the end of a stroke a point has to be for its smoothing to be final
    /// (new points at the end no longer reach it).
    public static func settledLength(radius: CGFloat) -> CGFloat {
        reach * radius
    }

    /// - Parameter radius: Position smoothing σ in page points.
    public static func smooth(_ points: [InkPoint], radius: CGFloat) -> [InkPoint] {
        let n = points.count
        guard n > 2, radius > 0 else { return points }
        let arc = arcLengths(points)
        return (0..<n).map { smoothedPoint(at: $0, in: points, arc: arc, radius: radius) }
    }

    /// Cumulative length along the points.
    static func arcLengths(_ points: [InkPoint]) -> [CGFloat] {
        var arc = [CGFloat](repeating: 0, count: points.count)
        for i in points.indices.dropFirst() {
            arc[i] = arc[i - 1] + points[i - 1].location.distance(to: points[i].location)
        }
        return arc
    }

    /// One smoothed point. `arc` holds the cumulative lengths of `points`.
    static func smoothedPoint(at i: Int, in points: [InkPoint], arc: [CGFloat], radius: CGFloat) -> InkPoint {
        let n = points.count
        guard n > 2, radius > 0 else { return points[i] }
        let total = arc[n - 1]
        // A symmetric window that never runs past either end keeps the ends in place.
        let sigma = min(radius, min(arc[i], total - arc[i]) / reach)
        guard sigma > 1e-3 else { return points[i] }

        let windowReach = reach * sigma
        var x: CGFloat = 0, y: CGFloat = 0, weight: CGFloat = 0
        func accumulate(_ j: Int) {
            let d = arc[j] - arc[i]
            let w = exp(-d * d / (2 * sigma * sigma))
            x += w * CGFloat(points[j].x)
            y += w * CGFloat(points[j].y)
            weight += w
        }

        var j = i
        while j >= 0, arc[i] - arc[j] <= windowReach {
            accumulate(j)
            j -= 1
        }
        j = i + 1
        while j < n, arc[j] - arc[i] <= windowReach {
            accumulate(j)
            j += 1
        }

        var result = points[i]
        result.x = Float(x / weight)
        result.y = Float(y / weight)
        return result
    }
}
