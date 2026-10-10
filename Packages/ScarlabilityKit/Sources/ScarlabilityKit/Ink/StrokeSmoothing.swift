import CoreGraphics

/// Smooths a stroke along its length, so slow and fast writing get the same amount of smoothing.
///
/// Each point becomes a Gaussian-weighted average of its neighbors within a few points of arc
/// length. That irons out the tiny wobbles in raw Pencil samples, which otherwise read as a chain
/// of short straight lines, while keeping the shape of the handwriting. Near the ends the window
/// shrinks, so a stroke still starts and ends exactly where the pen touched down and lifted.
public enum StrokeSmoothing {
    /// Position smoothing (Gaussian σ) in *screen* points; divide by the zoom to get page points,
    /// so smoothing feels the same at any zoom.
    public static let screenRadius: CGFloat = 1.6
    /// Widths are smoothed over a longer stretch, so pressure changes look even.
    static let widthRadiusFactor: CGFloat = 2.5
    /// The window reaches this many σ either side.
    static let reach: CGFloat = 2.5

    /// How far behind the end of a stroke a point has to be for its smoothing to be final
    /// (new points at the end no longer reach it).
    public static func settledLength(radius: CGFloat) -> CGFloat {
        reach * radius * widthRadiusFactor
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
        let room = min(arc[i], total - arc[i]) / reach
        let positionSigma = min(radius, room)
        let widthSigma = min(radius * widthRadiusFactor, room)
        guard widthSigma > 1e-3 else { return points[i] }

        let positionReach = reach * positionSigma
        let widthReach = reach * widthSigma
        var x: CGFloat = 0, y: CGFloat = 0, positionWeight: CGFloat = 0
        var width: CGFloat = 0, widthWeight: CGFloat = 0

        func accumulate(_ j: Int) {
            let d = arc[j] - arc[i]
            if positionSigma > 1e-3, abs(d) <= positionReach {
                let w = exp(-d * d / (2 * positionSigma * positionSigma))
                x += w * CGFloat(points[j].x)
                y += w * CGFloat(points[j].y)
                positionWeight += w
            }
            if abs(d) <= widthReach {
                let w = exp(-d * d / (2 * widthSigma * widthSigma))
                width += w * CGFloat(points[j].width)
                widthWeight += w
            }
        }

        var j = i
        while j >= 0, arc[i] - arc[j] <= widthReach {
            accumulate(j)
            j -= 1
        }
        j = i + 1
        while j < n, arc[j] - arc[i] <= widthReach {
            accumulate(j)
            j += 1
        }

        var result = points[i]
        if positionWeight > 0 {
            result.x = Float(x / positionWeight)
            result.y = Float(y / positionWeight)
        }
        result.width = Float(width / widthWeight)
        return result
    }
}
