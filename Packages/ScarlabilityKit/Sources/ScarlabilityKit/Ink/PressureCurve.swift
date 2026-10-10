import Foundation

/// Turns Apple Pencil force into a width multiplier for the pressure pen.
///
/// Normal writing pressure gives the pen's base width; pressing harder makes the line thicker and
/// writing lightly makes it thinner. `sensitivity` scales how far it can go either way.
public struct PressureCurve: Hashable, Sendable {
    /// 0 means pressure has no effect; 1 is the strongest effect.
    public var sensitivity: Double
    /// How far from the base width the line can go at full sensitivity (0.7 → 30%…170%).
    public var maxSwing: Double
    /// Below 1, light pressure ramps the width up quickly, so light writing doesn't look starved;
    /// above 1, light pressure stays thin.
    public var exponent: Double

    public static let defaultSensitivity = 0.5
    public static let defaultFountainSensitivity = 0.8

    /// Normalized force (`force / maximumPossibleForce`) treated as a firm press. Handwriting rarely
    /// gets near the Pencil's maximum, so the full range is reached well before it.
    static let firmForce = 0.55

    public init(sensitivity: Double = PressureCurve.defaultSensitivity, maxSwing: Double = 0.7, exponent: Double = 0.8) {
        self.sensitivity = sensitivity
        self.maxSwing = maxSwing
        self.exponent = exponent
    }

    /// The fountain pen (钢笔): a wider range, and light pressure stays thin, so a line can go
    /// from a hairline to bold within one stroke.
    public static func fountain(sensitivity: Double = PressureCurve.defaultFountainSensitivity) -> PressureCurve {
        PressureCurve(sensitivity: sensitivity, maxSwing: 0.9, exponent: 1.2)
    }

    public func widthFactor(forNormalizedForce force: Double) -> Double {
        let pressure = min(max(force / Self.firmForce, 0), 1)
        let curved = pow(pressure, exponent)
        let swing = maxSwing * min(max(sensitivity, 0), 1)
        return 1 - swing + 2 * swing * curved
    }
}
