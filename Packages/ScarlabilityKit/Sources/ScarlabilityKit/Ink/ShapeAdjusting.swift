import CoreGraphics
import Foundation

/// After a stroke snaps to a shape, keeping the pen down and moving it reshapes the shape, like
/// Notability: a line's far end follows the pen (the start stays put); a closed shape turns and
/// grows or shrinks around its center to follow the pen.
///
/// Lines lock flat (0°/180°) and upright (90°), and closed shapes lock square to the page, when
/// they come within `ShapeAdjusting.lockAngle` of it; pushing past that frees them again.
public enum ShapeAdjusting {
    /// How close (in radians) to flat or upright the shape has to come to lock there.
    public static let lockAngle: CGFloat = 5 * .pi / 180

    /// The shape after the pen moved from `start` (where it was when the shape snapped) to `pen`.
    public static func adjust(_ shape: ShapeRecognizer.Shape, from start: CGPoint, to pen: CGPoint) -> ShapeRecognizer.Shape {
        let moved = CGPoint(x: pen.x - start.x, y: pen.y - start.y)
        switch shape {
        case .line(let a, let b):
            // The far end moves with the pen.
            let end = CGPoint(x: b.x + moved.x, y: b.y + moved.y)
            let length = a.distance(to: end)
            guard length > 0.01 else { return .line(a, end) }
            let angle = atan2(end.y - a.y, end.x - a.x)
            let lockedAngle = locked(angle)
            guard lockedAngle != angle else { return .line(a, end) }
            return .line(a, CGPoint(x: a.x + length * cos(lockedAngle), y: a.y + length * sin(lockedAngle)))

        case .ellipse(let center, let radii, let angle):
            guard let (scale, turn) = scaleAndTurn(around: center, from: start, to: pen) else { return shape }
            // A circle looks the same at any angle, so only real ellipses lock.
            let isCircle = abs(radii.width - radii.height) < 0.01
            let newAngle = isCircle ? angle : locked(angle + turn)
            return .ellipse(center: center, radii: CGSize(width: radii.width * scale, height: radii.height * scale), angle: newAngle)

        case .polygon(let corners):
            let center = CGPoint(x: corners.map(\.x).reduce(0, +) / CGFloat(corners.count),
                                 y: corners.map(\.y).reduce(0, +) / CGFloat(corners.count))
            guard let (scale, turn) = scaleAndTurn(around: center, from: start, to: pen) else { return shape }
            // Lock on the longest side, so a rectangle squares up with the page.
            let side = longestSide(corners)
            let lockedTurn = locked(side + turn) - side
            let cosine = cos(lockedTurn), sine = sin(lockedTurn)
            return .polygon(corners.map { p in
                let dx = (p.x - center.x) * scale, dy = (p.y - center.y) * scale
                return CGPoint(x: center.x + dx * cosine - dy * sine, y: center.y + dx * sine + dy * cosine)
            })
        }
    }

    /// The nearest of 0°, 90°, 180° and 270° if `angle` is within `lockAngle` of it.
    static func locked(_ angle: CGFloat) -> CGFloat {
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return abs(angle - nearest) <= lockAngle ? nearest : angle
    }

    /// How much bigger, and how far turned, the pen is around `center` compared with `start`.
    private static func scaleAndTurn(around center: CGPoint, from start: CGPoint, to pen: CGPoint) -> (CGFloat, CGFloat)? {
        let before = CGPoint(x: start.x - center.x, y: start.y - center.y)
        let after = CGPoint(x: pen.x - center.x, y: pen.y - center.y)
        let startDistance = hypot(before.x, before.y)
        // Too close to the middle to tell which way it turned.
        guard startDistance > 1, hypot(after.x, after.y) > 1 else { return nil }
        let scale = hypot(after.x, after.y) / startDistance
        let turn = atan2(after.y, after.x) - atan2(before.y, before.x)
        return (max(scale, 0.05), turn)
    }

    private static func longestSide(_ corners: [CGPoint]) -> CGFloat {
        let sides = zip(corners, corners.dropFirst() + corners.prefix(1))
        guard let (a, b) = sides.max(by: { $0.0.distance(to: $0.1) < $1.0.distance(to: $1.1) }) else { return 0 }
        return atan2(b.y - a.y, b.x - a.x)
    }
}
