import CoreGraphics

/// Collects pen samples for the stroke being drawn and turns them into smooth `InkPoint`s.
///
/// While writing and after lifting, points go through the same `StrokeSmoothing`, so the stroke
/// doesn't visibly change when the pen lifts.
public struct StrokeBuilder: Sendable {
    private struct Sample: Sendable {
        var location: CGPoint
        /// `force / maximumPossibleForce`, or nil for input without pressure (finger, mouse).
        var force: Double?
    }

    public let baseWidth: Double
    public let curve: PressureCurve
    /// Position smoothing σ in page points.
    public let smoothing: CGFloat
    private var samples: [Sample] = []

    /// Samples closer than this (in page points) to the previous one only update its force.
    static let minimumSpacing: CGFloat = 0.15
    static let minimumWidth = 0.2

    public init(baseWidth: Double, curve: PressureCurve, smoothing: CGFloat) {
        self.baseWidth = baseWidth
        self.curve = curve
        self.smoothing = smoothing
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Adds a pen sample. Returns the index it was stored at (for later force updates), or nil if it
    /// was too close to the previous sample and only refreshed that sample's force.
    @discardableResult
    public mutating func add(_ location: CGPoint, force: Double?) -> Int? {
        if let last = samples.last, last.location.distance(to: location) < Self.minimumSpacing {
            if let force { samples[samples.count - 1].force = force }
            return nil
        }
        samples.append(Sample(location: location, force: force))
        return samples.count - 1
    }

    /// Apple Pencil refines its force readings shortly after reporting them.
    public mutating func updateForce(_ force: Double, at index: Int) {
        guard samples.indices.contains(index) else { return }
        samples[index].force = force
    }

    /// Points to show while drawing, continuing through the system's predicted pen locations to
    /// hide latency.
    public func livePoints(predicted: [CGPoint] = []) -> [InkPoint] {
        var points = rawPoints()
        guard var last = points.last else { return [] }
        for location in predicted where location.distance(to: last.location) >= Self.minimumSpacing {
            last = InkPoint(location, width: Double(last.width))
            points.append(last)
        }
        return StrokeSmoothing.smooth(points, radius: smoothing)
    }

    /// The final points.
    public func finishedPoints() -> [InkPoint] {
        StrokeSmoothing.smooth(rawPoints(), radius: smoothing)
    }

    private func rawPoints() -> [InkPoint] {
        samples.map { sample in
            let factor = sample.force.map(curve.widthFactor(forNormalizedForce:)) ?? 1
            return InkPoint(sample.location, width: max(baseWidth * factor, Self.minimumWidth))
        }
    }
}

extension CGPoint {
    public func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
