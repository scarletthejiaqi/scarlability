import Foundation

/// Turns Apple Pencil force into a width multiplier for the pressure pen.
///
/// Normal writing pressure gives the pen's base width; pressing harder makes the line thicker and
/// writing lightly makes it thinner. `sensitivity` scales how far it can go either way.
public struct PressureCurve: Hashable, Sendable {
    /// 0 means pressure has no effect; 1 is the strongest effect.
    public var sensitivity: Double

    public static let defaultSensitivity = 0.5

    /// Normalized force (`force / maximumPossibleForce`) treated as a firm press. Handwriting rarely
    /// gets near the Pencil's maximum, so the full range is reached well before it.
    static let firmForce = 0.55
    /// Below 1, light pressure ramps the width up quickly, so light writing doesn't look starved.
    static let exponent = 0.8
    /// How far from the base width the line can go at full sensitivity (0.7 → 30%…170%).
    static let maxSwing = 0.7

    public init(sensitivity: Double = PressureCurve.defaultSensitivity) {
        self.sensitivity = sensitivity
    }

    public func widthFactor(forNormalizedForce force: Double) -> Double {
        let pressure = min(max(force / Self.firmForce, 0), 1)
        let curved = pow(pressure, Self.exponent)
        let swing = Self.maxSwing * min(max(sensitivity, 0), 1)
        return 1 - swing + 2 * swing * curved
    }
}
