import CoreGraphics

/// Collects pen samples for the stroke being drawn and smooths them into `InkPoint`s.
///
/// Positions get light exponential smoothing so shaky lines look clean, and widths are smoothed
/// separately so pressure changes don't make the edge look jittery.
public struct StrokeBuilder: Sendable {
    private struct Sample: Sendable {
        var location: CGPoint
        /// `force / maximumPossibleForce`, or nil for input without pressure (finger, mouse).
        var force: Double?
    }

    public let baseWidth: Double
    public let curve: PressureCurve
    private var samples: [Sample] = []
    private var lastRawLocation: CGPoint?

    /// Weight of each new raw position; lower is smoother but trails the pen more.
    static let positionSmoothing: CGFloat = 0.55
    /// Weight of each new width.
    static let widthSmoothing = 0.3
    /// Samples closer than this (in page points) to the previous one only update its force.
    static let minimumSpacing: CGFloat = 0.25
    static let minimumWidth = 0.2

    public init(baseWidth: Double, curve: PressureCurve) {
        self.baseWidth = baseWidth
        self.curve = curve
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Adds a pen sample. Returns the index it was stored at (for later force updates), or nil if it
    /// was too close to the previous sample and only refreshed that sample's force.
    @discardableResult
    public mutating func add(_ location: CGPoint, force: Double?) -> Int? {
        lastRawLocation = location
        guard let previous = samples.last else {
            samples.append(Sample(location: location, force: force))
            return 0
        }
        let a = Self.positionSmoothing
        let smoothed = CGPoint(
            x: previous.location.x + (location.x - previous.location.x) * a,
            y: previous.location.y + (location.y - previous.location.y) * a
        )
        guard smoothed.distance(to: previous.location) >= Self.minimumSpacing else {
            if let force { samples[samples.count - 1].force = force }
            return nil
        }
        samples.append(Sample(location: smoothed, force: force))
        return samples.count - 1
    }

    /// Apple Pencil refines its force readings shortly after reporting them.
    public mutating func updateForce(_ force: Double, at index: Int) {
        guard samples.indices.contains(index) else { return }
        samples[index].force = force
    }

    /// Points to show while drawing: the smoothed stroke, reaching all the way to the pen tip and on
    /// through the system's predicted locations.
    public func livePoints(predicted: [CGPoint] = []) -> [InkPoint] {
        var points = finishedPoints()
        guard let last = points.last else { return [] }
        points += predicted.map { InkPoint($0, width: Double(last.width)) }
        return points
    }

    /// The final points, ending exactly where the pen lifted.
    public func finishedPoints() -> [InkPoint] {
        var points = smoothedPoints()
        if let last = points.last, let raw = lastRawLocation, raw.distance(to: last.location) >= Self.minimumSpacing {
            points.append(InkPoint(raw, width: Double(last.width)))
        }
        return points
    }

    private func smoothedPoints() -> [InkPoint] {
        var width: Double?
        return samples.map { sample in
            let factor = sample.force.map(curve.widthFactor(forNormalizedForce:)) ?? 1
            let target = max(baseWidth * factor, Self.minimumWidth)
            let smoothed = width.map { $0 + (target - $0) * Self.widthSmoothing } ?? target
            width = smoothed
            return InkPoint(sample.location, width: smoothed)
        }
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
