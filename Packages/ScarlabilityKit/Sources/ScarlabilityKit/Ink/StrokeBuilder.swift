import CoreGraphics

/// Collects pen samples for the stroke being drawn and turns them into smooth `InkPoint`s.
///
/// While writing and after lifting, points go through the same `StrokeSmoothing`, so the stroke
/// doesn't visibly change when the pen lifts. Smoothing is incremental: points far enough behind
/// the pen are final and kept, so each new sample only recomputes the last few points.
public struct StrokeBuilder: Sendable {
    public let baseWidth: Double
    public let curve: PressureCurve
    /// Position smoothing σ in page points.
    public let smoothing: CGFloat

    /// The samples, with widths from pressure applied.
    private var raw: [InkPoint] = []
    /// Pressure per sample (nil for input without pressure), kept for force updates.
    private var forces: [Double?] = []
    /// Cumulative length along `raw`.
    private var arc: [CGFloat] = []
    private var smoothed: [InkPoint] = []
    /// `smoothed[..<settled]` are final.
    private var settled = 0

    /// Samples closer than this (in page points) to the previous one only update its force.
    static let minimumSpacing: CGFloat = 0.15
    static let minimumWidth = 0.2

    public init(baseWidth: Double, curve: PressureCurve, smoothing: CGFloat) {
        self.baseWidth = baseWidth
        self.curve = curve
        self.smoothing = smoothing
    }

    public var isEmpty: Bool { raw.isEmpty }

    /// Adds a pen sample. Returns the index it was stored at (for later force updates), or nil if it
    /// was too close to the previous sample and only refreshed that sample's force.
    @discardableResult
    public mutating func add(_ location: CGPoint, force: Double?) -> Int? {
        if let last = raw.last, last.location.distance(to: location) < Self.minimumSpacing {
            if let force { updateForce(force, at: raw.count - 1) }
            return nil
        }
        arc.append((raw.last.map { $0.location.distance(to: location) } ?? 0) + (arc.last ?? 0))
        raw.append(InkPoint(location, width: width(for: force)))
        forces.append(force)
        return raw.count - 1
    }

    /// Apple Pencil refines its force readings shortly after reporting them.
    public mutating func updateForce(_ force: Double, at index: Int) {
        guard raw.indices.contains(index) else { return }
        forces[index] = force
        raw[index].width = Float(width(for: force))
        // Points whose smoothing window reaches this one have to be recomputed.
        let reach = arc[index] - StrokeSmoothing.settledLength(radius: smoothing)
        while settled > 0, arc[settled - 1] >= reach {
            settled -= 1
        }
    }

    /// Points to show while drawing: the real stroke (exactly as it will be saved), then a tail
    /// through the system's predicted pen locations to hide latency.
    ///
    /// The prediction is only appended, never smoothed together with the real points: it's a
    /// guess that's replaced next frame, and if it bent the real line, the line would visibly
    /// snap back whenever the guess was wrong.
    public mutating func livePoints(predicted: [CGPoint] = []) -> [InkPoint] {
        var points = finishedPoints()
        guard var last = points.last else { return [] }
        for location in predicted where location.distance(to: last.location) >= Self.minimumSpacing {
            last = InkPoint(location, width: Double(last.width))
            points.append(last)
        }
        return points
    }

    /// The final points.
    public mutating func finishedPoints() -> [InkPoint] {
        let n = raw.count
        guard n > 2, smoothing > 0 else { return raw }
        if smoothed.count > settled {
            smoothed.removeSubrange(settled...)
        }
        for i in settled..<n {
            smoothed.append(StrokeSmoothing.smoothedPoint(at: i, in: raw, arc: arc, radius: smoothing))
        }
        // Points this far behind the end won't change any more.
        let limit = arc[n - 1] - StrokeSmoothing.settledLength(radius: smoothing)
        while settled < n, arc[settled] < limit {
            settled += 1
        }
        return smoothed
    }

    private func width(for force: Double?) -> Double {
        let factor = force.map(curve.widthFactor(forNormalizedForce:)) ?? 1
        return max(baseWidth * factor, Self.minimumWidth)
    }
}

extension CGPoint {
    public func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
