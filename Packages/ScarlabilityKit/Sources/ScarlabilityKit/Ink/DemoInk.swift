import CoreGraphics
import Foundation

/// Synthetic pen input for tests and debug builds. It feeds `StrokeBuilder` the way the Pencil
/// does (~240 samples per second with changing pressure), so the output goes through the same
/// smoothing and pressure curve as real writing.
public enum DemoInk {
    /// The normal zoom (an A4 page filling the width of an 11" iPad in portrait).
    static let zoom: CGFloat = 820 / PageSize.a4.width
    /// Position smoothing used for demo strokes: the app's default at the normal zoom.
    public static let smoothing = StrokeSmoothing.screenRadius / zoom

    public static func strokes(color: InkColor = .black, baseWidth: Double = 2.2, curve: PressureCurve = PressureCurve()) -> [Stroke] {
        var strokes: [Stroke] = []
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func add(_ samples: [(CGPoint, Double)], color: InkColor = color, width: Double = baseWidth) {
            var builder = StrokeBuilder(baseWidth: width, curve: curve, smoothing: smoothing,
                                        pressureSmoothing: StrokeBuilder.screenPressureSmoothing / zoom)
            for (location, force) in samples {
                builder.add(location, force: force)
            }
            strokes.append(Stroke(color: color, points: builder.finishedPoints(), createdAt: start + Double(strokes.count)))
        }

        // Cursive-style loops, with pressure rising and falling like real handwriting.
        add(sample(count: 480) { t in
            let x = 60 + t * 300 + 14 * sin(t * .pi * 16)
            let y = 120 - 18 * cos(t * .pi * 16) + 18
            return (CGPoint(x: x, y: y), 0.15 + 0.25 * (1 + sin(t * .pi * 5)))
        })

        // Pressure ramp: very light on the left to very firm on the right.
        add(sample(count: 360) { t in
            (CGPoint(x: 60 + t * 460, y: 210 + 12 * sin(t * .pi * 6)), t * 0.7)
        })

        // Zigzag with sharp corners, to check that turns stay solid.
        let zigzag: [CGPoint] = (0...8).map { i in CGPoint(x: 60 + Double(i) * 30, y: i.isMultiple(of: 2) ? 300 : 250) }
        add(polyline(zigzag, samplesPerSegment: 30, force: 0.35))

        // Spiral.
        add(sample(count: 600) { t in
            let angle = t * .pi * 8
            let radius = 4 + t * 45
            return (CGPoint(x: 420 + radius * cos(angle), y: 290 + radius * sin(angle)), 0.3)
        }, color: .blue)

        // Taps make dots.
        for i in 0..<5 {
            add([(CGPoint(x: 70 + Double(i) * 18, y: 370), 0.1 + Double(i) * 0.12)], color: .red)
        }

        // A fast flick with few samples, to check that spline interpolation keeps it smooth.
        add(sample(count: 9) { t in
            (CGPoint(x: 200 + t * 250, y: 380 - 40 * sin(t * .pi)), 0.3)
        }, color: .red)

        // Thick pen.
        add(sample(count: 300) { t in
            (CGPoint(x: 60 + t * 460, y: 450 + 20 * sin(t * .pi * 3)), 0.25 + 0.2 * t)
        }, width: 5)

        return strokes
    }

    /// Slow cursive loops with the small position and pressure wobble of real Pencil input
    /// (deterministic, so tests can compare runs). Returns raw samples.
    public static func shakyHandwritingSamples(origin: CGPoint = CGPoint(x: 60, y: 560)) -> [(CGPoint, Double)] {
        var random = SeededRandom(seed: 42)
        // ~120 points per second of pen travel at 240 samples per second: slow, careful writing.
        return sample(count: 1200) { t in
            let x = origin.x + t * 300 + 14 * sin(t * .pi * 16)
            let y = origin.y - 18 * cos(t * .pi * 16) + 18
            let jitter = CGPoint(x: random.gaussian() * 0.12, y: random.gaussian() * 0.12)
            let force = 0.3 + 0.1 * sin(t * .pi * 5) + random.gaussian() * 0.02
            return (CGPoint(x: x + jitter.x, y: y + jitter.y), force)
        }
    }

    private static func sample(count: Int, _ f: (Double) -> (CGPoint, Double)) -> [(CGPoint, Double)] {
        (0..<count).map { f(Double($0) / Double(max(count - 1, 1))) }
    }

    private static func polyline(_ corners: [CGPoint], samplesPerSegment: Int, force: Double) -> [(CGPoint, Double)] {
        var samples: [(CGPoint, Double)] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for step in 0..<samplesPerSegment {
                let t = CGFloat(step) / CGFloat(samplesPerSegment)
                samples.append((CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), force))
            }
        }
        if let last = corners.last { samples.append((last, force)) }
        return samples
    }
}

/// A small deterministic random number generator (SplitMix64).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Standard normal, via Box–Muller.
    mutating func gaussian() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
