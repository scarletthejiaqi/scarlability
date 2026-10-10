import CoreGraphics

/// Collects pen samples for the stroke being drawn and turns them into smooth `InkPoint`s.
///
/// While writing and after lifting, points go through the same `StrokeSmoothing`, so the stroke
/// doesn't visibly change when the pen lifts. Smoothing is incremental: points far enough behind
/// the pen are final and kept, so each new sample only recomputes the last few points.
///
/// Pressure is evened out as samples arrive (each width only depends on the samples before it),
/// so the thickness behind the pen never shifts while you write. Only the Pencil's own refined
/// force readings, which arrive a moment later, can still change the last few widths.
public struct StrokeBuilder: Sendable {
    public let baseWidth: Double
    public let curve: PressureCurve
    /// Position smoothing σ in page points.
    public let smoothing: CGFloat
    /// How quickly the width follows pressure: the length (in page points) over which a change
    /// in pressure is mostly taken up. Shorter reacts faster.
    public let pressureSmoothing: CGFloat

    /// The samples, with widths from (evened-out) pressure applied.
    private var raw: [InkPoint] = []
    /// Pressure per sample as reported (nil for input without pressure), kept for force updates.
    private var forces: [Double?] = []
    /// Pressure per sample after evening out.
    private var evenedForces: [Double?] = []
    /// Cumulative length along `raw`.
    private var arc: [CGFloat] = []
    private var smoothed: [InkPoint] = []
    /// `smoothed[..<settled]` are final.
    private var settled = 0

    /// Samples closer than this (in page points) to the previous one only update its force.
    static let minimumSpacing: CGFloat = 0.15
    static let minimumWidth = 0.2
    /// Default `pressureSmoothing`, in screen points (divide by the zoom).
    public static let screenPressureSmoothing: CGFloat = 2.5

    public init(baseWidth: Double, curve: PressureCurve, smoothing: CGFloat, pressureSmoothing: CGFloat = 2) {
        self.baseWidth = baseWidth
        self.curve = curve
        self.smoothing = smoothing
        self.pressureSmoothing = pressureSmoothing
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
        forces.append(force)
        evenedForces.append(nil)
        raw.append(InkPoint(location, width: baseWidth))
        evenPressure(from: raw.count - 1)
        return raw.count - 1
    }

    /// Apple Pencil refines its force readings shortly after reporting them.
    public mutating func updateForce(_ force: Double, at index: Int) {
        guard raw.indices.contains(index) else { return }
        forces[index] = force
        evenPressure(from: index)
        // Widths from here on changed; positions didn't, so only these points are redone.
        settled = min(settled, index)
    }

    /// Recomputes the evened-out pressure, and the widths, from `start` to the end.
    private mutating func evenPressure(from start: Int) {
        for i in start..<raw.count {
            guard let force = forces[i] else {
                evenedForces[i] = nil
                raw[i].width = Float(baseWidth)
                continue
            }
            var evened = force
            if i > 0, let previous = evenedForces[i - 1], pressureSmoothing > 0 {
                // An exponential average over arc length: the same evening-out fast or slow.
                let take = 1 - exp(-(arc[i] - arc[i - 1]) / pressureSmoothing)
                evened = previous + (force - previous) * Double(take)
            }
            evenedForces[i] = evened
            raw[i].width = Float(max(baseWidth * curve.widthFactor(forNormalizedForce: evened), Self.minimumWidth))
        }
    }

    /// Points to show while drawing: the real stroke (exactly as it will be saved), then a tail
    /// through the system's predicted pen locations to hide latency.
    ///
    /// The prediction is only appended, never smoothed together with the real points: it's a
    /// guess that's replaced next frame, and if it bent the real line, the line would visibly
    /// snap back whenever the guess was wrong.
    ///
    /// - Parameter predictionScale: How far along the prediction to go (0 = not at all, 1 = all
    ///   the way). Less is steadier: a guess that overshoots a turn, or keeps going as the pen
    ///   stops, makes the tip flick out and back.
    public mutating func livePoints(predicted: [CGPoint] = [], predictionScale: CGFloat = 1) -> [InkPoint] {
        var points = finishedPoints()
        guard let tip = points.last, predictionScale > 0 else { return points }
        let origin = tip.location
        var last = tip
        for location in predicted {
            let scaled = CGPoint(x: origin.x + (location.x - origin.x) * predictionScale,
                                 y: origin.y + (location.y - origin.y) * predictionScale)
            guard scaled.distance(to: last.location) >= Self.minimumSpacing else { continue }
            last = InkPoint(scaled, width: Double(tip.width))
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
}

extension CGPoint {
    public func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
